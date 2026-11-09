import uuid
from unittest.mock import patch

from django.core.cache import cache
from django.test import SimpleTestCase, TestCase, override_settings
from django.urls import reverse
from rest_framework.test import APIClient

from plandit.core.models import Profile
from resolution.models import SocialEvidenceThrottleState
from resolution.providers.ensembledata import (
    EnsembleDataQuotaExceeded,
    SocialEvidence,
)
from resolution.providers.public_page import (
    PublicPageEvidenceMissing,
    PublicPageSocialEvidence,
)


@override_settings(
    DEBUG=True,
    SOCIAL_PAGE_EXTRACTION_ENABLED=False,
    ENSEMBLEDATA_ENABLED=True,
    ENSEMBLEDATA_API_TOKEN="1234567890abcdef",
)
class SocialEvidenceApiTests(TestCase):
    def setUp(self):
        cache.clear()
        self.api_client = APIClient()
        self.profile = Profile.objects.create(id=uuid.uuid4())
        self.api_client.force_authenticate(user=self.profile)

    def post(self, source_url="https://www.tiktok.com/t/ZTfDj7vmC/"):
        return self.api_client.post(
            reverse("social-evidence"),
            data={"sourceUrl": source_url},
            format="json",
        )

    @override_settings(DEBUG=False)
    def test_requires_authentication_in_production(self):
        response = APIClient().post(
            reverse("social-evidence"),
            data={"sourceUrl": "https://www.tiktok.com/t/ZTfDj7vmC/"},
            format="json",
        )

        self.assertEqual(response.status_code, 401)

    @patch("resolution.views.EnsembleDataClient")
    def test_returns_caption_and_transcript_without_persisting_them(self, client_type):
        client_type.return_value.evidence_for.return_value = SocialEvidence(
            canonical_url=("https://www.tiktok.com/@travelwithchyna/video/7655467577765793037"),
            caption="Chubby Bowls at 809 Broadway",
            transcript="Near 14th Street and Union Square",
            transcript_language="en",
        )

        response = self.post()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json()["combinedText"],
            "Chubby Bowls at 809 Broadway\nNear 14th Street and Union Square",
        )
        self.assertEqual(response["Cache-Control"], "no-store")
        client_type.return_value.evidence_for.assert_called_once_with("https://www.tiktok.com/t/ZTfDj7vmC")

    @patch("resolution.views.EnsembleDataClient")
    def test_reuses_short_lived_evidence_for_identical_retries(self, client_type):
        client_type.return_value.evidence_for.return_value = SocialEvidence(
            canonical_url="https://www.tiktok.com/@creator/video/123",
            caption="Chubby Bowls",
            transcript="809 Broadway",
            transcript_language="en",
        )
        first = self.post()
        second = self.post()

        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        client_type.return_value.evidence_for.assert_called_once()

    @patch("resolution.views.EnsembleDataClient")
    def test_reports_daily_provider_limit(self, client_type):
        client_type.return_value.evidence_for.side_effect = EnsembleDataQuotaExceeded()

        response = self.post()

        self.assertEqual(response.status_code, 429)
        self.assertEqual(response.json()["error"]["code"], "provider_quota_exceeded")
        self.assertTrue(response.json()["error"]["retryable"])

    @override_settings(ENSEMBLEDATA_ENABLED=False)
    def test_is_unavailable_without_explicit_enablement(self):
        response = self.post()

        self.assertEqual(response.status_code, 404)

    @override_settings(DEBUG=False, SOCIAL_EVIDENCE_THROTTLE_RATE="1/day")
    @patch("resolution.views.EnsembleDataClient")
    def test_enforces_atomic_per_user_limit(self, client_type):
        client_type.return_value.evidence_for.return_value = SocialEvidence(
            canonical_url="https://www.tiktok.com/@creator/video/123",
            caption="Chubby Bowls",
            transcript="809 Broadway",
            transcript_language="en",
        )

        first = self.post()
        second = self.post("https://www.tiktok.com/@creator/video/456")

        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 429)
        self.assertEqual(
            SocialEvidenceThrottleState.objects.get(user=self.profile).request_count,
            1,
        )


@override_settings(
    DEBUG=True,
    SOCIAL_PAGE_EXTRACTION_ENABLED=True,
    ENSEMBLEDATA_ENABLED=False,
)
class DirectSocialEvidenceApiTests(SimpleTestCase):
    def setUp(self):
        cache.clear()
        self.api_client = APIClient()

    def post(self, source_url):
        return self.api_client.post(
            reverse("social-evidence"),
            data={"sourceUrl": source_url},
            format="json",
        )

    @patch("resolution.views.PublicPageSocialEvidenceClient")
    def test_returns_direct_tiktok_caption(self, client_type):
        client_type.return_value.evidence_for.return_value = PublicPageSocialEvidence(
            canonical_url="https://www.tiktok.com/@creator/video/123",
            caption="Kings of Kobe 650 W 42nd St, New York, NY 10036",
        )

        response = self.post("https://www.tiktok.com/t/short-code")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json()["combinedText"],
            "Kings of Kobe 650 W 42nd St, New York, NY 10036",
        )

    @patch("resolution.views.PublicPageSocialEvidenceClient")
    def test_returns_direct_instagram_caption(self, client_type):
        client_type.return_value.evidence_for.return_value = PublicPageSocialEvidence(
            canonical_url="https://www.instagram.com/reel/DdFUQjZJ0fc",
            caption="Yop City 2324 Arthur Ave, Bronx, NY 10458",
        )

        response = self.post("https://www.instagram.com/reel/DdFUQjZJ0fc/?tracking=value")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json()["combinedText"],
            "Yop City 2324 Arthur Ave, Bronx, NY 10458",
        )

    @patch("resolution.views.PublicPageSocialEvidenceClient")
    def test_reports_missing_caption_as_non_retryable(self, client_type):
        client_type.return_value.evidence_for.side_effect = PublicPageEvidenceMissing()

        response = self.post("https://www.instagram.com/reel/ABC")

        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json()["error"]["code"], "evidence_unavailable")
        self.assertFalse(response.json()["error"]["retryable"])

    @patch("resolution.views.EnsembleDataClient")
    @patch("resolution.views.PublicPageSocialEvidenceClient")
    def test_direct_cache_is_not_used_after_kill_switch_is_disabled(
        self,
        direct_client_type,
        ensemble_client_type,
    ):
        direct_client_type.return_value.evidence_for.return_value = PublicPageSocialEvidence(
            canonical_url="https://www.tiktok.com/@creator/video/123",
            caption="Direct caption",
        )
        ensemble_client_type.return_value.evidence_for.return_value = SocialEvidence(
            canonical_url="https://www.tiktok.com/@creator/video/123",
            caption="Fallback caption",
            transcript=None,
            transcript_language=None,
        )
        source_url = "https://www.tiktok.com/@creator/video/123"

        self.assertEqual(self.post(source_url).json()["caption"], "Direct caption")
        with self.settings(
            SOCIAL_PAGE_EXTRACTION_ENABLED=False,
            ENSEMBLEDATA_ENABLED=True,
            ENSEMBLEDATA_API_TOKEN="1234567890abcdef",
        ):
            response = self.post(source_url)

        self.assertEqual(response.json()["caption"], "Fallback caption")
        ensemble_client_type.return_value.evidence_for.assert_called_once()

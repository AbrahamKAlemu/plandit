import uuid
from unittest.mock import patch

from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework.test import APIClient

from plandit.core.models import Profile
from resolution.models import SocialEvidenceThrottleState
from resolution.providers.ensembledata import (
    EnsembleDataQuotaExceeded,
    SocialEvidence,
)


@override_settings(
    DEBUG=True,
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

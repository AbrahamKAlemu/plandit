import json
from unittest.mock import patch

from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse

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

    @patch("resolution.views.EnsembleDataClient")
    def test_returns_caption_and_transcript_without_persisting_them(self, client_type):
        client_type.return_value.evidence_for.return_value = SocialEvidence(
            canonical_url=(
                "https://www.tiktok.com/@travelwithchyna/video/7655467577765793037"
            ),
            caption="Chubby Bowls at 809 Broadway",
            transcript="Near 14th Street and Union Square",
            transcript_language="en",
        )

        response = self.client.post(
            reverse("social-evidence"),
            data=json.dumps(
                {"sourceUrl": "https://www.tiktok.com/t/ZTfDj7vmC/"}
            ),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json()["combinedText"],
            "Chubby Bowls at 809 Broadway\nNear 14th Street and Union Square",
        )
        self.assertEqual(response["Cache-Control"], "no-store")
        client_type.return_value.evidence_for.assert_called_once_with(
            "https://www.tiktok.com/t/ZTfDj7vmC"
        )

    @patch("resolution.views.EnsembleDataClient")
    def test_reuses_short_lived_evidence_for_identical_retries(self, client_type):
        client_type.return_value.evidence_for.return_value = SocialEvidence(
            canonical_url="https://www.tiktok.com/@creator/video/123",
            caption="Chubby Bowls",
            transcript="809 Broadway",
            transcript_language="en",
        )
        body = json.dumps({"sourceUrl": "https://www.tiktok.com/t/ZTfDj7vmC/"})

        first = self.client.post(
            reverse("social-evidence"), data=body, content_type="application/json"
        )
        second = self.client.post(
            reverse("social-evidence"), data=body, content_type="application/json"
        )

        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        client_type.return_value.evidence_for.assert_called_once()

    @patch("resolution.views.EnsembleDataClient")
    def test_reports_daily_provider_limit(self, client_type):
        client_type.return_value.evidence_for.side_effect = EnsembleDataQuotaExceeded()

        response = self.client.post(
            reverse("social-evidence"),
            data=json.dumps(
                {"sourceUrl": "https://www.tiktok.com/t/ZTfDj7vmC/"}
            ),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 429)
        self.assertEqual(response.json()["error"]["code"], "provider_quota_exceeded")
        self.assertTrue(response.json()["error"]["retryable"])

    @override_settings(ENSEMBLEDATA_ENABLED=False)
    def test_is_unavailable_without_explicit_development_flag(self):
        response = self.client.post(
            reverse("social-evidence"),
            data=json.dumps(
                {"sourceUrl": "https://www.tiktok.com/t/ZTfDj7vmC/"}
            ),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 404)

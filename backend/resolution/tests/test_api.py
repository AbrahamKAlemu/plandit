import hashlib
import json
import uuid

from django.test import TestCase
from django.urls import reverse

from resolution.models import ResolutionAttempt


class PlaceResolutionApiTests(TestCase):
    def test_returns_matching_candidate_without_storing_evidence(self):
        request_id = str(uuid.uuid4())
        response = self.client.post(
            reverse("place-resolutions"),
            data=json.dumps(
                {
                    "requestId": request_id,
                    "platform": "tiktok",
                    "sourceUrl": "https://www.tiktok.com/@creator/video/123",
                    "evidence": {"userText": "Try Levain Bakery on the Upper West Side"},
                }
            ),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["candidates"][0]["name"], "Levain Bakery")
        attempt = ResolutionAttempt.objects.get(request_id=request_id)
        self.assertEqual(attempt.candidate_count, 1)
        model_fields = {field.name for field in ResolutionAttempt._meta.fields}
        self.assertNotIn("evidence", model_fields)
        self.assertNotIn("source_url", model_fields)

    def test_instagram_rejects_source_url(self):
        response = self.client.post(
            reverse("place-resolutions"),
            data=json.dumps(
                {
                    "requestId": str(uuid.uuid4()),
                    "platform": "instagram",
                    "sourceUrl": "https://www.instagram.com/reel/ABC",
                    "evidence": {"userText": "Levain Bakery"},
                }
            ),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["error"]["code"], "invalid_request")

    def test_rejects_deceptive_tiktok_host(self):
        response = self.client.post(
            reverse("place-resolutions"),
            data=json.dumps(
                {
                    "requestId": str(uuid.uuid4()),
                    "platform": "tiktok",
                    "sourceUrl": "https://tiktok.com.example.com/@creator/video/123",
                    "evidence": {"userText": "Levain Bakery"},
                }
            ),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["error"]["code"], "invalid_url")

    def test_rejects_non_object_json_shapes(self):
        response = self.client.post(
            reverse("place-resolutions"),
            data=json.dumps([]),
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["error"]["code"], "invalid_request")

        response = self.client.post(
            reverse("place-resolutions"),
            data=json.dumps(
                {
                    "requestId": str(uuid.uuid4()),
                    "platform": "video",
                    "evidence": "Levain Bakery",
                }
            ),
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["error"]["code"], "invalid_request")

    def test_request_id_is_idempotent_and_rejects_changed_request(self):
        request_id = str(uuid.uuid4())
        payload = {
            "requestId": request_id,
            "platform": "video",
            "evidence": {"userText": "Levain Bakery"},
        }
        first = self.client.post(
            reverse("place-resolutions"),
            data=json.dumps(payload),
            content_type="application/json",
        )
        second = self.client.post(
            reverse("place-resolutions"),
            data=json.dumps(payload),
            content_type="application/json",
        )
        self.assertEqual(first.json(), second.json())
        self.assertEqual(ResolutionAttempt.objects.filter(request_id=request_id).count(), 1)
        self.assertEqual(
            ResolutionAttempt.objects.get(request_id=request_id).candidate_payload,
            first.json()["candidates"],
        )

        payload["evidence"]["userText"] = "Los Tacos"
        conflict = self.client.post(
            reverse("place-resolutions"),
            data=json.dumps(payload),
            content_type="application/json",
        )
        self.assertEqual(conflict.status_code, 409)
        self.assertEqual(conflict.json()["error"]["code"], "idempotency_conflict")

    def test_legacy_request_without_candidate_snapshot_is_expired(self):
        request_id = str(uuid.uuid4())
        payload = {
            "requestId": request_id,
            "platform": "video",
            "evidence": {"userText": "Levain Bakery"},
        }
        first = self.client.post(
            reverse("place-resolutions"),
            data=json.dumps(payload),
            content_type="application/json",
        )
        self.assertEqual(first.status_code, 200)
        ResolutionAttempt.objects.filter(request_id=request_id).update(
            candidate_payload=None,
            idempotency_digest=hashlib.sha256(
                f"video:{request_id}".encode()
            ).hexdigest(),
        )

        retry = self.client.post(
            reverse("place-resolutions"),
            data=json.dumps(payload),
            content_type="application/json",
        )
        self.assertEqual(retry.status_code, 409)
        self.assertEqual(retry.json()["error"]["code"], "idempotency_record_expired")

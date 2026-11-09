import json
import socket
from unittest.mock import MagicMock, patch

from django.test import SimpleTestCase

from resolution.providers.public_page import (
    MAX_PAGE_BYTES,
    PublicPageError,
    PublicPageEvidenceMissing,
    PublicPageSocialEvidenceClient,
    _fetch_page,
    _open_pinned,
    _PageResponse,
    _public_addresses,
)


class PublicPageSocialEvidenceClientTests(SimpleTestCase):
    def test_extracts_tiktok_caption_from_hydration_json(self):
        payload = {
            "__DEFAULT_SCOPE__": {
                "webapp.video-detail": {
                    "itemInfo": {
                        "itemStruct": {
                            "desc": ("Kings of Kobe 650 W 42nd St, New York, NY 10036"),
                            "author": {"uniqueId": "saint_travels"},
                        }
                    },
                    "shareMeta": {"desc": "fallback caption"},
                }
            }
        }
        html = f'<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">{json.dumps(payload)}</script>'
        client = PublicPageSocialEvidenceClient(
            fetch_page=lambda url: (
                "https://www.tiktok.com/@saint_travels/video/7694476036867640589",
                html,
            )
        )

        evidence = client.evidence_for("https://www.tiktok.com/t/ZTfyEe3H7/")

        self.assertEqual(
            evidence.canonical_url,
            "https://www.tiktok.com/@saint_travels/video/7694476036867640589",
        )
        self.assertEqual(
            evidence.caption,
            "Kings of Kobe 650 W 42nd St, New York, NY 10036",
        )
        self.assertIsNone(evidence.transcript)

    def test_uses_tiktok_share_metadata_when_item_caption_is_absent(self):
        payload = {
            "__DEFAULT_SCOPE__": {
                "webapp.video-detail": {
                    "itemInfo": {"itemStruct": {}},
                    "shareMeta": {"desc": "Lululala 139 Hester St New York, NY"},
                }
            }
        }
        client = PublicPageSocialEvidenceClient(
            fetch_page=lambda url: (
                "https://www.tiktok.com/@johnnyeatsnyc/video/7515092400834956575",
                (
                    '<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" '
                    f'type="application/json">{json.dumps(payload)}</script>'
                ),
            )
        )

        evidence = client.evidence_for("https://www.tiktok.com/@johnnyeatsnyc/video/7515092400834956575")

        self.assertEqual(
            evidence.caption,
            "Lululala 139 Hester St New York, NY",
        )

    def test_extracts_instagram_caption_from_open_graph_metadata(self):
        client = PublicPageSocialEvidenceClient(
            fetch_page=lambda url: (
                "https://www.instagram.com/reel/DdFUQjZJ0fc",
                """
                <meta property="og:description"
                      content="A true Bronx Staple.. 📍Yop City &#10;2324 Arthur Ave, Bronx, NY 10458">
                """,
            )
        )

        evidence = client.evidence_for("https://www.instagram.com/reel/DdFUQjZJ0fc/?tracking=value")

        self.assertEqual(
            evidence.caption,
            "A true Bronx Staple.. 📍Yop City \n2324 Arthur Ave, Bronx, NY 10458",
        )

    def test_rejects_page_without_caption_evidence(self):
        client = PublicPageSocialEvidenceClient(
            fetch_page=lambda url: (
                "https://www.instagram.com/reel/ABC",
                '<meta property="og:title" content="Instagram">',
            )
        )

        with self.assertRaises(PublicPageEvidenceMissing):
            client.evidence_for("https://www.instagram.com/reel/ABC")

    @patch("resolution.providers.public_page._open_pinned")
    def test_rejects_cross_platform_redirect_before_fetching_destination(self, open_pinned):
        open_pinned.return_value = _PageResponse(
            302,
            "https://www.instagram.com/reel/ABC",
            b"",
        )

        with self.assertRaises(PublicPageError):
            _fetch_page("https://www.tiktok.com/t/ABC")

        open_pinned.assert_called_once()

    @patch("resolution.providers.public_page.socket.getaddrinfo")
    def test_rejects_private_dns_results(self, getaddrinfo):
        getaddrinfo.return_value = [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 443)),
        ]

        with self.assertRaises(PublicPageError):
            _public_addresses("www.tiktok.com")

    @patch("resolution.providers.public_page._PinnedHTTPSConnection")
    @patch("resolution.providers.public_page._public_addresses")
    def test_rejects_oversized_response_before_reading_body(self, public_addresses, connection_type):
        public_addresses.return_value = ["203.0.113.1"]
        response = MagicMock()
        response.getheader.side_effect = lambda name: {
            "Content-Length": str(MAX_PAGE_BYTES + 1),
            "Location": None,
            "Content-Encoding": None,
        }.get(name)
        connection_type.return_value.getresponse.return_value = response

        with self.assertRaises(PublicPageError):
            _open_pinned("https://www.instagram.com/reel/ABC")

        response.read.assert_not_called()

    @patch("resolution.providers.public_page._PinnedHTTPSConnection")
    @patch("resolution.providers.public_page._public_addresses")
    def test_wraps_connection_timeout(self, public_addresses, connection_type):
        public_addresses.return_value = ["203.0.113.1"]
        connection_type.return_value.request.side_effect = TimeoutError()

        with self.assertRaises(PublicPageError):
            _open_pinned("https://www.instagram.com/reel/ABC")

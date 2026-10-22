import os
from unittest.mock import patch

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import SimpleTestCase

from resolution.providers.ensembledata import (
    EnsembleDataClient,
    EnsembleDataError,
    _validate_external_https_url,
    parse_subtitle_text,
)


class EnsembleDataClientTests(SimpleTestCase):
    def test_extracts_caption_and_english_platform_subtitles(self):
        requested_urls = []

        def fetch_json(url):
            requested_urls.append(url)
            return {
                "data": {
                    "desc": "Come with me to try Chubby Bowls",
                    "video": {
                        "cla_info": {
                            "caption_infos": [
                                {
                                    "language_code": "es",
                                    "url": "https://captions.example/es.json",
                                },
                                {
                                    "language_code": "en",
                                    "url": "https://captions.example/en.json",
                                },
                            ]
                        }
                    },
                }
            }

        client = EnsembleDataClient(
            "1234567890abcdef",
            fetch_json=fetch_json,
            fetch_text=lambda url: (
                '{"utterances":[{"text":"Chubby Bowls at 809 Broadway"},'
                '{"text":"near Union Square"}]}'
            ),
            resolve_url=lambda url: (
                "https://www.tiktok.com/@travelwithchyna/video/7655467577765793037"
            ),
            validate_subtitle_url=lambda url: None,
        )

        evidence = client.evidence_for("https://www.tiktok.com/t/ZTfDj7vmC/")

        self.assertEqual(
            evidence.canonical_url,
            "https://www.tiktok.com/@travelwithchyna/video/7655467577765793037",
        )
        self.assertEqual(evidence.caption, "Come with me to try Chubby Bowls")
        self.assertEqual(evidence.transcript_language, "en")
        self.assertEqual(
            evidence.transcript,
            "Chubby Bowls at 809 Broadway\nnear Union Square",
        )
        self.assertIn("download_video=false", requested_urls[0])
        self.assertIn("new_version=false", requested_urls[0])

    def test_returns_caption_when_subtitles_are_unavailable(self):
        client = EnsembleDataClient(
            "1234567890abcdef",
            fetch_json=lambda url: {"data": {"desc": "Chubby Bowls in NYC"}},
            resolve_url=lambda url: (
                "https://www.tiktok.com/@travelwithchyna/video/7655467577765793037"
            ),
        )

        evidence = client.evidence_for(
            "https://www.tiktok.com/@travelwithchyna/video/7655467577765793037"
        )

        self.assertEqual(evidence.caption, "Chubby Bowls in NYC")
        self.assertIsNone(evidence.transcript)

    def test_rejects_share_url_that_does_not_resolve_to_video(self):
        client = EnsembleDataClient(
            "1234567890abcdef",
            resolve_url=lambda url: "https://www.tiktok.com/t/unchanged",
        )

        with self.assertRaises(EnsembleDataError):
            client.evidence_for("https://www.tiktok.com/t/unchanged")


class SubtitleParsingTests(SimpleTestCase):
    def test_parses_and_deduplicates_webvtt(self):
        value = """WEBVTT

00:00:00.000 --> 00:00:02.000
Chubby Bowls at 809 Broadway

00:00:02.000 --> 00:00:04.000
Chubby Bowls at 809 Broadway
Union Square
"""

        self.assertEqual(
            parse_subtitle_text(value),
            "Chubby Bowls at 809 Broadway\nUnion Square",
        )

    def test_subtitle_urls_are_limited_to_known_tiktok_cdns(self):
        _validate_external_https_url(
            "https://p16-sign-va.tiktokcdn.com/captions/english.json"
        )
        _validate_external_https_url(
            "https://v16-cla.tiktokcdn-eu.com/captions/english.json"
        )
        _validate_external_https_url(
            "https://v16m-default.akamaized.net/captions/english.json"
        )

        with self.assertRaises(EnsembleDataError):
            _validate_external_https_url(
                "https://attacker.example/captions/english.json"
            )


class EnsembleDataCommandTests(SimpleTestCase):
    def test_requires_token_from_environment(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesMessage(
                CommandError,
                "Set ENSEMBLEDATA_API_TOKEN",
            ):
                call_command(
                    "try_ensembledata",
                    "https://www.tiktok.com/@creator/video/123",
                )

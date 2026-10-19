from django.test import SimpleTestCase

from resolution.url_policy import SourceUrlError, parse_supported_source_url


class SourceUrlPolicyTests(SimpleTestCase):
    def test_canonicalizes_supported_url(self):
        source = parse_supported_source_url(
            "https://www.tiktok.com/@creator/video/123?share=1#fragment"
        )
        self.assertEqual(
            source.canonical_url,
            "https://www.tiktok.com/@creator/video/123",
        )

    def test_rejects_unsafe_urls(self):
        unsafe = (
            "http://www.tiktok.com/@creator/video/123",
            "https://user:pass@www.tiktok.com/@creator/video/123",
            "https://www.tiktok.com:444/@creator/video/123",
            "https://tiktok.com.example.com/@creator/video/123",
        )
        for value in unsafe:
            with self.subTest(value=value):
                with self.assertRaises(SourceUrlError):
                    parse_supported_source_url(value)

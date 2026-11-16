"""Run with yt-dlp installed: python -m unittest discover -s this-directory."""

import copy
import io
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

from yt_dlp import YoutubeDL
from yt_dlp.networking import Response
from yt_dlp.networking.exceptions import CertificateVerifyError, HTTPError, TransportError
from yt_dlp.utils.networking import HTTPHeaderDict

from youtube_cdn_fallback import YoutubeCdnFallbackPP, _fallback_urls


PRIMARY = "rr1---sn-primary.googlevideo.com"
BACKUP = "rr1---sn-backup.googlevideo.com"
URL = f"https://{PRIMARY}/videoplayback?sig=a%2Fb%2Bz&mn=sn-primary%2Csn-backup&itag=299"


class CdnFallbackTests(unittest.TestCase):
    def setUp(self):
        self.ydl = YoutubeDL({"quiet": True, "no_warnings": True})
        self.addCleanup(self.ydl.close)
        self.pp = YoutubeCdnFallbackPP(self.ydl)
        self.info = {"extractor_key": "Youtube", "requested_formats": [
            {"url": URL, "protocol": "https", "format_id": "299", "http_headers": {"User-Agent": "test"}},
            {"url": URL.replace("itag=299", "itag=140"), "protocol": "https", "format_id": "140"},
        ]}

    def test_both_streams_fall_back_and_keep_signed_query(self):
        requests = []
        responses = []

        def urlopen(request):
            requests.append(request)
            self.assertEqual(request.headers["Range"], "bytes=0-1023")
            self.assertEqual(request.extensions["timeout"], 3)
            if urlsplit(request.url).hostname == PRIMARY:
                raise TransportError("connect timeout")
            response = Response(io.BytesIO(b"x"), request.url, {}, 206)
            responses.append(response)
            return response

        with patch.object(self.ydl, "urlopen", side_effect=urlopen):
            _, result = self.pp.run(self.info)
        self.assertEqual(len(requests), 4)
        self.assertEqual(requests[1].headers["User-Agent"], "test")
        for fmt, itag in zip(result["requested_formats"], ("299", "140")):
            self.assertEqual(fmt["url"], URL.replace(PRIMARY, BACKUP).replace("itag=299", f"itag={itag}") + "&fallback_count=1")
        self.assertTrue(all(response.closed for response in responses))

    def test_probe_does_not_mutate_shared_headers_or_resume_range(self):
        for initial in ({"User-Agent": "test"}, {"User-Agent": "test", "Range": "bytes=100-200"}):
            with self.subTest(initial=initial):
                headers = HTTPHeaderDict(initial)
                response = Response(io.BytesIO(b"x" * 2048), URL, {}, 206)
                with patch.object(self.ydl, "urlopen", return_value=response) as urlopen:
                    self.assertTrue(self.pp._probe(URL, headers))
                self.assertEqual(dict(headers), initial)
                request = urlopen.call_args.args[0]
                self.assertIsNot(request.headers, headers)
                self.assertEqual(request.headers["Range"], "bytes=0-1023")

    def test_healthy_primary_is_unchanged(self):
        original = copy.deepcopy(self.info)
        with patch.object(self.pp, "_probe", return_value=True) as probe:
            self.pp.run(self.info)
        self.assertEqual(self.info, original)
        self.assertEqual(probe.call_count, 2)

    def test_waits_for_media_availability_before_probing(self):
        info = {"extractor": "youtube", "available_at": 105} | self.info["requested_formats"][0]
        calls = []
        with patch("youtube_cdn_fallback.time.time", return_value=100), \
                patch("youtube_cdn_fallback.time.sleep", side_effect=lambda seconds: calls.append(("wait", seconds))), \
                patch.object(self.pp, "_probe", side_effect=lambda *_: calls.append(("probe",)) or True):
            self.pp.run(info)
        self.assertEqual(calls, [("wait", 5), ("probe",)])

    def test_expired_availability_does_not_add_delay(self):
        info = {"extractor": "youtube", "available_at": 95} | self.info["requested_formats"][0]
        with patch("youtube_cdn_fallback.time.time", return_value=100), \
                patch("youtube_cdn_fallback.time.sleep") as sleep, \
                patch.object(self.pp, "_probe", return_value=True):
            self.pp.run(info)
        sleep.assert_not_called()

    def test_http_and_certificate_errors_do_not_trigger_fallback(self):
        for error in (HTTPError(Response(io.BytesIO(), URL, {}, 403)), CertificateVerifyError("bad cert")):
            with self.subTest(error=type(error).__name__):
                original = copy.deepcopy(self.info)
                with patch.object(self.pp, "_probe", side_effect=error) as probe:
                    self.pp.run(self.info)
                self.assertEqual(self.info, original)
                self.assertEqual(probe.call_count, 2)

    def test_all_hosts_unreachable_keeps_original(self):
        original = copy.deepcopy(self.info)
        with patch.object(self.pp, "_probe", side_effect=TransportError("timeout")):
            self.pp.run(self.info)
        self.assertEqual(self.info, original)

    def test_other_sites_and_hls_are_skipped(self):
        for overrides in ({"extractor_key": "Vimeo"}, {"requested_formats": [{"url": URL, "protocol": "m3u8_native"}]}):
            with self.subTest(overrides=overrides), patch.object(self.pp, "_probe") as probe:
                self.pp.run(self.info | overrides)
                probe.assert_not_called()

    def test_single_combined_stream(self):
        info = {"extractor": "youtube"} | copy.deepcopy(self.info["requested_formats"][0])
        with patch.object(self.pp, "_probe", side_effect=[TransportError("timeout"), True]):
            self.pp.run(info)
        self.assertEqual(urlsplit(info["url"]).hostname, BACKUP)

    def test_untrusted_or_unadvertised_hosts_are_rejected(self):
        for url in (
            URL.replace("https:", "http:"),
            URL.replace(PRIMARY, "example.com"),
            URL.replace(PRIMARY, "user@" + PRIMARY),
            URL.replace(PRIMARY, PRIMARY + ":8443"),
            URL.replace("/videoplayback", "/other"),
            URL.replace("sn-primary%2C", "sn-unlisted%2C"),
            URL.replace("sn-backup&", "evil.example&"),
            URL + "&mn=sn-other",
        ):
            with self.subTest(url=url):
                self.assertEqual(_fallback_urls(url), [])

    def test_existing_fallback_count_is_replaced_without_reencoding_signature(self):
        backup, = _fallback_urls(URL + "&fallback_count=2")
        self.assertIn("sig=a%2Fb%2Bz", backup)
        self.assertEqual(backup.count("fallback_count="), 1)
        self.assertTrue(backup.endswith("fallback_count=1"))


if __name__ == "__main__":
    unittest.main()

"""Use YouTube's advertised backup CDN when the primary is unreachable.

Workaround for https://github.com/yt-dlp/yt-dlp/issues/1986. Load this
postprocessor at before_dl, after format selection, for video and audio.
"""

import re
import time
from urllib.parse import parse_qs, unquote, urlsplit, urlunsplit

from yt_dlp.networking import Request
from yt_dlp.networking.exceptions import HTTPError, SSLError, TransportError
from yt_dlp.postprocessor.common import PostProcessor


def _fallback_urls(url):
    """Keep the signed query intact; only use CDN names advertised in mn."""
    parsed = urlsplit(url)
    match = re.fullmatch(r"(rr?\d+)---(sn-[a-z0-9-]+)\.googlevideo\.com", parsed.netloc)
    if parsed.scheme != "https" or parsed.path != "/videoplayback" or not match:
        return []
    params = parse_qs(parsed.query)
    names = params.get("mn", [])
    if len(names) != 1:
        return []
    names = list(dict.fromkeys(names[0].split(",")))
    if match[2] not in names:
        return []
    # fvip names the video server in the backup CDN. A primary GGC's rr1/rr2
    # number can redirect elsewhere; also retain it as an alternate route.
    prefixes = [match[1]]
    fvip = params.get("fvip", [])
    if len(fvip) == 1 and re.fullmatch(r"[1-9][0-9]?", fvip[0]):
        prefixes = list(dict.fromkeys([f"r{fvip[0]}", *prefixes]))
    query = "&".join(
        part for part in parsed.query.split("&")
        if unquote(part.partition("=")[0]) != "fallback_count"
    )
    backups = []
    for name in names:
        if name == match[2] or not re.fullmatch(r"sn-[a-z0-9-]+", name):
            continue
        for prefix in prefixes:
            host = f"{prefix}---{name}.googlevideo.com"
            backups.append(urlunsplit(parsed._replace(
                netloc=host, query=f"{query}&fallback_count={len(backups) + 1}")))
            if len(backups) == 3:
                return backups
    return backups


class YoutubeCdnFallbackPP(PostProcessor):
    def __init__(self, downloader=None, timeout=3):
        super().__init__(downloader)
        self.timeout = float(timeout)

    def _probe(self, url, headers):
        # Request reuses HTTPHeaderDict instances. Copy so the probe's Range
        # cannot leak into the real download and override its chunking/resume.
        request = Request(url, headers=dict(headers), extensions={"timeout": self.timeout})
        request.headers["Range"] = "bytes=0-1023"
        with self._downloader.urlopen(request) as response:
            # Read at most 1 KiB, including when a server ignores Range.
            return response.status in (200, 206) and bool(response.read(1024))

    def run(self, info):
        if info.get("extractor_key") != "Youtube" and info.get("extractor") != "youtube":
            return [], info
        for fmt in info.get("requested_formats") or [info]:
            if fmt.get("protocol") != "https":
                continue
            url = fmt.get("url", "")
            backups = _fallback_urls(url)
            if not backups:
                continue
            # before_dl runs before the downloader's normal availability wait.
            # YouTube returns 403 if even a range probe arrives before this time.
            wait = (fmt.get("available_at") or info.get("available_at") or 0) - time.time()
            if wait > 0:
                self.to_screen(f"Waiting {wait:.2f} seconds for YouTube media availability")
                time.sleep(wait)
            headers = fmt.get("http_headers") or info.get("http_headers") or {}
            try:
                self._probe(url, headers)
                continue
            except HTTPError as error:
                # Authentication/HTTP errors are not connectivity failures.
                error.close()
                continue
            except SSLError:
                # Do not work around certificate verification failures.
                continue
            except TransportError:
                pass
            primary = urlsplit(url).hostname
            failures = []
            for backup in backups:
                host = urlsplit(backup).hostname
                try:
                    if not self._probe(backup, headers):
                        failures.append(f"{host}: empty response")
                        continue
                except HTTPError as error:
                    failures.append(f"{host}: HTTP {error.status}")
                    error.close()
                    continue
                except TransportError as error:
                    failures.append(f"{host}: {type(error).__name__}")
                    continue
                fmt["url"] = backup
                self.to_screen(
                    f"{primary} unreachable; using {urlsplit(backup).hostname} "
                    f"for format {fmt.get('format_id', 'unknown')}")
                break
            else:
                self.report_warning(
                    f"No reachable backup CDN for {primary}; keeping original URL "
                    f"({'; '.join(failures)})")
        return [], info

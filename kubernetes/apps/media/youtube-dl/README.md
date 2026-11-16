# MeTube CDN fallback

The November 16, 2026 failures were TCP connection timeouts to YouTube's
primary media CDN (`rr1/rr2---sn-8pxuuxahv1-52al.googlevideo.com`,
`197.218.22.140/141`). They reproduced from both the pod and the Mac,
including with the older November 10 MeTube image. Metadata extraction
worked, and Firewalla showed no blocked flows. The precise upstream
network fault is unknown.

YouTube's signed media URL advertised an alternate CDN in its `mn` query
parameter. The alternate returned HTTP 206 for both video and audio in
under one second. yt-dlp does not automatically use this fallback;
see [upstream issue 1986](https://github.com/yt-dlp/yt-dlp/issues/1986).

`app/youtube_cdn_fallback.py` is a yt-dlp postprocessor mounted from a
ConfigMap into the supported system plugin directory. `YTDL_OPTIONS`
runs it at `before_dl`, after video/audio format selection. It probes
each selected HTTPS stream with a one-byte range request and a three-second
socket timeout. Only a transport failure triggers probing of the alternate
Googlevideo CDN names in that URL's `mn` parameter. The signed query,
request headers, and TLS verification are preserved. HTTP/authentication
and primary certificate errors are left to the normal downloader.

There are no fixed IP overrides or VPN requirements. Healthy primary
servers continue to be used. Other websites and HLS streams are unchanged.
The existing Reloader annotation restarts MeTube when the ConfigMap changes.
The 2 GiB memory limit is retained because the previous 1 GiB limit caused
OOM kills during playlist downloads.

Validation (tests are not included in the ConfigMap):

```sh
uv run --no-project --with yt-dlp==2026.10.26 python -B -m unittest discover -s kubernetes/apps/media/youtube-dl/app -p 'test_*.py' -v
PATH=/opt/homebrew/opt/helm@3/bin:$PATH uvx --from flux-local==8.1.0 flux-local test --enable-helm --all-namespaces 'kubernetes/flux/cluster::youtube-dl' -v
```

To remove the workaround after upstream implements CDN fallback, remove
the `YoutubeCdnFallback` postprocessor entry, the `cdn-fallback` volume,
and the ConfigMap generator together.

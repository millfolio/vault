"""httputil_test — unit tests for the HTTP response builders + host allow-list
(httputil.mojo).

Builds + runs as a plain Mojo program (flare only, no privacy_box): `pixi run
test-httputil`. Covers content-type guessing, host extraction, the DNS-rebinding
allow-list (incl. the MILLFOLIO_ALLOWED_HOSTS knob), the canned error responses
(401/403) + their headers, the CORS scaffolding (methods/headers set, Allow-Origin
deliberately NOT), and static-file serving (200 with content-type, 404 when
missing). Uses a temp file for _serve_file and rm's it at the end.
"""

from std.os import setenv, remove
from std.os.path import exists

from flare.prelude import *

from httputil import (
    _content_type,
    _serve_file,
    _cors,
    _forbidden,
    _extract_host,
    _host_allowed,
    unauthorized,
)


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def expect_eq(got: String, want: String, what: String) raises:
    if got != want:
        raise Error("FAIL: " + what + "\n  got:  " + got + "\n  want: " + want)


def main() raises:
    # ── _content_type: extension → MIME, .json before .js, unknown → default ─────
    expect_eq(
        _content_type("app/index.html"),
        "text/html; charset=utf-8",
        "html",
    )
    expect_eq(
        _content_type("bundle.js"),
        "application/javascript; charset=utf-8",
        "js",
    )
    expect_eq(
        _content_type("data.json"),
        "application/json; charset=utf-8",
        "json (checked before .js)",
    )
    expect_eq(_content_type("style.css"), "text/css; charset=utf-8", "css")
    expect_eq(_content_type("logo.svg"), "image/svg+xml", "svg")
    # No png branch → default; same for any unknown extension.
    expect_eq(
        _content_type("photo.png"),
        "application/octet-stream",
        "png → default",
    )
    expect_eq(
        _content_type("archive.zip"),
        "application/octet-stream",
        "unknown → default",
    )

    # ── _extract_host: strip scheme / path / IPv6 brackets / :port ───────────────
    expect_eq(
        _extract_host("http://localhost:5173"), "localhost", "scheme+port"
    )
    expect_eq(_extract_host("127.0.0.1:10000"), "127.0.0.1", "host:port")
    expect_eq(_extract_host("[::1]:10000"), "::1", "IPv6 bracketed + port")
    expect_eq(_extract_host("localhost"), "localhost", "bare host")
    expect_eq(
        _extract_host("http://example.com/some/path"),
        "example.com",
        "scheme + path stripped",
    )
    expect_eq(_extract_host(""), "", "missing header → empty")

    # ── _host_allowed: loopback names + empty allowed; else denied ───────────────
    _ = setenv("MILLFOLIO_ALLOWED_HOSTS", "", True)
    expect(_host_allowed(""), "empty host allowed (no rebinding vector)")
    expect(_host_allowed("localhost"), "localhost allowed")
    expect(_host_allowed("127.0.0.1"), "127.0.0.1 allowed")
    expect(_host_allowed("::1"), "::1 allowed")
    expect(not _host_allowed("evil.example.com"), "arbitrary host denied")
    # Opt-in extra hosts via the env knob (e.g. a Tailscale MagicDNS name).
    _ = setenv("MILLFOLIO_ALLOWED_HOSTS", "box.ts.net, other.local", True)
    expect(_host_allowed("box.ts.net"), "env-allowed host accepted")
    expect(_host_allowed("other.local"), "second env-allowed host accepted")
    expect(not _host_allowed("nope.ts.net"), "host not in env list denied")
    _ = setenv("MILLFOLIO_ALLOWED_HOSTS", "", True)

    # ── unauthorized: 401 + JSON content-type ────────────────────────────────────
    var u = unauthorized()
    expect(u.status == 401, "unauthorized → 401")
    expect_eq(
        u.headers.get("Content-Type"),
        "application/json",
        "401 content-type is json",
    )

    # ── _forbidden: 403, text/plain, NO CORS Allow-Origin header ─────────────────
    var f = _forbidden()
    expect(f.status == 403, "forbidden → 403")
    expect_eq(
        f.headers.get("Content-Type"),
        "text/plain",
        "403 content-type text/plain",
    )
    expect(
        not f.headers.contains("Access-Control-Allow-Origin"),
        "403 carries no Allow-Origin (cross-origin can't read body)",
    )

    # ── _cors: sets methods/headers, but NOT Allow-Origin ────────────────────────
    var c = _cors(ok("hi"))
    expect(
        c.headers.contains("Access-Control-Allow-Methods"),
        "CORS methods header present",
    )
    expect(
        c.headers.contains("Access-Control-Allow-Headers"),
        "CORS headers header present",
    )
    expect(
        not c.headers.contains("Access-Control-Allow-Origin"),
        "CORS does NOT set Allow-Origin (Api.serve echoes the origin)",
    )

    # ── _serve_file: 200 + content-type when present, 404 when missing ───────────
    var tmp = "/tmp/millfolio-httputil-test.txt"
    with open(tmp, "w") as fh:
        fh.write("hello world")
    var served = _serve_file(tmp, "text/plain; charset=utf-8")
    expect(served.status == 200, "existing file served 200")
    expect_eq(served.text(), "hello world", "served body matches file")
    expect_eq(
        served.headers.get("Content-Type"),
        "text/plain; charset=utf-8",
        "served content-type set",
    )
    var missing = _serve_file("/tmp/millfolio-httputil-nope.txt", "text/plain")
    expect(missing.status == 404, "missing file → 404")

    if exists(tmp):
        remove(tmp)

    print("httputil_test: OK")

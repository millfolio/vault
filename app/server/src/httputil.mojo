"""httputil — HTTP response builders + host/origin allow-listing.

The small, self-contained HTTP helpers: canned error responses (401/403), the
CORS scaffolding, content-type guessing, static file serving, and the
DNS-rebinding host allow-list. Depends only on flare + the stdlib (no `osutil`),
so it stays an independent leaf module.

Pure moves out of server.mojo — behaviour is identical.
"""

from std.os import getenv

from flare.prelude import *


def unauthorized(msg: String = "Unauthorized") -> Response:
    """A 401 (mirrors flare's `bad_request`)."""
    var resp = Response(
        status=401, reason="Unauthorized", body=List[UInt8](msg.as_bytes())
    )
    try:
        resp.headers.set("Content-Type", "application/json")
    except:
        pass
    return resp^


def _content_type(path: String) -> String:
    """Guess a Content-Type from the file extension. `.json` is checked before
    `.js` (".json" contains ".js")."""
    if path.find(".json") != -1:
        return String("application/json; charset=utf-8")
    if path.find(".js") != -1:
        return String("application/javascript; charset=utf-8")
    if path.find(".css") != -1:
        return String("text/css; charset=utf-8")
    if path.find(".svg") != -1:
        return String("image/svg+xml")
    if path.find(".html") != -1:
        return String("text/html; charset=utf-8")
    return String("application/octet-stream")


def _serve_file(path: String, content_type: String) raises -> Response:
    """Read a file under the web root and return it (404 if missing)."""
    var content: String
    try:
        with open(path, "r") as f:
            content = f.read()
    except:
        return not_found(path)
    var r = ok(content)
    try:
        r.headers.set("Content-Type", content_type)
    except:
        pass
    return r^


def _cors(var resp: Response) -> Response:
    """CORS scaffolding for the local web app (a different origin/port in dev).

    Deliberately does NOT set `Access-Control-Allow-Origin` — that is added by
    `Api.serve` *after* the origin has been allow-listed, so it echoes the
    specific caller origin instead of a wildcard `*`. A wildcard here would let
    ANY website the user visits read this API's responses (vault filenames,
    transactions, history) cross-origin; see `_host_allowed`."""
    try:
        resp.headers.set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        resp.headers.set("Access-Control-Allow-Headers", "Content-Type")
    except:
        pass
    return resp^


def _forbidden(msg: String = "Forbidden") -> Response:
    """A 403 with NO CORS headers, so a cross-origin caller can't read the body.
    """
    var resp = Response(
        status=403, reason="Forbidden", body=List[UInt8](msg.as_bytes())
    )
    try:
        resp.headers.set("Content-Type", "text/plain")
    except:
        pass
    return resp^


def _extract_host(raw: String) -> String:
    """The bare host of a `Host`/`Origin` header value: strip the scheme, any
    path, IPv6 brackets, and the `:port`. `http://localhost:5173` → `localhost`,
    `[::1]:10000` → `::1`, `127.0.0.1:10000` → `127.0.0.1`."""
    var s = raw
    var sch = s.find("://")
    if sch != -1:
        s = String(s[byte = sch + 3 :])
    var slash = s.find("/")
    if slash != -1:
        s = String(s[byte=:slash])
    if s.startswith("["):
        var rb = s.find("]")
        if rb != -1:
            return String(s[byte=1:rb])
    var colon = s.find(":")
    if colon != -1:
        s = String(s[byte=:colon])
    return s^


def _host_allowed(h: String) raises -> Bool:
    """Is this host a loopback name we serve on? Empty (HTTP/1.0 / no header) is
    allowed — it isn't a browser DNS-rebinding vector. Extra hostnames (e.g. a
    Tailscale MagicDNS name for `mill start`'s `tailscale serve`) can be opted in
    via `MILLFOLIO_ALLOWED_HOSTS` (comma-separated)."""
    if h == "" or h == "localhost" or h == "127.0.0.1" or h == "::1":
        return True
    var extra = String(getenv("MILLFOLIO_ALLOWED_HOSTS", "").strip())
    if extra != "":
        var parts = extra.split(",")
        for i in range(len(parts)):
            if String(parts[i].strip()) == h:
                return True
    return False

"""server — the millfolio app backend over HTTP (flare).

Migrated from headgate/src/server.mojo. The vault brains stay in headgate; this
server imports them as a library via `-I ../../headgate/src` (build wired in
pixi.toml + ../../.github/workflows/server.yml). Runs the SAME vault orchestrator
the CLI does, on localhost:10000, behind:

    POST /chat   { "message": <question> }  ->  { "reply": <answer> }
    GET  /health
    OPTIONS *    (CORS preflight, so a web app on another port can call us)

Single-threaded reactor — one task in flight at a time. The orchestrator lives
in a heap `MillfolioState` reached through a pointer so the borrowed-self handler
can still run `mut` codegen.

VAULT-ONLY: `/chat` always runs the private-vault codegen loop (`run_vault_task`)
over the resolved vault dir.

PHASE 1 (this file): behavior-preserving lift of the headgate server. The
streaming millfolio protocol (status / approval-request / debug / message events,
see ../../protocol) is the next phase — it needs an event hook in the orchestrator
and a streaming/duplex transport, so it's intentionally NOT here yet.

    pixi run build   # -> build/millfolio-server, listens on 127.0.0.1:10000
"""

from std.memory import alloc
from std.os import getenv

from flare.prelude import *
from flare.http import Handler

from settings import load_config
from wiring import build_vault_orchestrator
from orchestrator import Orchestrator
from vaultcfg import vault_dir as resolve_vault_dir
from json import loads

comptime PORT = 10000


struct MillfolioState(Movable):
    """The vault orchestrator + vault dir, loaded once and reached by the
    (borrowed-self) handler through a pointer so `run_vault_task` can still take
    `mut self`. `/chat` always runs `run_vault_task` over `vault_dir`."""

    var orch: Orchestrator
    var vault_dir: String

    def __init__(out self, var orch: Orchestrator, var vault_dir: String):
        self.orch = orch^
        self.vault_dir = vault_dir^


def _json_escape(s: String) -> String:
    """Quote + escape `s` as a JSON string (control chars dropped to spaces)."""
    var out = String('"')
    for cp in s.codepoints():
        var c = Int(cp)
        if c == 34:
            out += '\\"'
        elif c == 92:
            out += "\\\\"
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif c == 9:
            out += "\\t"
        elif c < 32:
            out += " "
        else:
            out += chr(c)
    out += '"'
    return out


def _extract_message(body: String) -> String:
    """Pull `message` out of a `{ "message": ... }` body (empty on any failure)."""
    try:
        var j = loads(body)
        return j["message"].string_value()
    except:
        return String("")


def _web_root() -> String:
    """The dir holding the built UI. $MILLFOLIO_WEB_DIR (an ABSOLUTE path set by the
    launcher) so serving never depends on the process's cwd; falls back to the
    cwd-relative web/dist for `pixi run`/dev."""
    return getenv("MILLFOLIO_WEB_DIR", "web/dist")


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
    """Allow the local web app (a different origin/port) to call this API."""
    try:
        resp.headers.set("Access-Control-Allow-Origin", "*")
        resp.headers.set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        resp.headers.set("Access-Control-Allow-Headers", "Content-Type")
    except:
        pass
    return resp^


@fieldwise_init
struct Api(Handler, Copyable, Movable):
    var st: UnsafePointer[MillfolioState, MutExternalOrigin]

    def serve(self, req: Request) raises -> Response:
        var path = req.url
        # CORS preflight (compare the raw method string — no Method.OPTIONS dep).
        if req.method == "OPTIONS":
            return _cors(Response(status=204, reason="No Content"))
        if req.method == Method.POST and path == "/chat":
            return self.handle_chat(req)
        if path == "/health":
            return _cors(ok("millfolio ok"))
        # Static web UI — same-origin in production (Vite serves it in dev).
        # Reject path traversal before mapping under web/dist.
        if path.find("..") == -1:
            var root = _web_root()
            if path == "/" or path == "/index.html":
                return _serve_file(root + "/index.html", "text/html; charset=utf-8")
            # Any other path is a built asset — SvelteKit emits /_app/immutable/…
            # (JS/CSS), /_app/version.json, /favicon.svg, etc. Serve it from the web
            # root (404 only if it genuinely isn't there).
            return _serve_file(root + path, _content_type(path))
        return _cors(not_found(path))

    def handle_chat(self, req: Request) raises -> Response:
        ref s = self.st[]
        var msg = _extract_message(req.text())
        if msg == "":
            return _cors(bad_request('{"reply":"(empty message)"}'))
        print("  chat: ", msg, sep="")
        var reply: String
        try:
            # VAULT-ONLY: always the private-vault codegen loop over the vault dir.
            reply = s.orch.run_vault_task(msg, s.vault_dir.copy())
        except e:
            reply = String("error: ") + String(e)
        return _cors(ok_json('{"reply":' + _json_escape(reply) + "}"))


def main() raises:
    var cfg = load_config()

    # VAULT-ONLY: build the vault orchestrator over the resolved vault dir
    # (HEADGATE_VAULT_DIR / $MILLFOLIO_VAULT / $HEADGATE_DATA / ~/millfolio) and route
    # /chat to run_vault_task.
    var vault_dir = resolve_vault_dir()
    print("millfolio server — VAULT mode — vault dir: " + vault_dir)
    var orch = build_vault_orchestrator(cfg, vault_dir)

    var st = MillfolioState(orch^, vault_dir^)
    var sp = alloc[MillfolioState](1)
    sp.init_pointee_move(st^)
    var api = Api(sp)

    print("millfolio server on http://127.0.0.1:", PORT, "  (flare)", sep="")
    print('  POST /chat   { "message": ... } -> { "reply": ... }')
    var srv = HttpServer.bind(SocketAddr.localhost(UInt16(PORT)))
    srv.serve(api^)

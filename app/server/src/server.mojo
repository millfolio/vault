"""server — the millfolio app backend over HTTP (flare).

Migrated from headgate/src/server.mojo. The vault brains stay in headgate; this
server imports them as a library via `-I ../../headgate/src` (build wired in
pixi.toml + ../../.github/workflows/server.yml). Runs the SAME vault orchestrator
the CLI does, on localhost:10000, behind:

    POST /chat       { "message": <question> }  ->  { "reply": <answer> }
    GET  /api/vault  ->  { vaultDir, indexed, stats, files[] }  (the vault view)
    GET  /health
    OPTIONS *        (CORS preflight, so a web app on another port can call us)

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
from std.os import getenv, listdir, makedirs
from std.os.path import isfile, isdir, getsize

from flare.prelude import *
from flare.http import Handler

from settings import load_config
from wiring import build_vault_orchestrator
from orchestrator import Orchestrator
from vaultcfg import vault_dir as resolve_vault_dir
from json import loads

comptime PORT = 10000
comptime EMBED_DIM = 1024  # Qwen3-Embedding-0.6B — mirrors vault/core embed.mojo


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


# ── vault view (GET /api/vault) ───────────────────────────────────────────────
# Self-contained, read-only: walk the vault dir + read the index side-table
# (chunks.tsv) and the LanceDB dir on disk — no LanceDB linkage in this binary.
# The file aliasing here mirrors vault/core/src/manifest.mojo EXACTLY (sorted
# names, csv/pdf/md only, alias = "file_<i>") so per-file chunk counts line up
# with the aliases the indexer wrote into chunks.tsv.

def _config_dir() -> String:
    """Where the index lives — mirrors vault/core index.mojo (_config_dir)."""
    return getenv("HOME", ".") + "/.config/millfolio"


def _lower_ascii(s: String) -> String:
    """ASCII-lowercase (enough for file extensions)."""
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 65 and c <= 90:  # 'A'..'Z'
            c += 32
        out += chr(c)
    return out^


def _kind_for_name(name: String) -> String:
    """Vault kind from a filename's extension (csv/pdf/md), else "" to skip.
    Mirrors vault/core manifest so aliases line up with the index."""
    if name.find(".") == -1:
        return String("")
    var parts = name.split(".")
    var ext = _lower_ascii(String(parts[len(parts) - 1]))
    if ext == "csv":
        return String("csv")
    if ext == "pdf":
        return String("pdf")
    if ext == "md" or ext == "markdown":
        return String("md")
    return String("")


def _sort_names(mut names: List[String]):
    """In-place insertion sort so aliases are stable across runs (as manifest)."""
    for i in range(1, len(names)):
        var j = i
        while j > 0 and names[j - 1] > names[j]:
            var tmp = names[j - 1].copy()
            names[j - 1] = names[j].copy()
            names[j] = tmp^
            j -= 1


def _dir_size(path: String) -> Int:
    """Recursive byte size of a file or directory tree (0 if missing)."""
    try:
        if isfile(path):
            return getsize(path)
        if isdir(path):
            var total = 0
            var entries = listdir(path)
            for i in range(len(entries)):
                total += _dir_size(path + "/" + String(entries[i]))
            return total
    except:
        pass
    return 0


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
        if path == "/api/vault":
            return self.handle_vault()
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

    def handle_vault(self) raises -> Response:
        """The vault view: the vault dir's indexable files + index stats, as JSON.

        Read-only. Per-file chunk counts come from the index side-table
        (chunks.tsv, written by `mill index`); files with no index entry report
        0 chunks. db size is the on-disk LanceDB dir."""
        ref s = self.st[]
        var vault_dir = s.vault_dir.copy()
        var config_dir = _config_dir()
        var tsv_path = config_dir + "/chunks.tsv"
        var db_path = config_dir + "/index.db"

        # Per-alias chunk counts from the index side-table (alias is column 1).
        var counts = Dict[String, Int]()
        var total_chunks = 0
        var indexed = isfile(tsv_path)
        if indexed:
            var text: String
            with open(tsv_path, "r") as f:
                text = f.read()
            var lines = text.split("\n")
            for i in range(len(lines)):
                var line = String(lines[i])
                if line.byte_length() == 0:
                    continue
                var cols = line.split("\t")
                if len(cols) < 3:
                    continue
                var falias = String(cols[1])
                total_chunks += 1
                if falias in counts:
                    counts[falias] = counts[falias] + 1
                else:
                    counts[falias] = 1

        # Current vault files, aliased exactly like vault/core's manifest
        # (sorted-name order; csv/pdf/md only) so chunk counts line up.
        makedirs(vault_dir, exist_ok=True)
        var raw = listdir(vault_dir)
        var names = List[String]()
        for i in range(len(raw)):
            names.append(String(raw[i]))
        _sort_names(names)

        var files_json = String("[")
        var file_count = 0
        var idx = 0
        for i in range(len(names)):
            var name = names[i].copy()
            var path = vault_dir + "/" + name
            if not isfile(path):
                continue
            var kind = _kind_for_name(name)
            if kind == "":
                continue
            var falias = String("file_") + String(idx)
            var sz: Int
            try:
                sz = getsize(path)
            except:
                sz = 0
            var chunks = 0
            if falias in counts:
                chunks = counts[falias]
            if file_count > 0:
                files_json += ","
            files_json += "{"
            files_json += '"alias":' + _json_escape(falias) + ","
            files_json += '"name":' + _json_escape(name) + ","
            files_json += '"kind":' + _json_escape(kind) + ","
            files_json += '"sizeBytes":' + String(sz) + ","
            files_json += '"chunks":' + String(chunks)
            files_json += "}"
            file_count += 1
            idx += 1
        files_json += "]"

        var out = String("{")
        out += '"vaultDir":' + _json_escape(vault_dir) + ","
        out += '"configDir":' + _json_escape(config_dir) + ","
        out += '"indexed":' + ("true" if indexed else "false") + ","
        out += '"embeddingDim":' + String(EMBED_DIM) + ","
        out += '"fileCount":' + String(file_count) + ","
        out += '"indexedFileCount":' + String(len(counts)) + ","
        out += '"chunkCount":' + String(total_chunks) + ","
        out += '"dbSizeBytes":' + String(_dir_size(db_path)) + ","
        out += '"files":' + files_json
        out += "}"
        return _cors(ok_json(out))


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
    print("  GET  /api/vault  -> vault files + index stats")
    var srv = HttpServer.bind(SocketAddr.localhost(UInt16(PORT)))
    srv.serve(api^)

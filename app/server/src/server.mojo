"""server — the millfolio app backend over HTTP (flare).

Migrated from headgate/src/server.mojo. The vault brains stay in headgate; this
server imports them as a library via `-I ../../headgate/src` (build wired in
pixi.toml + ../../.github/workflows/server.yml). Runs the SAME vault orchestrator
the CLI does, on localhost:10000, behind:

    POST /chat        { "message": <question> }  ->  { "reply": <answer> }
    POST /api/search  { "query": ..., "k": N }   ->  { "hits": [...] }
    GET  /api/vault   ->  { vaultDir, indexed, stats, files[] }  (the vault view)
    GET  /health
    WS   (Upgrade)    ->  streaming chat (status/approval/debug/message events)
    OPTIONS *         (CORS preflight, so a web app on another port can call us)

Single-threaded reactor — one task in flight at a time. The orchestrator lives
in a heap `MillfolioState` reached through a pointer so the borrowed-self handler
can still run `mut` codegen.

VAULT-ONLY: `/chat` always runs the private-vault codegen loop (`run_vault_task`)
over the resolved vault dir.

ONE PORT: the unary HTTP `Api` handler AND the streaming WebSocket chat (`on_connect`)
share a single :10000 listener — flare's `HttpServer.serve(handler, ws_handler)`
upgrades requests carrying the WebSocket headers and routes everything else to the
HTTP handler. (Previously the WS stream needed a second port; flare couldn't
multiplex them.)

    pixi run build   # -> build/millfolio-server, listens on 127.0.0.1:10000
"""

from std.memory import alloc
from std.os import getenv, listdir, makedirs
from std.os.path import isfile, isdir, getsize

from flare.prelude import *
from flare.http import Handler
from flare.ws import WsConnection, WsOpcode, WsCloseCode

from std.ffi import external_call, c_char

from settings import load_config
from wiring import build_vault_orchestrator
from orchestrator import Orchestrator, PROGRESS_SENTINEL, STAT_SENTINEL
from runqueue import runq_take, runq_peek, runq_done, runq_reset
from vaultcfg import vault_dir as resolve_vault_dir
from sandbox import _spawn_capture
from events import field, status, debug_event, approval, message, error_event
from json import loads

comptime DEFAULT_PORT = 10000
comptime EMBED_DIM = 1024  # Qwen3-Embedding-0.6B — mirrors vault/core embed.mojo


def _port() raises -> Int:
    """The HTTP/WS listen port — MILLFOLIO_PORT (digits) overrides, else 10000. Lets a
    second instance (e.g. the demo) coexist on the same box without a rebuild."""
    var s = String(getenv("MILLFOLIO_PORT", "").strip())
    if s == "":
        return DEFAULT_PORT
    var n = 0
    var any = False
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 48 and c <= 57:
            n = n * 10 + (c - 48)
            any = True
        else:
            break
    return n if (any and n > 0 and n <= 65535) else DEFAULT_PORT


def _workers() raises -> Int:
    """Worker thread count — MILLFOLIO_WORKERS (digits) overrides, else 1. The default
    keeps the real product single-threaded (one local user); the demo sets it >1 so
    concurrent visitors don't block each other at codegen/approval. The actual sandboxed
    run stays serial regardless — see the run-queue (flock) in `on_connect`."""
    var s = String(getenv("MILLFOLIO_WORKERS", "").strip())
    if s == "":
        return 1
    var n = 0
    var any = False
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 48 and c <= 57:
            n = n * 10 + (c - 48)
            any = True
        else:
            break
    return n if (any and n > 0 and n <= 256) else 1


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


def _atoi(s: String) -> Int:
    """Parse a non-negative integer (digits only)."""
    var n = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 48 and c <= 57:
            n = n * 10 + (c - 48)
    return n


def _tsv_unescape(s: String) raises -> String:
    """Inverse of vault/core's TSV escaping (manifest stores escaped name/dir)."""
    var out = String("")
    var bytes = s.as_bytes()
    var i = 0
    while i < len(bytes):
        var c = Int(bytes[i])
        if c == 92 and i + 1 < len(bytes):  # backslash
            var n = Int(bytes[i + 1])
            if n == 116:
                out += "\t"; i += 2; continue
            elif n == 110:
                out += "\n"; i += 2; continue
            elif n == 114:
                out += "\r"; i += 2; continue
            elif n == 92:
                out += "\\"; i += 2; continue
        out += chr(c)
        i += 1
    return out^


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
    if ext == "docx":
        return String("docx")
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
    var st: UnsafePointer[MillfolioState, MutUntrackedOrigin]

    def serve(self, req: Request) raises -> Response:
        var path = req.url
        # CORS preflight (compare the raw method string — no Method.OPTIONS dep).
        if req.method == "OPTIONS":
            return _cors(Response(status=204, reason="No Content"))
        if req.method == Method.POST and path == "/chat":
            return self.handle_chat(req)
        if path == "/api/vault":
            return self.handle_vault()
        # Document viewer: /api/doc?alias=file_N streams the raw indexed file
        # (alias-gated via the manifest — no caller-supplied path, so no traversal).
        if path == "/api/doc" or (path.find("/api/doc?") == 0):
            return self.handle_doc(req)
        if req.method == Method.POST and path == "/api/search":
            return self.handle_search(req)
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
        """The vault view: the INDEXED files + index stats, read from the engine's
        manifest.tsv (written by `mill index`). Reflects what was actually indexed
        — not a live walk of the served dir — so it's correct even when the indexed
        folder differs from the served vault dir (both are surfaced, plus a
        `dirMismatch` flag the UI can warn on). Read-only."""
        ref s = self.st[]
        var served_dir = s.vault_dir.copy()
        var config_dir = _config_dir()
        var manifest_path = config_dir + "/manifest.tsv"
        var db_path = config_dir + "/index.db"

        var indexed = isfile(manifest_path)
        var source_dir = String("")
        var files_json = String("[")
        var file_count = 0
        var total_chunks = 0
        if indexed:
            var text: String
            with open(manifest_path, "r") as f:
                text = f.read()
            var lines = text.split("\n")
            for i in range(len(lines)):
                var line = String(lines[i])
                if line.byte_length() == 0:
                    continue
                var cols = line.split("\t")
                # Meta row: #meta <next_id> <next_alias> <source_dir>.
                if String(cols[0]) == "#meta":
                    if len(cols) >= 4:
                        source_dir = _tsv_unescape(String(cols[3]))
                    continue
                # File row: alias name kind size sha256 id_start chunk_count.
                if len(cols) < 7:
                    continue
                var falias = String(cols[0])
                var name = _tsv_unescape(String(cols[1]))
                var kind = String(cols[2])
                var sz = _atoi(String(cols[3]))
                var chunks = _atoi(String(cols[6]))
                total_chunks += chunks
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
        files_json += "]"

        var has_index = indexed and file_count > 0
        var mismatch = has_index and source_dir != "" and source_dir != served_dir

        var out = String("{")
        out += '"vaultDir":' + _json_escape(served_dir) + ","
        out += '"sourceDir":' + _json_escape(source_dir) + ","
        out += '"dirMismatch":' + ("true" if mismatch else "false") + ","
        out += '"configDir":' + _json_escape(config_dir) + ","
        out += '"indexed":' + ("true" if has_index else "false") + ","
        out += '"embeddingDim":' + String(EMBED_DIM) + ","
        out += '"fileCount":' + String(file_count) + ","
        out += '"indexedFileCount":' + String(file_count) + ","
        out += '"chunkCount":' + String(total_chunks) + ","
        out += '"dbSizeBytes":' + String(_dir_size(db_path)) + ","
        out += '"files":' + files_json
        out += "}"
        return _cors(ok_json(out))

    def handle_doc(self, req: Request) raises -> Response:
        """Stream a single indexed document for the in-app viewer:
        GET /api/doc?alias=file_N -> the raw file bytes, Content-Type by kind
        (application/pdf / text/csv / text/markdown) so the browser renders it
        inline. FRONTIER-SAFE: the caller passes only the manifest alias; we map
        it to the real path from manifest.tsv (#meta source_dir + the file's
        name). The caller never supplies a path, so there's no traversal — an
        unknown alias is a 404, never a read outside the indexed dir."""
        var want = req.query_param("alias")
        if want == "":
            return _cors(bad_request("missing alias"))
        var manifest_path = _config_dir() + "/manifest.tsv"
        if not isfile(manifest_path):
            return _cors(not_found("no index"))
        var text: String
        with open(manifest_path, "r") as f:
            text = f.read()
        # Resolve alias -> (source_dir, name, kind) from the manifest.
        var source_dir = String("")
        var name = String("")
        var kind = String("")
        var lines = text.split("\n")
        for i in range(len(lines)):
            var line = String(lines[i])
            if line.byte_length() == 0:
                continue
            var cols = line.split("\t")
            if String(cols[0]) == "#meta":
                if len(cols) >= 4:
                    source_dir = _tsv_unescape(String(cols[3]))
                continue
            if len(cols) < 7:
                continue
            if String(cols[0]) == want:
                name = _tsv_unescape(String(cols[1]))
                kind = String(cols[2])
        if name == "":
            return _cors(not_found("unknown alias"))

        var file_path = source_dir + "/" + name
        var data: List[UInt8]
        try:
            with open(file_path, "r") as f:
                data = f.read_bytes()
        except:
            return _cors(not_found(name))

        var ctype = String("application/octet-stream")
        if kind == "pdf":
            ctype = String("application/pdf")
        elif kind == "csv":
            ctype = String("text/csv; charset=utf-8")
        elif kind == "md":
            ctype = String("text/markdown; charset=utf-8")
        elif kind == "docx":
            # Browsers can't render .docx inline — the viewer's "Open ↗" downloads it.
            ctype = String(
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            )
        var r = Response(status=200, reason="OK", body=data^)
        try:
            r.headers.set("Content-Type", ctype)
            # inline -> render in the viewer rather than triggering a download.
            r.headers.set("Content-Disposition", 'inline; filename="' + name + '"')
        except:
            pass
        return _cors(r^)

    def handle_search(self, req: Request) raises -> Response:
        """Semantic vault search: POST {"query": ..., "k": N} -> {"hits":[{alias,
        score,text}]}. The LanceDB/embedding work stays OUT of this server — we
        shell the `millfolio` engine binary via its run-script (MILLFOLIO_RUN_SCRIPT,
        set by the launcher) and have it write the JSON to a file (so captured
        stderr noise can't corrupt it), then return that file's contents."""
        var query = String("")
        var k = 5
        try:
            var j = loads(req.text())
            query = j["query"].string_value()
            try:
                k = Int(j["k"].int_value())
            except:
                k = 5
        except:
            query = String("")
        if query == "":
            return _cors(bad_request('{"error":"empty query","hits":[]}'))
        var run_script = getenv("MILLFOLIO_RUN_SCRIPT", "")
        if run_script == "":
            return _cors(ok_json('{"error":"search unavailable — engine runner not configured","hits":[]}'))

        var cfg = _config_dir()
        var out_json = cfg + "/.search_out.json"
        var cap = cfg + "/.search_cap.txt"
        var argv = List[String]()
        argv.append(String("/bin/bash"))
        argv.append(run_script)
        argv.append(String("search"))
        argv.append(query)
        argv.append(String(k))
        argv.append(String("--json"))
        argv.append(String("--out"))
        argv.append(out_json)
        var rc = _spawn_capture(argv, cap)
        if rc != 0:
            return _cors(ok_json(
                '{"error":"search failed (exit ' + String(rc) + ')","hits":[]}'
            ))
        var hits = String("[]")
        try:
            with open(out_json, "r") as f:
                hits = f.read()
        except:
            hits = String("[]")
        return _cors(ok_json('{"hits":' + hits + "}"))


def _usleep(usec: Int):
    """Sleep `usec` microseconds (libc usleep) — the gap between run-output polls
    in the streaming loop, so we don't busy-spin while the sandboxed child runs."""
    _ = external_call["usleep", Int](Int(usec))


def _progress_label(line: String) raises -> String:
    """Strip the progress sentinel off a captured stdout line, leaving the message
    the generated program passed to `progress(...)`."""
    return String(line.removeprefix(PROGRESS_SENTINEL))


def _secs1(ms: Float64) -> String:
    """Milliseconds → seconds with one decimal: 38234.5 -> "38.2s"."""
    var tenths = Int(ms / 100.0 + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10) + "s"


# ── serial run-queue ─────────────────────────────────────────────────────────
# The FIFO ticket queue (one sandboxed run at a time across workers, with each
# waiter's live position) lives in runqueue.mojo and is unit-tested by
# test/runqueue_test.mojo. A run is ALSO time-bounded here (the child is killed past
# _RUN_MAX_ITERS) so one slow/stuck program can't stall the whole queue.
comptime _SIGKILL: Int = 9
comptime _RUN_MAX_ITERS: Int = 1000   # ~120s at 120ms/poll — kill a run past this


def on_connect(mut conn: WsConnection) raises:
    """Streaming chat over the SAME :10000 listener — flare upgrades the WebSocket
    request; every other request stays on the unary HTTP path (the `Api` handler).
    One WS connection = one chat session: stream a status/debug event per stage and
    gate the sandbox run on the user's approval (the blocking `recv()` IS the pause).

    flare's WS handler is THIN (non-capturing), so it builds the orchestrator per
    connection — fine for a local single-user server. Events are ServerEvent JSON,
    one per text frame (see ../../protocol/events.ts / events.mojo)."""
    var frame = conn.recv()
    if frame.opcode == WsOpcode.CLOSE:
        return
    var question = field(frame.text_payload(), "text")
    if question == "":
        conn.send_text(error_event("empty or malformed ask"))
        conn.close(WsCloseCode.NORMAL)
        return
    var ticket = -1  # our run-queue ticket; >= 0 once we've entered (see runqueue.mojo)
    try:
        var cfg = load_config()
        var vault_dir = resolve_vault_dir()
        var orch = build_vault_orchestrator(cfg, vault_dir)

        conn.send_text(status("manifest", "Aliasing vault manifest", "running"))
        var manifest = orch.vault_manifest(vault_dir)
        conn.send_text(debug_event("manifest", "Frontier-safe manifest (aliases only)", manifest, "text"))
        conn.send_text(status("manifest", "Aliasing vault manifest", "done"))

        conn.send_text(status("codegen", "Writing the program", "running"))
        var code = orch.vault_codegen(question, manifest)
        conn.send_text(debug_event("codegen", "Generated program", code, "mojo"))
        conn.send_text(status("codegen", "Writing the program", "done"))

        conn.send_text(status("run", "Run the generated program over your vault?", "awaiting-approval"))
        conn.send_text(approval("run", "Run the generated program over your vault?", code))
        var decision = conn.recv()
        if decision.opcode == WsOpcode.CLOSE or field(decision.text_payload(), "type") != "approve":
            conn.send_text(status("run", "Run rejected", "error"))
            conn.send_text(message("Okay — I won't run that. Tell me how you'd like to adjust it."))
            conn.close(WsCloseCode.NORMAL)
            return

        # Enter the serial run-queue — AFTER approval. With multiple workers several
        # visitors reach here at once; only ONE runs at a time (shared scratch path +
        # heavy build + on-device inference). Take a FIFO ticket and wait our turn,
        # streaming our live position so the wait isn't a blind spinner.
        ticket = runq_take()
        var st = runq_peek()
        # Always surface the queue position — even "1 of 1" for a solo run — so the
        # serial run-queue is visible, and update it live while we wait our turn.
        var waited = 0
        while True:
            var ahead = ticket - st[0]   # people in front of us
            var qlen = st[1] - st[0]     # total waiting + running, including us
            if ahead <= 0:
                conn.send_text(status("queue",
                    "Position 1 of " + String(qlen) + " — running now", "done"))
                break
            waited += 1
            if waited > 600:  # ~300s — assume the queue stalled; take our turn anyway
                conn.send_text(status("queue", "Starting now (queue wait timed out)", "done"))
                break
            conn.send_text(status("queue",
                "Position " + String(ahead + 1) + " of " + String(qlen) + " — waiting…",
                "running"))
            _usleep(500_000)  # re-check twice a second
            st = runq_peek()

        # Approved — surface the two real phases SEPARATELY so the wait isn't one
        # opaque "working": first compile the generated Mojo, then run it over the
        # vault (the read + ask_local loop — the long part). The run is now spawned
        # NON-BLOCKING and we poll its captured stdout, streaming each `progress(…)`
        # line the generated program emits as a live "execute" status update (same
        # stepId, so the UI updates ONE line in place) instead of a frozen spinner.
        conn.send_text(status("run", "Approved — running", "done"))
        conn.send_text(status("compile", "Compiling the generated program", "running"))
        orch.vault_build(code)
        conn.send_text(status("compile", "Compiling the generated program", "done"))
        conn.send_text(status("execute",
            "Running it locally over your vault…",
            "running"))
        var h = orch.vault_run_start(vault_dir)
        var n_ask = 0
        var ms_ask = 0.0
        var n_search = 0
        var ms_search = 0.0
        var running = True
        var iters = 0
        var timed_out = False
        while running:
            # Reap FIRST, then poll — so the final poll (once the child has exited)
            # still drains every progress/stat line written just before it died.
            running = orch.vault_run_reap(h) == -1  # -1 = still running
            var lines = orch.vault_run_poll(h)
            for i in range(len(lines)):
                var ln = lines[i].copy()
                if ln.startswith(PROGRESS_SENTINEL):
                    conn.send_text(status("execute", _progress_label(ln), "running"))
                elif ln.startswith(STAT_SENTINEL):
                    # "<tool>\t<ms>" — accumulate per-engine-call count + duration.
                    var parts = String(ln.removeprefix(STAT_SENTINEL)).split("\t")
                    if len(parts) == 2:
                        var ms = atof(String(parts[1]))
                        if String(parts[0]) == "search":
                            n_search += 1; ms_search += ms
                        else:
                            n_ask += 1; ms_ask += ms
            if running:
                iters += 1
                if iters > _RUN_MAX_ITERS:
                    # A run must not stall the queue — kill a too-slow / stuck child.
                    _ = external_call["kill", Int32](h.pid, Int32(_SIGKILL))
                    timed_out = True
                    running = False
                else:
                    _usleep(120_000)  # 120 ms between polls

        # A one-line summary of the on-device engine calls, before the answer.
        var total = n_ask + n_search
        if total > 0:
            var sum = String("Engine: ") + String(total) + " calls"
            if n_ask > 0:
                sum += " · ask_local ×" + String(n_ask) + " (" + _secs1(ms_ask) + ")"
            if n_search > 0:
                sum += " · search ×" + String(n_search) + " (" + _secs1(ms_search) + ")"
            sum += " · " + _secs1(ms_ask + ms_search) + " total"
            conn.send_text(status("engine", sum, "done"))

        var reply = orch.vault_run_finish(h)
        if timed_out:
            conn.send_text(status("execute", "Stopped — the run exceeded the time limit", "error"))
            conn.send_text(message("That took too long and was stopped. Please try another question."))
        else:
            conn.send_text(status("execute", "Running it locally over your vault", "done"))
            conn.send_text(message(reply))
        runq_done(ticket)  # leave the run slot → next waiter proceeds
        ticket = -1
    except e:
        conn.send_text(error_event(String(e)))
        if ticket >= 0:
            runq_done(ticket)  # release the slot if we died mid-run
    conn.close(WsCloseCode.NORMAL)


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

    var port = _port()
    print("millfolio server on http://127.0.0.1:", port, "  (flare)", sep="")
    print('  POST /chat   { "message": ... } -> { "reply": ... }')
    print("  GET  /api/vault  -> vault files + index stats")
    print("  POST /api/search { query, k } -> ranked hits")
    print("  WS   (Upgrade)   -> streaming chat (status/approval/message events)")
    # One listener serves both: the unary HTTP `Api` handler AND, for requests with
    # the WebSocket Upgrade headers, the streaming `on_connect` chat — no second port.
    # (The 2-arg serve overload is plain-function-only; we use a stateful Handler
    # struct, so set the WS handler on the config and use the Handler-typed serve.)
    runq_reset()  # clear any stale run-queue state from a prior process
    var srv = HttpServer.bind(SocketAddr.localhost(UInt16(port)))
    srv.config.ws_handler = on_connect
    var workers = _workers()
    if workers > 1:
        print(
            "  workers: ", workers,
            " (concurrent connections; the sandboxed run stays serial via the run-queue)",
            sep="",
        )
    # num_workers=1 (default) → single-threaded reactor (real product). >1 → N pthread
    # workers via the multicore Handler-serve; Api is Copyable (shares the state
    # pointer) and config.ws_handler propagates to each worker.
    srv.serve(api^, num_workers=workers)

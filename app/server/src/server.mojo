"""Server — the millfolio app backend over HTTP (flare).

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

from std.memory import alloc, UnsafePointer
from std.os import getenv, listdir, makedirs
from std.os.path import isfile, isdir, getsize

from flare.prelude import *
from flare.http import Handler
from flare.ws import WsConnection, WsOpcode, WsCloseCode

from std.ffi import external_call, c_char, c_int
from std.time import perf_counter_ns

from settings import load_config
from wiring import build_vault_orchestrator
from orchestrator import (
    Orchestrator,
    PROGRESS_SENTINEL,
    STAT_SENTINEL,
    LOCAL_SENTINEL,
    LOCAL_SEP,
)
from transport import DeltaSink
from runqueue import runq_take, runq_peek, runq_done, runq_reset

# The LanceDB-free registry/tags/retag store — the SAME functions the `millfolio`
# CLI uses, so the Tags panel + category editor run in-process (no engine spawn).
from vault.derive.store import (
    tags_report_json,
    read_categories,
    save_categories,
    preview_categories,
    effective_tags,
    effective_tag_descriptions,
)
from vaultcfg import vault_dir as resolve_vault_dir
from sandbox import _spawn_capture
from logging import log
from events import (
    field,
    status,
    tags_event,
    tag_proposal_event,
    debug_event,
    approval,
    message,
    error_event,
    json_escape,
)
from store import ask_record_line, history_records_array, system_json
from json import loads

comptime DEFAULT_PORT = 10000
comptime EMBED_DIM = 1024  # Qwen3-Embedding-0.6B — mirrors vault/core embed.mojo


def _port() raises -> Int:
    """The HTTP/WS listen port — MILLFOLIO_PORT (digits) overrides, else 10000. Lets a
    second instance (e.g. the demo) coexist on the same box without a rebuild.
    """
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
    """Pull `message` out of a `{ "message": ... }` body (empty on any failure).
    """
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
    """Inverse of vault/core's TSV escaping (manifest stores escaped name/dir).
    """
    var out = String("")
    var bytes = s.as_bytes()
    var i = 0
    while i < len(bytes):
        var c = Int(bytes[i])
        if c == 92 and i + 1 < len(bytes):  # backslash
            var n = Int(bytes[i + 1])
            if n == 116:
                out += "\t"
                i += 2
                continue
            elif n == 110:
                out += "\n"
                i += 2
                continue
            elif n == 114:
                out += "\r"
                i += 2
                continue
            elif n == 92:
                out += "\\"
                i += 2
                continue
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
    """In-place insertion sort so aliases are stable across runs (as manifest).
    """
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


def _tags_in_program(code: String) raises -> String:
    """The available category tag NAMES the generated program filters on —
    detected as a quoted literal (`"phone"`) alongside `.tags`. Comma-joined, in
    registry order; "" when the program used no tag (it read each transaction).
    """
    if code.find(".tags") == -1:
        return String("")
    var avail = effective_tags()
    var used = String("")
    for i in range(len(avail)):
        if code.find('"' + avail[i] + '"') != -1:
            if used.byte_length() > 0:
                used += ","
            used += avail[i]
    return used^


def _tag_proposal_in_program(code: String) raises -> List[String]:
    """A reusable-tag suggestion the model emitted as a program comment
    `# SUGGEST_TAG: <name> = <kw>, <kw>` (for a durable, keyword-able category
    that isn't a tag yet — so the next such question is a fast `.tags` filter
    instead of an inline classify). Returns `[name, keywords_csv]` when present,
    well-formed, and NOT already a known tag; `[]` otherwise. Static scan — the
    comment never executes, mirroring `_tags_in_program`."""
    var lines = code.split("\n")
    var marker = String("# SUGGEST_TAG:")
    for i in range(len(lines)):
        var ln = String(lines[i].strip())
        if not ln.startswith(marker):
            continue
        var rest = String(ln.removeprefix(marker).strip())
        var parts = rest.split("=")
        if len(parts) < 2:
            continue
        var name = String(parts[0].strip())
        var kws = String(parts[1].strip())
        if name.byte_length() == 0 or kws.byte_length() == 0:
            continue
        # Skip a suggestion for a tag that already exists (redundant).
        var avail = effective_tags()
        var dup = False
        for a in range(len(avail)):
            if avail[a] == name:
                dup = True
                break
        if dup:
            continue
        var out = List[String]()
        out.append(name^)
        out.append(kws^)
        return out^
    return List[String]()


@fieldwise_init
struct Api(Copyable, Handler, Movable):
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
        # The on-device model name — the UI shows it in the bottom bar.
        if path == "/api/model":
            return _cors(
                ok_json(
                    '{"model":'
                    + json_escape(_model_label())
                    + ',"version":'
                    + json_escape(_app_version())
                    + "}"
                )
            )
        # Accumulated per-question usage (JSONL file, returned verbatim) — the Stats page.
        if path == "/api/stats":
            return self.handle_stats()
        if path == "/api/history":
            return self.handle_history()
        if path == "/api/system":
            return self.handle_system()
        # Category tags: the panel's list (names + keywords + per-tag counts) and
        # the editable registry file. All in-process via vault.derive.store.
        if path == "/api/tags":
            return self.handle_tags()
        if path == "/api/categories/preview":
            return self.handle_categories_preview(req)
        if path == "/api/categories":
            if req.method == Method.POST:
                return self.handle_categories_save(req)
            return self.handle_categories_get()
        # Static web UI — same-origin in production (Vite serves it in dev).
        # Reject path traversal before mapping under web/dist.
        if path.find("..") == -1:
            var root = _web_root()
            if path == "/" or path == "/index.html":
                return _serve_file(
                    root + "/index.html", "text/html; charset=utf-8"
                )
            # A client-side route (no file extension, e.g. /stats) → serve the SPA
            # entry so SvelteKit's router can render it (adapter-static fallback).
            if path.find(".") == -1:
                return _serve_file(
                    root + "/index.html", "text/html; charset=utf-8"
                )
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

    def handle_stats(self) raises -> Response:
        """Return the usage log as {"model": <label>, "records": [<obj>, …]}. The file
        is JSONL (each line is already a valid object), so we comma-join the non-empty
        lines into an array — no server-side JSON parsing. Missing file → empty list.
        """
        var recs = String("")
        var first = True
        try:
            var raw: String
            with open(_stats_path(), "r") as f:
                raw = f.read()
            var lines = raw.split("\n")
            for i in range(len(lines)):
                var ln = String(lines[i]).strip()
                if ln.byte_length() == 0:
                    continue
                if not first:
                    recs += ","
                recs += ln
                first = False
        except:
            pass
        return _cors(
            ok_json(
                '{"model":'
                + json_escape(_model_label())
                + ',"records":['
                + recs
                + "]}"
            )
        )

    def handle_history(self) raises -> Response:
        """Return the full ask history as {"records": [<obj>, …]} — the durable
        backend store (`asks.jsonl`) of every question with its generated program
        and answer. JSONL, so we comma-join the non-empty lines into an array — no
        server-side JSON parsing. Missing file → empty list. Newest first so the UI
        panel shows the most recent ask at the top."""
        var raw = String("")
        try:
            with open(_asks_path(), "r") as f:
                raw = f.read()
        except:
            pass  # missing file → empty history
        return _cors(ok_json('{"records":' + history_records_array(raw) + "}"))

    def handle_system(self) raises -> Response:
        """System info for the System tab: WHERE the data + logs live, so a user can
        find a per-ask transcript (the generated program + its run output) when an
        answer looks wrong, plus the running version/model. Paths are computed from
        $HOME so they stay correct across machines; the log locations mirror the ones
        the `mill` CLI's launch agents write to."""
        return _cors(
            ok_json(
                system_json(
                    getenv("HOME", ""),
                    _app_version(),
                    _model_label(),
                    _config_dir(),
                    _stats_path(),
                    _asks_path(),
                )
            )
        )

    def handle_tags(self) raises -> Response:
        """GET /api/tags → {"tags":[{name,keywords,count}]} for the Tags panel —
        in-process (vault.derive.store), the SAME payload `millfolio tags --json`
        prints. No engine spawn."""
        return _cors(ok_json(tags_report_json()))

    def handle_categories_get(self) raises -> Response:
        """GET /api/categories → {"text": <raw categories.txt>} for the editor
        (the file is seeded with the built-in defaults if absent)."""
        return _cors(ok_json('{"text":' + json_escape(read_categories()) + "}"))

    def handle_categories_save(self, req: Request) raises -> Response:
        """POST /api/categories {"text": …} → overwrite categories.txt (it becomes
        the user's authoritative registry) and re-tag the stored transactions
        in-process. Returns {"ok":true,"retagged":N}."""
        var text: String
        try:
            var j = loads(req.text())
            text = j["text"].string_value()
        except:
            return _cors(bad_request('{"error":"expected {text}"}'))
        var changed = save_categories(text)
        return _cors(ok_json('{"ok":true,"retagged":' + String(changed) + "}"))

    def handle_categories_preview(self, req: Request) raises -> Response:
        """POST /api/categories/preview {"text": …} → dry-run the edited rules over
        the stored transactions WITHOUT saving (the validation loop): per-tag match
        counts + a few example descriptions to spot false positives before saving.
        Returns {"tags":[{name,ml,count,examples}]} from preview_categories."""
        var text: String
        try:
            var j = loads(req.text())
            text = j["text"].string_value()
        except:
            return _cors(bad_request('{"error":"expected {text}"}'))
        return _cors(ok_json(preview_categories(text)))

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
        var mismatch = (
            has_index and source_dir != "" and source_dir != served_dir
        )

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
            r.headers.set(
                "Content-Disposition", 'inline; filename="' + name + '"'
            )
        except:
            pass
        return _cors(r^)

    def handle_search(self, req: Request) raises -> Response:
        """Semantic vault search: POST {"query": ..., "k": N} -> {"hits":[{alias,
        score,text}]}. The LanceDB/embedding work stays OUT of this server — we
        shell the `millfolio` engine binary via its run-script (MILLFOLIO_RUN_SCRIPT,
        set by the launcher) and have it write the JSON to a file (so captured
        stderr noise can't corrupt it), then return that file's contents."""
        var query: String
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
            return _cors(
                ok_json(
                    '{"error":"search unavailable — engine runner not'
                    ' configured","hits":[]}'
                )
            )

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
            return _cors(
                ok_json(
                    '{"error":"search failed (exit '
                    + String(rc)
                    + ')","hits":[]}'
                )
            )
        var hits: String
        try:
            with open(out_json, "r") as f:
                hits = f.read()
        except:
            hits = String("[]")
        return _cors(ok_json('{"hits":' + hits + "}"))


def _usleep(usec: Int):
    """Sleep `usec` microseconds (libc usleep) — the gap between run-output polls
    in the streaming loop, so we don't busy-spin while the sandboxed child runs.
    """
    _ = external_call["usleep", Int](Int(usec))


def _progress_label(line: String) raises -> String:
    """Strip the progress sentinel off a captured stdout line, leaving the message
    the generated program passed to `progress(...)`."""
    return String(line.removeprefix(PROGRESS_SENTINEL))


def _unescape_nl(s: String) raises -> String:
    """Restore `\\n` (two chars) → a real newline. The LOCAL sentinel escapes newlines
    so each exchange stays one line; this undoes it for display. UTF-8 safe (splits the
    String, not its bytes)."""
    var parts = s.split("\\n")
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += "\n"
        out += String(parts[i])
    return out^


def _secs1(ms: Float64) -> String:
    """Milliseconds → seconds with one decimal: 38234.5 -> "38.2s"."""
    var tenths = Int(ms / 100.0 + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10) + "s"


def _irate(n: Float64, ms: Float64) -> String:
    """Throughput `n` per second over `ms` milliseconds, integer: e.g. tokens/sec.
    Empty-time-safe (returns "0")."""
    if ms <= 0.0:
        return String("0")
    return String(Int(n * 1000.0 / ms + 0.5))


def _rate1(n: Float64, ms: Float64) -> String:
    """Throughput per second with one decimal — for the lower call rates (calls/s).
    """
    if ms <= 0.0:
        return String("0.0")
    var tenths = Int(n * 10000.0 / ms + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10)


def _dur(ms: Float64) -> String:
    """A single op's wall-clock: '210ms' under a second, else '1.2s'. For an op
    that ran ONCE, the duration is more telling than a per-second rate."""
    if ms < 1000.0:
        return String(Int(ms + 0.5)) + "ms"
    return _secs1(ms)


def _ms_since(t0: UInt) -> Float64:
    """Milliseconds elapsed since a perf_counter_ns() timestamp."""
    return Float64(perf_counter_ns() - t0) / 1.0e6


def _epoch_s() -> Int64:
    """Unix epoch seconds, right now — time(2) with a NULL arg. For stats timestamps
    (perf_counter_ns is monotonic, not wall-clock, so it can't date a record).
    """
    var null = UnsafePointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(0)
    )
    return external_call["time", Int64](null)


def _model_label() -> String:
    """The on-device model name shown in the UI's bottom bar + stamped on each stats
    record. MILLFOLIO_MODEL_LABEL (set by run-demo.sh from the engine's /v1/models)
    overrides; defaults to the Qwen the demo ships."""
    return String(getenv("MILLFOLIO_MODEL_LABEL", "Qwen2.5-3B-Instruct"))


def _app_version() -> String:
    """The deployed build label (matches the UI's bottom-bar stamp: '<sha> · <date>').
    Stamped on each stats record so the Stats page can average per deployed version.
    MILLFOLIO_VERSION is set by run-demo.sh from the deploy stamp; 'dev' otherwise.
    """
    return String(getenv("MILLFOLIO_VERSION", "dev"))


def _stats_path() -> String:
    """Where per-question usage records accumulate (JSONL). MILLFOLIO_STATS_FILE
    overrides; defaults under the config dir (which `cp -R` deploys never delete).
    """
    return String(
        getenv("MILLFOLIO_STATS_FILE", _config_dir() + "/stats.jsonl")
    )


def _append_stats(
    epoch: Int64,
    question: String,
    label: String,
    version: String,
    ok: Bool,
    total_ms: Float64,
    pf_tok: Int,
    gen_tok: Int,
    pf_ms: Float64,
    dec_ms: Float64,
    names: List[String],
    counts: List[Int],
    ms: List[Float64],
):
    """Append ONE self-contained JSON object (a usage record) to the stats file.
    JSONL — one object per line — so /api/stats can return the file verbatim and the
    browser does the averaging (the Mojo json lib is avoided on this path). Best-effort:
    a write failure is logged, never propagated into the chat reply."""
    var api = String("[")
    for i in range(len(names)):
        if i > 0:
            api += ","
        api += (
            "["
            + json_escape(names[i])
            + ","
            + String(counts[i])
            + ","
            + String(Int(ms[i] + 0.5))
            + "]"
        )
    api += "]"
    var line = (
        '{"ts":'
        + String(epoch)
        + ',"q":'
        + json_escape(question)
        + ',"model":'
        + json_escape(label)
        + ',"version":'
        + json_escape(version)
        + ',"ok":'
        + ("true" if ok else "false")
        + ',"total_ms":'
        + String(Int(total_ms + 0.5))
        + ',"prefill_tok":'
        + String(pf_tok)
        + ',"gen_tok":'
        + String(gen_tok)
        + ',"prefill_ms":'
        + String(Int(pf_ms + 0.5))
        + ',"decode_ms":'
        + String(Int(dec_ms + 0.5))
        + ',"api":'
        + api
        + "}\n"
    )
    try:
        with open(_stats_path(), "a") as f:
            f.write(line)
    except:
        log("[stats] append failed (non-fatal)")


def _asks_path() -> String:
    """Where the FULL per-ask history accumulates (JSONL): the question, the
    GENERATED program, and the answer. Durable + on-device under the config dir
    (which `cp -R` deploys never delete) — survives a browser-data clear, unlike
    the UI's localStorage. MILLFOLIO_ASKS_FILE overrides."""
    return String(getenv("MILLFOLIO_ASKS_FILE", _config_dir() + "/asks.jsonl"))


def _append_ask(
    epoch: Int64,
    question: String,
    code: String,
    answer: String,
    source: String,
    model: String,
    ok: Bool,
):
    """Append ONE self-contained JSON record — {ts, q, code, answer, source, model,
    ok} — to the per-ask history file (JSONL). This is the durable backend store
    behind the chat history panel: every ask is kept forever with the program that
    was generated and the answer it produced. Best-effort — a write failure is
    logged, never propagated into the chat reply."""
    var line = ask_record_line(epoch, question, code, answer, source, model, ok)
    try:
        with open(_asks_path(), "a") as f:
            f.write(line + "\n")  # JSONL — one record per line
    except:
        log("[asks] append failed (non-fatal)")


def _bump(
    mut names: List[String],
    mut counts: List[Int],
    mut ms: List[Float64],
    name: String,
    n: Int,
    dt: Float64,
):
    """Accumulate `n` calls (+ `dt` ms) under `name` in the parallel api-stat lists
    — find-or-append, so any tool/codegen name aggregates without a fixed schema.
    """
    for i in range(len(names)):
        if names[i] == name:
            counts[i] += n
            ms[i] += dt
            return
    names.append(name)
    counts.append(n)
    ms.append(dt)


def _live_stats(
    names: List[String], counts: List[Int], pf_tok: Int, gen_tok: Int
) -> String:
    """Running per-api call counts + model token tallies appended to the live
    working line — only the categories seen so far (empty stays clean)."""
    var s = String("")
    for i in range(len(names)):
        # Single op → just the name; repeated → ×count.
        if counts[i] == 1:
            s += " · " + names[i]
        else:
            s += " · " + names[i] + " ×" + String(counts[i])
    if pf_tok > 0:
        s += " · prefill " + String(pf_tok) + " tok"
    if gen_tok > 0:
        s += " · gen " + String(gen_tok) + " tok"
    return s^


# ── serial run-queue ─────────────────────────────────────────────────────────
# The FIFO ticket queue (one sandboxed run at a time across workers, with each
# waiter's live position) lives in runqueue.mojo and is unit-tested by
# test/runqueue_test.mojo. A run is ALSO time-bounded here (the child is killed past
# _RUN_MAX_ITERS) so one slow/stuck program can't stall the whole queue.
comptime _SIGKILL: Int = 9
comptime _RUN_MAX_ITERS: Int = 1000  # ~120s at 120ms/poll — kill a run past this


struct WsSink(DeltaSink, Movable):
    """Live codegen feedback: as the frontier model streams the program, update the ONE
    "codegen" status line in place with the growing size, so the user sees the model
    actively producing output (not just elapsed time). Coalesced (~200 chars) so it
    doesn't flood the WS. Holds the connection by pointer — valid for the duration of
    the synchronous `vault_codegen_stream` call within `on_connect`."""

    var conn_addr: Int  # address of the on_connect `conn` (alive for the call)
    var chars: Int
    var last: Int

    def __init__(out self, conn_addr: Int):
        self.conn_addr = conn_addr
        self.chars = 0
        self.last = 0

    def on_delta(mut self, text: String) raises:
        self.chars += text.byte_length()
        if self.chars - self.last >= 200:
            self.last = self.chars
            var conn = UnsafePointer[WsConnection, MutUntrackedOrigin](
                unsafe_from_address=self.conn_addr
            )
            conn[].send_text(
                status(
                    "codegen",
                    "Writing the program… (" + String(self.chars) + " chars)",
                    "running",
                )
            )


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
    var ticket = (
        -1
    )  # our run-queue ticket; >= 0 once we've entered (see runqueue.mojo)
    try:
        var cfg = load_config()
        var vault_dir = resolve_vault_dir()
        var orch = build_vault_orchestrator(cfg, vault_dir)

        # Run-stats accumulator — api call counts (codegen-phase + the vault tools the
        # generated program calls) and the model's prefill/gen tokens. Declared here so
        # the codegen/fix calls below feed the SAME tallies the run loop extends.
        var api_names = List[String]()
        var api_count = List[Int]()
        var api_ms = List[Float64]()
        var pf_tok = 0
        var gen_tok = 0
        var pf_ms = 0.0
        var dec_ms = 0.0

        # Wall-clock for the stats record: the WORK time (manifest+codegen, then
        # compile+run), deliberately EXCLUDING the human approval pause + queue wait.
        var t_total0 = perf_counter_ns()
        var pre_ms: Float64
        conn.send_text(status("manifest", "Aliasing vault manifest", "running"))
        var _t = perf_counter_ns()
        var manifest = orch.vault_manifest(vault_dir)
        _bump(api_names, api_count, api_ms, "alias", 1, _ms_since(_t))
        # The frontier-safe view also carries the category tag NAMES + scope notes
        # (so the model filters `.tags`); never the keyword RULES (real merchant
        # strings → on-device). DISPLAY-ONLY truncation so this dropdown stays
        # readable as the vault grows — show the first few of each group + the total.
        # The FULL manifest + tag list still go to the model (codegen uses `manifest`
        # / _tags_context, untouched); this only shapes the debug body.
        var _head = 3
        var _dbg = String("")
        # Manifest: keep the header lines (vault:/count), cap the `file_` lines.
        var _files = List[String]()
        var _mlines = manifest.split("\n")
        for _i in range(len(_mlines)):
            var _ln = String(_mlines[_i])
            if String(_ln.strip()).startswith("file_"):
                _files.append(_ln)
            elif String(_ln.strip()).byte_length() > 0:
                if _dbg.byte_length() > 0:
                    _dbg += "\n"
                _dbg += _ln
        for _i in range(len(_files)):
            if _i >= _head:
                break
            if _dbg.byte_length() > 0:
                _dbg += "\n"
            _dbg += _files[_i]
        if len(_files) > _head:
            _dbg += (
                "\n  … and "
                + String(len(_files) - _head)
                + " more files ("
                + String(len(_files))
                + " total)"
            )
        # Category tags (name + scope note), capped the same way.
        var _avail = effective_tags()
        var _adesc = effective_tag_descriptions()
        if len(_avail) > 0:
            _dbg += (
                "\n\nCategory tags also sent (name + scope note; the model"
                " filters .tags on these):"
            )
            for _i in range(len(_avail)):
                if _i >= _head:
                    break
                _dbg += "\n- " + _avail[_i]
                if _i < len(_adesc) and _adesc[_i].byte_length() > 0:
                    _dbg += " — " + _adesc[_i]
            if len(_avail) > _head:
                _dbg += (
                    "\n  … and "
                    + String(len(_avail) - _head)
                    + " more tags ("
                    + String(len(_avail))
                    + " total)"
                )
        conn.send_text(
            debug_event(
                "manifest",
                "Frontier-safe view — aliases + category tag names",
                _dbg,
                "text",
            )
        )
        conn.send_text(status("manifest", "Aliasing vault manifest", "done"))

        conn.send_text(status("codegen", "Writing the program", "running"))
        _t = perf_counter_ns()
        var code: String
        if getenv("MILLFOLIO_STREAM_CODEGEN", "") != "":
            # Stream the program — update the "codegen" line live with its size.
            var sink = WsSink(Int(UnsafePointer(to=conn)))
            code = orch.vault_codegen_stream(question, manifest, sink)
        else:
            code = orch.vault_codegen(question, manifest)
        _bump(api_names, api_count, api_ms, "codegen", 1, _ms_since(_t))
        conn.send_text(
            debug_event("codegen", "Generated program", code, "mojo")
        )
        conn.send_text(status("codegen", "Writing the program", "done"))
        # Surface which category tags the program filtered on (so the user knows
        # the answer came from a tag, not a guess) — the available tag NAMES that
        # appear as a quoted literal in the program (`"phone" in t.tags`).
        var used = _tags_in_program(code)
        if used.byte_length() > 0:
            conn.send_text(tags_event(used))
        # If the model proposed a NEW reusable tag for a category that isn't one
        # yet, surface it so the user can save it (next time = a fast `.tags`
        # filter, not an inline classify). A comment in the program; never runs.
        var prop = _tag_proposal_in_program(code)
        if len(prop) == 2:
            conn.send_text(tag_proposal_event(prop[0], prop[1]))
        pre_ms = _ms_since(
            t_total0
        )  # manifest + codegen, before the approval pause

        conn.send_text(
            status(
                "run",
                "Run the generated program over your vault?",
                "awaiting-approval",
            )
        )
        conn.send_text(
            approval("run", "Run the generated program over your vault?", code)
        )
        var decision = conn.recv()
        if (
            decision.opcode == WsOpcode.CLOSE
            or field(decision.text_payload(), "type") != "approve"
        ):
            conn.send_text(status("run", "Run rejected", "error"))
            conn.send_text(
                message(
                    "Okay — I won't run that. Tell me how you'd like to"
                    " adjust it."
                )
            )
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
            var ahead = ticket - st[0]  # people in front of us
            if ahead <= 0:
                conn.send_text(
                    status("queue", "You're next — running now", "done")
                )
                break
            waited += 1
            if (
                waited > 600
            ):  # ~300s — assume the queue stalled; take our turn anyway
                conn.send_text(status("queue", "Starting now", "done"))
                break
            conn.send_text(
                status(
                    "queue",
                    "There are " + String(ahead) + " ahead of you",
                    "running",
                )
            )
            _usleep(500_000)  # re-check twice a second
            st = runq_peek()

        # Approved — surface the two real phases SEPARATELY so the wait isn't one
        # opaque "working": first compile the generated Mojo, then run it over the
        # vault (the read + ask_local loop — the long part). The run is now spawned
        # NON-BLOCKING and we poll its captured stdout, streaming each `progress(…)`
        # line the generated program emits as a live "execute" status update (same
        # stepId, so the UI updates ONE line in place) instead of a frozen spinner.
        conn.send_text(status("run", "Approved — running", "done"))
        var t_run0 = (
            perf_counter_ns()
        )  # compile + run wall-clock (post-approval/queue)
        conn.send_text(
            status("compile", "Compiling the generated program", "running")
        )
        _t = perf_counter_ns()
        var fixes = orch.vault_build(code)
        _bump(api_names, api_count, api_ms, "compile", 1, _ms_since(_t))
        if fixes > 0:
            _bump(api_names, api_count, api_ms, "fix", fixes, 0.0)
        conn.send_text(
            status("compile", "Compiling the generated program", "done")
        )
        conn.send_text(
            status("execute", "Running it locally over your vault…", "running")
        )
        var h = orch.vault_run_start(vault_dir)
        log("[run] poll start: pid=" + String(Int(h.pid)))
        var cur_label = String("Running it locally over your vault…")
        var src_file = String(
            ""
        )  # first document a tool read — surfaced as the source
        var src_alias = String("")  # …its alias, for the /api/doc?alias= link
        var running = True
        var iters = 0
        var timed_out = False
        while running:
            # Reap FIRST, then poll — so the final poll (once the child has exited)
            # still drains every progress/stat line written just before it died.
            var reap = orch.vault_run_reap(h)
            running = reap == -1  # -1 = still running
            var lines = orch.vault_run_poll(h)
            if (
                iters % 16 == 0
            ):  # ~every 2s: prove the loop's alive + where it's stuck
                log(
                    "[run] poll iter="
                    + String(iters)
                    + " reap="
                    + String(reap)
                    + " captured="
                    + String(h.cursor)
                    + "B"
                )
            var dirty = False
            for i in range(len(lines)):
                var ln = lines[i].copy()
                if ln.startswith(PROGRESS_SENTINEL):
                    cur_label = _progress_label(ln)
                    dirty = True
                elif ln.startswith(STAT_SENTINEL):
                    var parts = String(ln.removeprefix(STAT_SENTINEL)).split(
                        "\t"
                    )
                    if len(parts) >= 5 and String(parts[0]) == "model":
                        # "model\t<pf_tok>\t<gen_tok>\t<pf_ms>\t<dec_ms>" — engine prefill/gen.
                        pf_tok += Int(atof(String(parts[1])))
                        gen_tok += Int(atof(String(parts[2])))
                        pf_ms += atof(String(parts[3]))
                        dec_ms += atof(String(parts[4]))
                        dirty = True
                    elif len(parts) >= 3 and String(parts[0]) == "source":
                        # "source\t<alias>\t<filename>" — the first document a tool read.
                        if src_alias == "":
                            src_alias = String(parts[1])
                            src_file = String(parts[2])
                    elif len(parts) == 2:
                        # "<tool>\t<ms>" — one vault-tool API call + its duration.
                        _bump(
                            api_names,
                            api_count,
                            api_ms,
                            String(parts[0]),
                            1,
                            atof(String(parts[1])),
                        )
                        dirty = True
                elif ln.startswith(LOCAL_SENTINEL):
                    # An on-device-model exchange (debug). Surface it as a collapsible
                    # item so the user can see exactly what ask_local/ask_local_batch
                    # sent to the local model and what it returned (e.g. why a
                    # phone-bill filter matched what it did). \n was escaped for the
                    # one-line sentinel — restore it for readability.
                    var rec = String(ln.removeprefix(LOCAL_SENTINEL))
                    var sg = rec.split(LOCAL_SEP)
                    var sent = _unescape_nl(String(sg[0])) if len(
                        sg
                    ) >= 1 else String("")
                    var got = _unescape_nl(String(sg[1])) if len(
                        sg
                    ) >= 2 else String("")
                    conn.send_text(
                        debug_event(
                            "execute",
                            "on-device model — what it was asked",
                            "SENT:\n" + sent + "\n\nGOT:\n" + got,
                            "text",
                        )
                    )
            # Update the ONE 'working' line in place with the latest progress label
            # + running api/model tallies, whenever a progress or stat line arrived.
            if dirty:
                conn.send_text(
                    status(
                        "execute",
                        cur_label
                        + _live_stats(api_names, api_count, pf_tok, gen_tok),
                        "running",
                    )
                )
            if running:
                iters += 1
                if iters > _RUN_MAX_ITERS:
                    # A run must not stall the queue — kill a too-slow / stuck child.
                    _ = external_call["kill", Int32](h.pid, Int32(_SIGKILL))
                    timed_out = True
                    running = False
                    # Reap the corpse so it doesn't linger as a zombie. SIGKILL isn't
                    # instant (a child wedged in a syscall dies when it returns), so
                    # poll a few times before giving up.
                    for _r in range(25):
                        if orch.vault_run_reap(h) != -1:
                            break
                        _usleep(40_000)  # 40 ms
                else:
                    _usleep(120_000)  # 120 ms between polls

        log(
            "[run] poll done: iters="
            + String(iters)
            + " timed_out="
            + String(timed_out)
        )
        # Final per-category summary: total + throughput (number/sec) for every API
        # category (codegen-phase + vault tools) and the model (prefill/gen tokens).
        if len(api_names) > 0 or pf_tok + gen_tok > 0:
            var sum = String("Stats:")
            for i in range(len(api_names)):
                if api_count[i] == 1:
                    # One instance → the duration is more telling than a rate.
                    sum += "  " + api_names[i]
                    if api_ms[i] > 0.0:
                        sum += " (" + _dur(api_ms[i]) + ")"
                else:
                    sum += "  " + api_names[i] + " ×" + String(api_count[i])
                    if api_ms[i] > 0.0:  # repeated timed calls → a rate
                        sum += (
                            " ("
                            + _rate1(Float64(api_count[i]), api_ms[i])
                            + "/s)"
                        )
            if pf_tok > 0:
                sum += (
                    "  prefill "
                    + String(pf_tok)
                    + " tok ("
                    + _irate(Float64(pf_tok), pf_ms)
                    + " tok/s)"
                )
            if gen_tok > 0:
                sum += (
                    "  gen "
                    + String(gen_tok)
                    + " tok ("
                    + _irate(Float64(gen_tok), dec_ms)
                    + " tok/s)"
                )
            conn.send_text(status("engine", sum, "done"))

        # Past `poll done` the run is over, so a perceived "hang" on the SECOND
        # question must live in this tail — finish/read, the WS sends, or releasing
        # the queue slot. Bracket each step so the log shows exactly where it stalls.
        log("[run] finish: reading captured output")
        var reply = orch.vault_run_finish(h)
        log("[run] finish: reply " + String(reply.byte_length()) + "B")
        if timed_out:
            conn.send_text(
                status(
                    "execute",
                    "Stopped — the run exceeded the time limit",
                    "error",
                )
            )
            conn.send_text(
                message(
                    "That took too long and was stopped. Please try another"
                    " question."
                )
            )
        else:
            conn.send_text(
                status("execute", "Running it locally over your vault", "done")
            )
            conn.send_text(message(reply, src_file, src_alias))
        log("[run] reply sent; releasing queue slot ticket=" + String(ticket))
        # Persist this question's usage (JSONL) for the Stats page — still inside the
        # run slot, so writes across workers are serialized. total = work time only
        # (pre-approval manifest+codegen + post-approval compile+run); the human pause
        # and queue wait are excluded so the average reflects the machine, not the user.
        _append_stats(
            _epoch_s(),
            question,
            _model_label(),
            _app_version(),
            not timed_out,
            pre_ms + _ms_since(t_run0),
            pf_tok,
            gen_tok,
            pf_ms,
            dec_ms,
            api_names,
            api_count,
            api_ms,
        )
        # The durable history store — same record, plus the generated program and
        # the answer, kept forever (the chat history panel reads it back).
        _append_ask(
            _epoch_s(),
            question,
            code,
            reply,
            src_file,
            _model_label(),
            not timed_out,
        )
        runq_done(ticket)  # leave the run slot → next waiter proceeds
        log("[run] queue slot released")
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
    print(
        "  WS   (Upgrade)   -> streaming chat (status/approval/message events)"
    )
    # One listener serves both: the unary HTTP `Api` handler AND, for requests with
    # the WebSocket Upgrade headers, the streaming `on_connect` chat — no second port.
    # (The 2-arg serve overload is plain-function-only; we use a stateful Handler
    # struct, so set the WS handler on the config and use the Handler-typed serve.)
    runq_reset()  # clear any stale run-queue state from a prior process
    var srv = HttpServer.bind(SocketAddr.localhost(UInt16(port)))
    srv.config.ws_handler = on_connect
    # Run each chat WebSocket on its OWN detached thread (off the reactor).
    # A chat query blocks for ~30s–2min inside `on_connect` (codegen's Anthropic
    # call, then compile + the run-poll loop). Inline, that parks the whole reactor
    # worker, so the read-only API GETs (/api/system, /api/vault, …) pinned to that
    # worker stall for the entire query — the UI's System tab shows "Loading…".
    # Offloading frees the reactor to keep answering those GETs while the chat runs.
    # The sandboxed RUN stays serial regardless (the flock run-queue in on_connect);
    # only manifest+codegen now overlap across visitors — desired for the demo.
    # MILLFOLIO_WS_INLINE=1 restores the old inline (reactor-blocking) behaviour.
    if getenv("MILLFOLIO_WS_INLINE", "") == "":
        srv.config.ws_offload = True
    var workers = _workers()
    if workers > 1:
        print(
            "  workers: ",
            workers,
            (
                " (concurrent connections; the sandboxed run stays serial via"
                " the run-queue)"
            ),
            sep="",
        )
    # num_workers=1 (default) → single-threaded reactor (real product). >1 → N pthread
    # workers via the multicore Handler-serve; Api is Copyable (shares the state
    # pointer) and config.ws_handler propagates to each worker.
    srv.serve(api^, num_workers=workers)

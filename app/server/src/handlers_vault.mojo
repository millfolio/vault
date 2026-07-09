"""handlers_vault — the read-only "vault view" HTTP handlers.

The three endpoints that surface the on-device index without touching the
inference engine:
  • GET  /api/vault  — the indexed files + index stats (from manifest.tsv).
  • GET  /api/doc    — stream one indexed document for the in-app viewer.
  • POST /api/search — semantic vault search (shells the `millfolio` engine).

Phase-1B slice 1: these were `Api.handle_*` methods on the state-pointer wrapper
`struct Api` in `server.mojo`. Each is a pure move to a free function here —
`self.st` becomes the `st` parameter, and the `self`-qualified helper calls
resolve to the already-extracted leaf modules (`osutil`, `sysmetrics`,
`httputil`, `events`, `sandbox`, `vault.storage`). `server.serve()` now delegates
to these. Behaviour is identical.

`handle_vault` needs the served vault dir off `MillfolioState`, so it takes the
state pointer; `handle_doc`/`handle_search` reach only file/manifest state, so
they take just the request.
"""

from std.os import getenv
from std.os.path import isfile

from flare.prelude import *

from json import loads

from vault.storage import default_manifest_store, DOC_MANIFEST, expand_home

from state import MillfolioState
from osutil import _config_dir, _tsv_unescape, _atoi
from sysmetrics import _dir_size
from httputil import _cors
from events import json_escape
from security.sandbox import _spawn_capture

# Qwen3-Embedding-0.6B — mirrors vault/core embed.mojo. Surfaced in /api/vault.
comptime EMBED_DIM = 1024


def handle_vault(
    st: UnsafePointer[MillfolioState, MutUntrackedOrigin]
) raises -> Response:
    """The vault view: the INDEXED files + index stats, read from the engine's
    manifest.tsv (written by `mill index`). Reflects what was actually indexed
    — not a live walk of the served dir — so it's correct even when the indexed
    folder differs from the served vault dir (both are surfaced, plus a
    `dirMismatch` flag the UI can warn on). Read-only."""
    ref s = st[]
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
        var text = default_manifest_store(config_dir).load(DOC_MANIFEST)
        var lines = text.split("\n")
        for i in range(len(lines)):
            var line = String(lines[i])
            if line.byte_length() == 0:
                continue
            var cols = line.split("\t")
            # Meta row: #meta <next_id> <next_alias> <source_dir>. The dir is
            # stored home-relative (`~/…`); expand for display + the mismatch
            # comparison (legacy absolute rows pass through unchanged).
            if String(cols[0]) == "#meta":
                if len(cols) >= 4:
                    source_dir = expand_home(_tsv_unescape(String(cols[3])))
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
            files_json += '"alias":' + json_escape(falias) + ","
            files_json += '"name":' + json_escape(name) + ","
            files_json += '"kind":' + json_escape(kind) + ","
            files_json += '"sizeBytes":' + String(sz) + ","
            files_json += '"chunks":' + String(chunks)
            files_json += "}"
            file_count += 1
    files_json += "]"

    var has_index = indexed and file_count > 0
    var mismatch = has_index and source_dir != "" and source_dir != served_dir

    var out = String("{")
    out += '"vaultDir":' + json_escape(served_dir) + ","
    out += '"sourceDir":' + json_escape(source_dir) + ","
    out += '"dirMismatch":' + ("true" if mismatch else "false") + ","
    out += '"configDir":' + json_escape(config_dir) + ","
    out += '"indexed":' + ("true" if has_index else "false") + ","
    out += '"embeddingDim":' + String(EMBED_DIM) + ","
    out += '"fileCount":' + String(file_count) + ","
    out += '"indexedFileCount":' + String(file_count) + ","
    out += '"chunkCount":' + String(total_chunks) + ","
    out += '"dbSizeBytes":' + String(_dir_size(db_path)) + ","
    out += '"files":' + files_json
    out += "}"
    return _cors(ok_json(out))


def handle_doc(req: Request) raises -> Response:
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
    var text = default_manifest_store(_config_dir()).load(DOC_MANIFEST)
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
                # Stored `~/…`; expand so the file open below hits the real path.
                source_dir = expand_home(_tsv_unescape(String(cols[3])))
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


def handle_search(req: Request) raises -> Response:
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
                '{"error":"search failed (exit ' + String(rc) + ')","hits":[]}'
            )
        )
    var hits: String
    try:
        with open(out_json, "r") as f:
            hits = f.read()
    except:
        hits = String("[]")
    return _cors(ok_json('{"hits":' + hits + "}"))

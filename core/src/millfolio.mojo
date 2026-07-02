"""Millfolio — CLI entry point for the personal data vault.

For now: `mill manifest <dir>` prints the aliased, frontier-visible view of a
vault directory — the confidentiality boundary, before any of the heavier
machinery (indexer, vault tools, the privacy_box-driven ask loop) is wired in.
"""

from std.sys import argv
from std.os import getenv

from vault.index import (
    build_manifest,
    FileInfo,
    csv_rows,
    md_text,
    pdf_text,
    embed,
    build_index,
    search,
    Chunk,
    vault_files,
    effective_tags,
    effective_retag,
    ml_materialize,
    codegen_tags_describe,
    materialize_status_json,
    tags_report_json,
)
from vault.index.relevance import cosine_from_l2sq, passes_min_sim
from vault.derive.store import get_amount_password, set_amount_password


def _print_manifest(data_dir: String) raises:
    # Prefer the persisted index manifest (what `mill index` actually indexed)
    # over a live walk of `data_dir` — so the frontier model's view matches what
    # search() can reach, even when the served dir differs from the indexed one.
    var infos = vault_files(data_dir)
    print("vault:", data_dir)
    print(
        String(len(infos))
        + " indexable file(s) — the frontier model sees only this:"
    )
    for i in range(len(infos)):
        ref fi = infos[i]
        var line = String("  ") + fi.id + "  [" + fi.kind + "]  "
        line += String(fi.size) + " bytes"
        if len(fi.columns) > 0:
            line += "  schema: "
            for j in range(len(fi.columns)):
                if j > 0:
                    line += ", "
                line += fi.columns[j]
        print(line)


def _resolve_alias(file_id: String, data_dir: String) raises -> FileInfo:
    """Look up a file alias (file_0..) in the vault manifest. Raises if unknown.
    """
    var infos = vault_files(data_dir)
    for i in range(len(infos)):
        if infos[i].id == file_id:
            return infos[i].copy()
    raise Error("no such alias '" + file_id + "' in " + data_dir)


def _read(file_id: String, data_dir: String) raises:
    """Smoke-test a reader: resolve `file_id` in `data_dir`, run the kind-appropriate
    reader, and print a short preview. The real path stays internal."""
    var fi = _resolve_alias(file_id, data_dir)
    print(fi.id, "[" + fi.kind + "]", String(fi.size) + " bytes")
    if fi.kind == "csv":
        var rows = csv_rows(fi.path)
        print(String(len(rows)) + " row(s) (header included):")
        var shown = 0
        for i in range(len(rows)):
            if shown >= 5:
                print("  ...")
                break
            var line = String("  ")
            for j in range(len(rows[i])):
                if j > 0:
                    line += " | "
                line += rows[i][j]
            print(line)
            shown += 1
    elif fi.kind == "md":
        var text = md_text(fi.path)
        print(String(text.byte_length()) + " bytes of text:")
        print(_preview(text, 400))
    elif fi.kind == "pdf":
        var text = pdf_text(fi.path)
        print(String(text.byte_length()) + " chars extracted:")
        print(_preview(text, 400))


def _preview(text: String, limit: Int) -> String:
    """First `limit` bytes of `text` (codepoint-safe truncation)."""
    var out = String("")
    var count = 0
    for cp in text.codepoint_slices():
        if count >= limit:
            out += " ..."
            break
        out += String(cp)
        count += String(cp).byte_length()
    return out^


def _default_dir() raises -> String:
    return getenv("HOME", ".") + "/millfolio"


def _local_url() raises -> String:
    """CHAT endpoint (default :8000)."""
    return getenv("MILLFOLIO_LOCAL_URL", "http://127.0.0.1:8000/v1")


def _embed_url() raises -> String:
    """EMBEDDINGS endpoint (default :8000, same base as chat). `index` + `search`
    + `embed` use this — one inference-server process now serves both the chat
    model and the embedding model on a single port (/v1/embeddings routes to the
    secondary Qwen3-Embedding model). Override MILLFOLIO_EMBED_URL to point at a
    separate embedding server. Mirrors vault._embed_url()."""
    return getenv("MILLFOLIO_EMBED_URL", "http://127.0.0.1:8000/v1")


def main() raises:
    var args = argv()
    if len(args) < 2:
        print(
            "usage: millfolio <manifest|read|embed|index|search|tags|retag> ..."
        )
        return
    var cmd = String(args[1])
    if cmd == "manifest":
        var data_dir = String(args[2]) if len(args) >= 3 else _default_dir()
        _print_manifest(data_dir)
    elif cmd == "read":
        if len(args) < 3:
            print("usage: millfolio read <alias> [vault-dir]")
            return
        var file_id = String(args[2])
        var data_dir = String(args[3]) if len(args) >= 4 else _default_dir()
        _read(file_id, data_dir)
    elif cmd == "embed":
        if len(args) < 3:
            print('usage: millfolio embed "<text>"')
            return
        _embed(String(args[2]))
    elif cmd == "index":
        var roots = List[String]()
        var force = False
        for i in range(2, len(args)):
            var a = String(args[i])
            if a == "--force":
                force = True
            else:
                roots.append(a)
        if len(roots) == 0:
            roots.append(_default_dir())  # no paths → the configured vault dir
        build_index(roots^, _embed_url(), force)
    elif cmd == "search":
        if len(args) < 3:
            print('usage: millfolio search "<query>" [k] [--json]')
            return
        var query = String(args[2])
        var k = 8
        var as_json = False
        var out_path = String("")
        var i = 3
        while i < len(args):
            var a = String(args[i])
            if a == "--json":
                as_json = True
            elif a == "--out" and i + 1 < len(args):
                out_path = String(args[i + 1])
                i += 1
            else:
                k = Int(a)
            i += 1
        if as_json:
            _search_json(query, k, out_path)
        else:
            _search(query, k)
    elif cmd == "tags":
        # `tags`        → the effective tag NAMES, comma-joined (the codegen
        #                 orchestrator captures this to tell the frontier model
        #                 which `.tags` it can filter on — names only).
        # `tags --json` → {"tags":[{"name","keywords":[…],"count":N}]} for the UI
        #                 Tags panel (per-tag keyword rules + how many stored
        #                 transactions carry each tag).
        if len(args) >= 3 and String(args[2]) == "--json":
            print(tags_report_json())
        elif len(args) >= 3 and String(args[2]) == "--describe":
            # One tag per line, `name <TAB> description` (description may be
            # empty) — the codegen orchestrator formats this into the prompt so
            # the model picks a tag by its scope, not just its name. Applies the
            # READINESS GATE: an ML tag not yet fully materialized is withheld so
            # codegen never filters `.tags` on it and reports a false "no X".
            print(codegen_tags_describe())
        else:
            var names = effective_tags()
            var out = String("")
            for i in range(len(names)):
                if i > 0:
                    out += ", "
                out += names[i]
            print(out)
    elif cmd == "retag":
        # Re-apply the current category rules to the stored transactions (no file
        # scan, no embedding) — the app server runs this after the user edits
        # their categories so the change applies without a full re-index.
        var changed = effective_retag()
        print(
            "re-tagged "
            + String(changed)
            + " transaction(s) from the current category rules"
        )
    elif cmd == "materialize":
        # Run the ML category rules (`<tag> : <question>`) over the stored
        # transactions via the on-device model — the fuzzy tail no keyword rule
        # captures. Ledger-based + incremental: each true negative is classified
        # once (the marker remembers it), so a re-run only does genuinely-new work.
        # `--status` prints the per-tag progress JSON without touching the engine.
        if len(args) >= 3 and String(args[2]) == "--status":
            print(materialize_status_json())
        else:
            var changed = ml_materialize(_local_url())
            print(
                "materialized — "
                + String(changed)
                + " transaction(s) updated from the category rules"
            )
    elif cmd == "amount-password":
        # The local reveal passphrase for the amount privacy screen.
        #   amount-password get         → print it (a random 3-word one is generated
        #                                 + saved on first use)
        #   amount-password set <words> → overwrite it with your own phrase
        var sub = String(args[2]) if len(args) >= 3 else String("get")
        if sub == "set":
            if len(args) < 4:
                print("usage: millfolio amount-password set <words>")
            else:
                var phrase = String(args[3])
                for k in range(4, len(args)):
                    phrase += " " + String(args[k])
                set_amount_password(phrase)
                print(get_amount_password())
        else:
            print(get_amount_password())
    else:
        print(
            "usage: millfolio <manifest|read|embed|index|search|tags|retag"
            "|materialize|amount-password> ..."
        )


def _embed(text: String) raises:
    """Smoke-test the embedding client. Requires the inference-server embeddings
    endpoint to be live + serving the embedding model."""
    var url = _embed_url()
    print("POST " + url + "/embeddings")
    try:
        var vec = embed(url, text)
        print("got " + String(len(vec)) + "-d embedding; first 4: ", end="")
        var n = 4 if len(vec) >= 4 else len(vec)
        for i in range(n):
            if i > 0:
                print(", ", end="")
            print(vec[i], end="")
        print()
    except err:
        print(
            "embed failed (needs inference-server embeddings endpoint live): "
            + String(err)
        )


def _search(query: String, k: Int) raises:
    """Smoke-test semantic search. Requires an existing index + live embeddings.
    """
    var hits = search(query, k, _embed_url())
    print(String(len(hits)) + " hit(s) for: " + query)
    for i in range(len(hits)):
        ref h = hits[i]
        print("  [" + h.file_alias + "] score=" + String(h.score))
        print("    " + _preview(h.text, 160))


def _json_str(s: String) -> String:
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


def _search_min_sim() raises -> Float64:
    """Minimum cosine similarity for a UI search hit to be shown. The embedding
    server returns L2-normalized vectors, so LanceDB's default squared-L2
    `_distance` d maps cleanly to cosine: `cos = 1 - d/2`. k-NN ALWAYS returns the
    k nearest chunks — even when nothing is actually relevant (a term absent from
    the vault, e.g. "anthropic") — so without a floor the UI shows junk. We drop
    hits below this similarity. Tunable via MILLFOLIO_SEARCH_MIN_SIM; default 0.4.
    """
    var raw = getenv("MILLFOLIO_SEARCH_MIN_SIM", "")
    if raw == "":
        return 0.4
    try:
        return atof(raw)
    except:
        return 0.4


def _search_json(query: String, k: Int, out_path: String) raises:
    """Machine-readable search for the app server / clients: a JSON array of
    {alias, score, text}, nearest first. `score` is COSINE SIMILARITY (higher =
    better, ~[0,1]); hits below `_search_min_sim()` are omitted so an absent term
    returns `[]` instead of the k nearest unrelated chunks. `alias` is the
    frontier-safe token; real names stay server-side (resolve via /api/vault). With
    `--out <path>` the JSON is written to that file (so a caller's captured
    stdout/stderr noise can't corrupt it); otherwise it's printed to stdout."""
    var hits = search(query, k, _embed_url())
    var min_sim = _search_min_sim()
    var out = String("[")
    var first = True
    for i in range(len(hits)):
        ref h = hits[i]
        # h.score is LanceDB's squared-L2 distance over unit vectors → cosine.
        var d = Float64(h.score)
        if not passes_min_sim(d, min_sim):
            continue  # below the relevance floor — not a real match
        var sim = cosine_from_l2sq(d)
        if not first:
            out += ","
        first = False
        out += "{"
        out += '"alias":' + _json_str(h.file_alias) + ","
        out += '"score":' + String(sim) + ","
        out += '"text":' + _json_str(h.text)
        out += "}"
    out += "]"
    if out_path.byte_length() > 0:
        with open(out_path, "w") as f:
            f.write(out)
    else:
        print(out)

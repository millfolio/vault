"""veilens — CLI entry point for the personal data vault.

For now: `veilens manifest <dir>` prints the aliased, frontier-visible view of a
vault directory — the confidentiality boundary, before any of the heavier
machinery (indexer, vault tools, the privacy_box-driven ask loop) is wired in.
"""

from std.sys import argv
from std.os import getenv

from manifest import build_manifest, FileInfo
from readers import csv_rows, md_text, pdf_text
from embed import embed
from index import build_index, search, Chunk


def _print_manifest(data_dir: String) raises:
    var infos = build_manifest(data_dir)
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
    """Look up a file alias (file_0..) in the vault manifest. Raises if unknown."""
    var infos = build_manifest(data_dir)
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
    return getenv("HOME", ".") + "/veilens"


def _local_url() raises -> String:
    """CHAT endpoint (default :8000)."""
    return getenv("VEILENS_LOCAL_URL", "http://127.0.0.1:8000/v1")


def _embed_url() raises -> String:
    """EMBEDDINGS endpoint (default :8000, same base as chat). `index` + `search`
    + `embed` use this — one inference-server process now serves both the chat
    model and the embedding model on a single port (/v1/embeddings routes to the
    secondary Qwen3-Embedding model). Override VEILENS_EMBED_URL to point at a
    separate embedding server. Mirrors vault._embed_url()."""
    return getenv("VEILENS_EMBED_URL", "http://127.0.0.1:8000/v1")


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: veilens <manifest|read|embed|index|search> ...")
        return
    var cmd = String(args[1])
    if cmd == "manifest":
        var data_dir = String(args[2]) if len(args) >= 3 else _default_dir()
        _print_manifest(data_dir)
    elif cmd == "read":
        if len(args) < 3:
            print("usage: veilens read <alias> [vault-dir]")
            return
        var file_id = String(args[2])
        var data_dir = String(args[3]) if len(args) >= 4 else _default_dir()
        _read(file_id, data_dir)
    elif cmd == "embed":
        if len(args) < 3:
            print("usage: veilens embed \"<text>\"")
            return
        _embed(String(args[2]))
    elif cmd == "index":
        var data_dir = String(args[2]) if len(args) >= 3 else _default_dir()
        build_index(data_dir, _embed_url())
    elif cmd == "search":
        if len(args) < 3:
            print("usage: veilens search \"<query>\" [k]")
            return
        var k = Int(String(args[3])) if len(args) >= 4 else 8
        _search(String(args[2]), k)

    else:
        print("usage: veilens <manifest|read|embed|index|search> ...")


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
        print("embed failed (needs inference-server embeddings endpoint live): " + String(err))


def _search(query: String, k: Int) raises:
    """Smoke-test semantic search. Requires an existing index + live embeddings."""
    var hits = search(query, k, _embed_url())
    print(String(len(hits)) + " hit(s) for: " + query)
    for i in range(len(hits)):
        ref h = hits[i]
        print("  [" + h.file_alias + "] score=" + String(h.score))
        print("    " + _preview(h.text, 160))

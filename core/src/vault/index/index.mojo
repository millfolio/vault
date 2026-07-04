"""Index — chunk + embed the vault into an on-device LanceDB vector store, with
INCREMENTAL re-indexing (only changed/new files are re-embedded).

`build_index` walks the data dir, content-hashes (SHA-256) each file, and diffs
against a persisted manifest:
  • unchanged file (same name + same hash) → skipped entirely (no embedding);
  • changed file → its old chunk-id range is deleted from LanceDB and it's
    re-embedded into a fresh id range (keeping its stable alias);
  • new file → embedded into a fresh id range under a freshly-minted alias;
  • removed file → its id range is deleted.
After deletes the table is `optimize()`d (deletes are soft tombstones). If
nothing changed, it's a no-op.

Only ids + vectors cross into LanceDB. The chunk text + its file alias live in a
side-table (chunks.tsv), and the per-file manifest (real name, kind, size, hash,
id range) lives in manifest.tsv. Both are LOCAL-ONLY: real names/text/hashes
never reach the frontier model — search results expose only aliases.

Layout (under the data dir — see store.config_dir, default
~/Library/Application Support/Millfolio/data):
  index.db/      — the LanceDB database (table "chunks", dim 1024)
  chunks.tsv     — chunk_id <TAB> file_alias <TAB> escaped_text   (ids are SPARSE)
  manifest.tsv   — #meta <next_id> <next_alias> <source_dir> <next_gen>, one row per
                   file: alias <TAB> name <TAB> kind <TAB> size <TAB> sha256
                   <TAB> id_start <TAB> chunk_count
"""

from std.os import getenv, makedirs, remove, rmdir, listdir
from std.os.path import exists, isfile

from lancedb import Store
from vault.index.manifest import (
    build_manifest,
    manifest_for_files,
    collect_index_paths,
    common_base,
    FileInfo,
    _csv_columns,
)
from vault.index.readers import csv_rows, md_text, pdf_text, docx_text
import vault.index.readers as readers
from vault.index.embed import embed, embed_batch, EMBED_DIM
from vault.index.sha256 import sha256_file_hex
from vault.extract.transactions import (
    Txn,
    extract_transactions,
    statement_year,
    csv_transactions,
    TxnRow,
    drop_aliases,
    dedupe_txns,
    select_txns,
    texts_for_alias,
)
from vault.extract.location import parse_location
from vault.derive.store import (
    config_dir,
    load_registry,
    load_txn_rows,
    write_txn_rows,
    retag,
    ml_backfill_rows,
    ledger_note_backfilled,
)


comptime CHUNK_SIZE = 512  # ~codepoints per chunk
comptime CHUNK_OVERLAP = 64  # codepoints carried into the next chunk for context
comptime TABLE = "chunks"
comptime EMBED_BATCH = 64  # chunks per /v1/embeddings request


@fieldwise_init
struct Chunk(Copyable, Movable):
    """A search hit: which file (by alias), the chunk text, and its score
    (smaller distance = closer; we expose it as `.score` per the tool contract).
    """

    var file_alias: String
    var text: String
    var score: Float32


@fieldwise_init
struct FileEntry(Copyable, Movable):
    """One indexed file in the manifest. `name` is the real path RELATIVE to the
    vault root (LOCAL-ONLY; e.g. `reports/q1.pdf`); `alias` is the stable,
    frontier-safe token. `[id_start, id_start+chunk_count)` is this file's
    contiguous chunk-id range in LanceDB."""

    var falias: String
    var name: String
    var kind: String
    var size: Int
    var sha: String
    var id_start: Int
    var chunk_count: Int


@fieldwise_init
struct Manifest(Copyable, Movable):
    var entries: List[FileEntry]
    var next_id: Int  # next free chunk id (monotonic; ids are never reused)
    var next_alias: Int  # next free alias number (monotonic)
    var source_dir: String
    # Next free INSERTION generation for transaction rows (monotonic). Each index
    # run that adds transactions stamps them with the current value, then bumps it,
    # so the ML-backfill ledger can tell late-inserted (back-dated) rows
    # apart from ones a rule has already covered. See `TxnRow.added_gen`.
    var next_gen: Int


@fieldwise_init
struct SideTable(Copyable, Movable):
    """Chunk_id -> (alias, text), as parallel lists. ids are sparse (deletes leave
    gaps), so lookups scan rather than index by position."""

    var ids: List[Int]
    var aliases: List[String]
    var texts: List[String]


# ── paths ─────────────────────────────────────────────────────────────────────


def _db_uri() raises -> String:
    return config_dir() + "/index.db"


def _sidetable_path() raises -> String:
    return config_dir() + "/chunks.tsv"


def _manifest_path() raises -> String:
    return config_dir() + "/manifest.tsv"


# ── small helpers ─────────────────────────────────────────────────────────────


def _replace_all(s: String, old: String, new: String) raises -> String:
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out^


def _tsv_escape(s: String) raises -> String:
    """Make `s` a single TSV cell: backslash-escape \\, tab, newline, CR."""
    var o = _replace_all(s, String("\\"), String("\\\\"))
    o = _replace_all(o, String("\t"), String("\\t"))
    o = _replace_all(o, String("\n"), String("\\n"))
    o = _replace_all(o, String("\r"), String("\\r"))
    return o^


def _tsv_unescape(s: String) raises -> String:
    """Inverse of `_tsv_escape` — left-to-right scan so escapes don't compound.
    """
    var out = String("")
    var bytes = s.as_bytes()
    var i = 0
    while i < len(bytes):
        var c = Int(bytes[i])
        if c == 92 and i + 1 < len(bytes):  # backslash
            var n = Int(bytes[i + 1])
            if n == 116:  # 't'
                out += "\t"
                i += 2
                continue
            elif n == 110:  # 'n'
                out += "\n"
                i += 2
                continue
            elif n == 114:  # 'r'
                out += "\r"
                i += 2
                continue
            elif n == 92:  # backslash
                out += "\\"
                i += 2
                continue
        out += chr(c)
        i += 1
    return out^


def _atoi(s: String) -> Int:
    """Parse a non-negative integer (digits only; other chars ignored)."""
    var n = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 48 and c <= 57:
            n = n * 10 + (c - 48)
    return n


def _basename(path: String) raises -> String:
    var parts = path.split("/")
    return String(parts[len(parts) - 1])


def _relpath(path: String, base: String) raises -> String:
    """`path` made relative to `base` — the file's full name within the vault
    (e.g. `reports/q1.pdf`). This is a file's stable identity for the index diff,
    so same-named files in different subfolders don't collide. Falls back to the
    basename if `path` isn't under `base` (shouldn't happen)."""
    return String(String(path).removeprefix(base + "/"))


# ── chunking ──────────────────────────────────────────────────────────────────


def _file_text(path: String, kind: String) raises -> String:
    """Read a file to plain text per its kind. CSV rows are joined back with
    commas/newlines so semantically-related cells stay together in a chunk."""
    if kind == "csv":
        var rows = csv_rows(path)
        var out = String("")
        for i in range(len(rows)):
            if i > 0:
                out += "\n"
            for j in range(len(rows[i])):
                if j > 0:
                    out += ", "
                out += rows[i][j]
        return out^
    elif kind == "md":
        return md_text(path)
    elif kind == "pdf":
        return pdf_text(path)
    elif kind == "docx":
        return docx_text(path)
    return String("")


def _codepoint_windows(s: String, size: Int) raises -> List[String]:
    """Split `s` into windows of at most `size` codepoints (UTF-8-safe), so a
    single over-long line/segment can't become one giant chunk."""
    var out = List[String]()
    var cur = String("")
    var cnt = 0
    for cp in s.codepoint_slices():
        cur += String(cp)
        cnt += 1
        if cnt >= size:
            out.append(cur^)
            cur = String("")
            cnt = 0
    if cur.byte_length() > 0:
        out.append(cur^)
    return out^


def _tail_codepoints(s: String, n: Int) raises -> String:
    """The last `n` codepoints of `s` (for chunk overlap)."""
    if n <= 0:
        return String("")
    var cps = List[String]()
    for cp in s.codepoint_slices():
        cps.append(String(cp))
    var start = len(cps) - n
    if start < 0:
        start = 0
    var out = String("")
    for i in range(start, len(cps)):
        out += cps[i]
    return out^


def _chunk_text(text: String) raises -> List[String]:
    """Pack lines into ~CHUNK_SIZE-codepoint chunks on line boundaries; hard-split
    any single segment longer than CHUNK_SIZE; carry CHUNK_OVERLAP codepoints of
    the previous chunk into the next so context isn't lost at boundaries."""
    var chunks = List[String]()
    var lines = text.split("\n")
    var cur = String("")
    var cur_len = 0
    for li in range(len(lines)):
        var segs = _codepoint_windows(String(lines[li]), CHUNK_SIZE)
        for si in range(len(segs)):
            var seg = segs[si].copy()
            var seg_len = seg.count_codepoints()
            if cur_len > 0 and cur_len + seg_len + 1 > CHUNK_SIZE:
                chunks.append(cur.copy())
                cur = _tail_codepoints(cur, CHUNK_OVERLAP)
                cur_len = cur.count_codepoints()
            if cur_len > 0:
                cur += "\n"
                cur_len += 1
            cur += seg
            cur_len += seg_len
    if String(cur.strip()).byte_length() > 0:
        chunks.append(cur^)
    return chunks^


def _rmtree(path: String) raises:
    """Recursively delete `path` (file or directory). No-op if it doesn't exist.
    """
    if not exists(path):
        return
    if isfile(path):
        remove(path)
        return
    var entries = listdir(path)
    for i in range(len(entries)):
        _rmtree(path + "/" + String(entries[i]))
    rmdir(path)


# ── side-table persistence (id-keyed; ids are sparse) ─────────────────────────


def _load_sidetable() raises -> SideTable:
    var ids = List[Int]()
    var aliases = List[String]()
    var texts = List[String]()
    if not exists(_sidetable_path()):
        return SideTable(ids^, aliases^, texts^)
    var text: String
    with open(_sidetable_path(), "r") as f:
        text = f.read()
    var lines = text.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        var cols = line.split("\t")
        if len(cols) < 3:
            continue
        ids.append(_atoi(String(cols[0])))
        aliases.append(_tsv_unescape(String(cols[1])))
        texts.append(_tsv_unescape(String(cols[2])))
    return SideTable(ids^, aliases^, texts^)


def _write_sidetable(st: SideTable) raises:
    var out = String("")
    for i in range(len(st.ids)):
        out += (
            String(st.ids[i])
            + "\t"
            + _tsv_escape(st.aliases[i])
            + "\t"
            + _tsv_escape(st.texts[i])
            + "\n"
        )
    with open(_sidetable_path(), "w") as f:
        f.write(out)


def _drop_ranges(
    st: SideTable, starts: List[Int], counts: List[Int]
) raises -> SideTable:
    """Return a copy of `st` with every chunk whose id falls in any
    `[start, start+count)` removed."""
    var ids = List[Int]()
    var aliases = List[String]()
    var texts = List[String]()
    for i in range(len(st.ids)):
        var cid = st.ids[i]
        var drop = False
        for r in range(len(starts)):
            if cid >= starts[r] and cid < starts[r] + counts[r]:
                drop = True
                break
        if not drop:
            ids.append(cid)
            aliases.append(st.aliases[i].copy())
            texts.append(st.texts[i].copy())
    return SideTable(ids^, aliases^, texts^)


# ── manifest persistence ──────────────────────────────────────────────────────


def _load_manifest() raises -> Manifest:
    var entries = List[FileEntry]()
    if not exists(_manifest_path()):
        return Manifest(entries^, 0, 0, String(""), 1)
    var text: String
    with open(_manifest_path(), "r") as f:
        text = f.read()
    var next_id = 0
    var next_alias = 0
    var source_dir = String("")
    # Legacy manifests (no `next_gen` column) start the generation at 1, so their
    # already-persisted rows (gen 0 from `tsv_to_txn_rows`) stay strictly below any
    # generation assigned after the upgrade.
    var next_gen = 1
    var lines = text.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        var cols = line.split("\t")
        if String(cols[0]) == "#meta":
            if len(cols) >= 4:
                next_id = _atoi(String(cols[1]))
                next_alias = _atoi(String(cols[2]))
                source_dir = _tsv_unescape(String(cols[3]))
            if len(cols) >= 5:
                next_gen = _atoi(String(cols[4]))
            continue
        if len(cols) < 7:
            continue
        entries.append(
            FileEntry(
                String(cols[0]),
                _tsv_unescape(String(cols[1])),
                String(cols[2]),
                _atoi(String(cols[3])),
                String(cols[4]),
                _atoi(String(cols[5])),
                _atoi(String(cols[6])),
            )
        )
    return Manifest(entries^, next_id, next_alias, source_dir^, next_gen)


def index_manifest() raises -> List[FileInfo]:
    """The aliased manifest derived from the PERSISTED index (manifest.tsv) instead
    of a live directory walk — what `mill index` actually indexed.

    Each file's real path is reconstructed as ``<source_dir>/<name>`` (the path
    stays LOCAL-ONLY, exactly like ``build_manifest``), and the aliases are the
    SAME persisted, monotonic ones that ``search()`` returns in ``Chunk.file_alias``
    — so ``manifest()`` / ``csv_rows()`` / ``pdf_text()`` / ``md_text()`` line up
    with search hits (a live walk re-numbers ``file_0..`` in sorted order and can
    disagree after incremental add/delete). Returns an EMPTY list when nothing has
    been indexed yet, so callers can fall back to a live walk."""
    var m = _load_manifest()
    var infos = List[FileInfo]()
    for i in range(len(m.entries)):
        ref e = m.entries[i]
        var path = m.source_dir + "/" + e.name
        var cols = List[String]()
        if e.kind == "csv":
            try:
                cols = _csv_columns(path)
            except:
                cols = List[
                    String
                ]()  # unreadable header → no schema, still listed
        infos.append(
            FileInfo(e.falias.copy(), path, e.kind.copy(), e.size, cols^)
        )
    return infos^


def vault_files(fallback_dir: String) raises -> List[FileInfo]:
    """The vault's aliased file set — the SINGLE source of truth used by every
    tool. Prefer the persisted index manifest (what `mill index` indexed: its
    source_dir + the SAME aliases `search()` returns); fall back to a live walk of
    `fallback_dir` only when nothing has been indexed yet. This is what fixes the
    vault-dir mismatch: `manifest()`/readers and `search()` now agree on one file
    set regardless of which dir the app happens to serve."""
    var idx = index_manifest()
    if len(idx) > 0:
        return idx^
    return build_manifest(fallback_dir)


def _write_manifest(m: Manifest) raises:
    var out = (
        String("#meta\t")
        + String(m.next_id)
        + "\t"
        + String(m.next_alias)
        + "\t"
        + _tsv_escape(m.source_dir)
        + "\t"
        + String(m.next_gen)
        + "\n"
    )
    for i in range(len(m.entries)):
        ref e = m.entries[i]
        out += (
            e.falias
            + "\t"
            + _tsv_escape(e.name)
            + "\t"
            + e.kind
            + "\t"
            + String(e.size)
            + "\t"
            + e.sha
            + "\t"
            + String(e.id_start)
            + "\t"
            + String(e.chunk_count)
            + "\n"
        )
    with open(_manifest_path(), "w") as f:
        f.write(out)


def _find_by_name(entries: List[FileEntry], name: String) -> Int:
    for i in range(len(entries)):
        if entries[i].name == name:
            return i
    return -1


def _total_chunks(entries: List[FileEntry]) -> Int:
    var n = 0
    for i in range(len(entries)):
        n += entries[i].chunk_count
    return n


def _embed_chunks(
    base_url: String, chunks: List[String]
) raises -> List[Float32]:
    """Embed `chunks` in batches of EMBED_BATCH; return the flat row-major vectors
    (len == len(chunks) * EMBED_DIM)."""
    var vectors = List[Float32]()
    var start = 0
    while start < len(chunks):
        var stop = start + EMBED_BATCH
        if stop > len(chunks):
            stop = len(chunks)
        var batch = List[String]()
        for j in range(start, stop):
            batch.append(chunks[j].copy())
        var vecs: List[List[Float32]]
        try:
            vecs = embed_batch(base_url, batch)
        except err:
            raise Error(
                "build_index: embedding chunks ["
                + String(start)
                + ".."
                + String(stop)
                + ") failed (is the inference-server embedding model"
                " serving at "
                + base_url
                + "?): "
                + String(err)
            )
        for k in range(len(vecs)):
            if len(vecs[k]) != EMBED_DIM:
                raise Error(
                    "build_index: embedding dim "
                    + String(len(vecs[k]))
                    + " != expected "
                    + String(EMBED_DIM)
                )
            for d in range(len(vecs[k])):
                vectors.append(vecs[k][d])
        start = stop
    return vectors^


# ── build (incremental) ───────────────────────────────────────────────────────


def build_index(
    roots: List[String], base_url: String, force: Bool = False
) raises:
    """Incrementally bring the index in sync with `roots` — one or more files
    and/or directories. Directories are walked recursively; files are indexed
    directly. Embed only new and content-changed files, delete chunks for
    changed/removed files, skip unchanged files. A no-op when nothing changed.

    Every file is named RELATIVE to the common-ancestor directory of `roots` (the
    index `source_dir`), so a single folder behaves exactly as before
    (`reports/q1.pdf`) and several folders stay distinct (`WF/2019-01.pdf`,
    `Chase/…`).

    `force` rebuilds from scratch even when nothing changed — use it when the
    extraction/chunking logic itself changed (e.g. an improved PDF extractor),
    since file bytes (and thus the skip-hash) are unchanged in that case.

    Requires the inference-server embeddings endpoint live at `base_url`
    (e.g. http://127.0.0.1:8000/v1); a failed embed aborts with a clear error.
    """
    makedirs(config_dir(), exist_ok=True)

    # Normalise roots (drop trailing slashes), then derive the source base + the
    # explicit candidate-file set across every root (dirs recursed, files direct).
    var nroots = List[String]()
    for r in range(len(roots)):
        var rr = String(roots[r])
        while rr.byte_length() > 1 and rr.endswith("/"):
            rr = String(rr[byte = : rr.byte_length() - 1])
        nroots.append(rr^)
    var base = common_base(nroots)
    var allpaths = collect_index_paths(nroots)

    var have_manifest = exists(_manifest_path())
    var man = _load_manifest()
    var old = man.entries.copy()
    var next_id = man.next_id
    var next_alias = man.next_alias
    var next_gen = man.next_gen

    # Start clean when forced, or there's no manifest (clean machine / upgrade from
    # the pre-manifest format), or the vault dir changed — so ids/aliases can't
    # collide with stale data.
    var fresh = (
        force
        or (not have_manifest)
        or (len(old) > 0 and man.source_dir != base)
    )
    if fresh:
        _rmtree(_db_uri())
        if exists(_sidetable_path()):
            remove(_sidetable_path())
        if exists(_manifest_path()):
            remove(_manifest_path())
        old = List[FileEntry]()
        next_id = 0
        next_alias = 0
        next_gen = 1

    # Current files (sorted, csv/pdf/md only) + their content hashes.
    var infos = manifest_for_files(allpaths)
    print(
        "scanning "
        + String(len(infos))
        + " file(s) under "
        + base
        + " for changes…"
    )
    var cur_paths = List[String]()
    var cur_names = List[String]()
    var cur_kinds = List[String]()
    var cur_sizes = List[Int]()
    var cur_shas = List[String]()
    for i in range(len(infos)):
        ref fi = infos[i]
        cur_paths.append(fi.path.copy())
        # Identity = full name relative to the vault root (recursion-safe: two
        # `report.pdf` in different subfolders stay distinct).
        cur_names.append(_relpath(fi.path, base))
        cur_kinds.append(fi.kind.copy())
        cur_sizes.append(fi.size)
        cur_shas.append(sha256_file_hex(fi.path))
        # Name every file the scan found (the embed step below logs only the
        # new/changed ones, so unchanged files would otherwise be invisible).
        print("  • " + _relpath(fi.path, base) + " [" + fi.kind + "]")

    # Diff current vs old (by name + hash).
    var new_entries = List[
        FileEntry
    ]()  # unchanged carried over; embedded added below
    var emb_idx = List[Int]()  # indices into cur_* needing embedding
    var emb_alias = List[String]()  # the alias to assign each embedded file
    var del_starts = List[Int]()
    var del_counts = List[Int]()
    var removed_aliases = List[
        String
    ]()  # files dropped entirely (for txn eviction)
    var matched = List[Bool]()
    for _ in range(len(old)):
        matched.append(False)

    for i in range(len(cur_names)):
        var oi = _find_by_name(old, cur_names[i])
        if oi >= 0:
            matched[oi] = True
            if old[oi].sha == cur_shas[i]:
                new_entries.append(old[oi].copy())  # unchanged: keep as-is
            else:
                del_starts.append(old[oi].id_start)  # changed: drop old range,
                del_counts.append(
                    old[oi].chunk_count
                )  # re-embed under same alias
                emb_idx.append(i)
                emb_alias.append(old[oi].falias.copy())
        else:
            emb_idx.append(i)  # new: fresh alias
            emb_alias.append(String("file_") + String(next_alias))
            next_alias += 1

    for oi in range(len(old)):
        if not matched[oi]:  # removed: drop its range
            del_starts.append(old[oi].id_start)
            del_counts.append(old[oi].chunk_count)
            removed_aliases.append(old[oi].falias.copy())

    # The effective tag registry (built-in defaults + the user's categories.txt),
    # loaded once. Tagging is PURE — no model call, no re-embed — so we re-apply it
    # to the stored transactions on EVERY index. That decouples categorization from
    # embedding: editing categories.txt (or upgrading to a tags-aware build) re-tags
    # on a plain `mill index`, with no forced re-embed.
    var reg = load_registry()

    if len(emb_idx) == 0 and len(del_starts) == 0:
        # Embedding is up to date — but the category rules may have changed, so
        # re-tag the stored transactions (cheap, pure) and persist if anything moved.
        var only_trows = load_txn_rows()
        var retagged = retag(only_trows, reg)
        if retagged > 0:
            write_txn_rows(only_trows)
        print(
            "index up to date — "
            + String(len(new_entries))
            + " file(s), "
            + String(_total_chunks(new_entries))
            + " chunk(s); "
            + (
                "re-applied category tags" if retagged
                > 0 else "nothing changed"
            )
        )
        return

    var store = Store(_db_uri(), String(TABLE), EMBED_DIM)

    # Delete changed/removed chunk ranges (by id predicate; cheaper than IN-lists).
    for r in range(len(del_starts)):
        if del_counts[r] > 0:
            store.delete(
                String("id >= ")
                + String(del_starts[r])
                + " AND id < "
                + String(del_starts[r] + del_counts[r])
            )

    var st = _load_sidetable()
    st = _drop_ranges(st, del_starts, del_counts)

    # Structured transactions live in their own side-table; evict the re-embedded +
    # removed files' rows, then re-extract the embedded ones below (in lockstep).
    var trows = load_txn_rows()
    var txn_drop = removed_aliases.copy()
    for t in range(len(emb_alias)):
        txn_drop.append(emb_alias[t].copy())
    trows = drop_aliases(trows, txn_drop)

    print(
        "embedding "
        + String(len(emb_idx))
        + " new/changed file(s)"
        + (
            " (the embedding model loads on first use — this can take a bit)…" if len(
                old
            )
            == 0 else "…"
        )
    )

    # All transactions extracted in THIS index run share one insertion generation
    # (`cur_gen`); it advances only if the run actually adds rows, so the ledger
    # sees each re-index of new statements as a distinct, higher generation.
    var cur_gen = next_gen
    var txns_before = len(trows)

    # Embed only new + changed files; append to LanceDB + the side-table.
    for t in range(len(emb_idx)):
        var i = emb_idx[t]
        var falias = emb_alias[t].copy()
        var body = _file_text(cur_paths[i], cur_kinds[i])

        # Extract structured transactions ONCE here, with whole-document context.
        # Tags are filled by the single _retag pass before write (the one source of
        # tags), so extraction here stays tag-agnostic.
        if cur_kinds[i] == "csv":
            # A CSV export is ALREADY structured → map its columns to records
            # directly (no reconciliation; every data row is a transaction). Each
            # row usually carries its own full date, so the year is per-row.
            var ctxns = csv_transactions(csv_rows(cur_paths[i]))
            for x in range(len(ctxns)):
                ref ct = ctxns[x]
                # Location split of the descriptor, computed ONCE here + persisted.
                var loc = parse_location(ct.desc)
                trows.append(
                    TxnRow(
                        falias.copy(),
                        ct.date.copy(),
                        ct.amount,
                        ct.direction.copy(),
                        ct.desc.copy(),
                        List[String](),
                        cur_gen,
                        ct.year,
                        loc.merchant.copy(),
                        loc.country.copy(),
                        loc.state.copy(),
                    )
                )
        else:
            # PDF/text statements are UNSTRUCTURED — persist only those that
            # RECONCILE against the statement's own arithmetic (running balance or
            # printed totals). Unreconciled/none → nothing written, callers fall
            # back to chunks. Needs COLUMN-ALIGNED text; for PDFs, re-extract
            # layout-preserved (`body` is stream-order, good for chunks/search).
            var txn_src = (
                readers.pdf_text_layout(cur_paths[i]) if cur_kinds[i]
                == "pdf" else body
            )
            var ext = extract_transactions(txn_src)
            if ext.reconciled:
                # The year lives in the statement header/period, not on the M/D
                # rows — detect it once per document and stamp every row from it.
                var syear = statement_year(txn_src)
                for x in range(len(ext.txns)):
                    ref tx = ext.txns[x]
                    # Location split of the descriptor, computed ONCE here + persisted.
                    var loc = parse_location(tx.desc)
                    trows.append(
                        TxnRow(
                            falias.copy(),
                            tx.date.copy(),
                            tx.amount,
                            tx.direction.copy(),
                            tx.desc.copy(),
                            List[String](),
                            cur_gen,
                            syear,
                            loc.merchant.copy(),
                            loc.country.copy(),
                            loc.state.copy(),
                        )
                    )

        var chunks = _chunk_text(body)
        # Print BEFORE the (slow) embed so a multi-page file isn't a silent stall.
        print(
            "  "
            + falias
            + " ["
            + cur_kinds[i]
            + "] "
            + cur_names[i]
            + " — "
            + String(len(chunks))
            + " chunk(s), embedding…"
        )
        var id_start = next_id
        var ids = List[Int64]()
        for c in range(len(chunks)):
            var cid = next_id + c
            ids.append(Int64(cid))
            st.ids.append(cid)
            st.aliases.append(falias.copy())
            st.texts.append(chunks[c].copy())
        var vectors = _embed_chunks(base_url, chunks)
        store.add(ids, vectors)
        next_id += len(chunks)
        new_entries.append(
            FileEntry(
                falias.copy(),
                cur_names[i].copy(),
                cur_kinds[i].copy(),
                cur_sizes[i],
                cur_shas[i].copy(),
                id_start,
                len(chunks),
            )
        )

    # Deletes are soft tombstones; compact so storage/scan cost stay bounded.
    if len(del_starts) > 0:
        store.optimize()

    # Advance the generation only if this run added transactions, so `next_gen`
    # reflects the number of insertion epochs, not the number of index runs.
    if len(trows) > txns_before:
        next_gen = cur_gen + 1
    _write_sidetable(st)
    # Guard against double-counting: drop CROSS-FILE duplicate transactions (the same
    # record in more than one file — overlapping CSV date ranges, a re-exported
    # statement saved under a new name). Content-identical FILES are already skipped by
    # the hash diff above; this catches the same records arriving via DIFFERENT files.
    var pre_dedup = len(trows)
    trows = dedupe_txns(trows)
    if pre_dedup > len(trows):
        print(
            "  deduped "
            + String(pre_dedup - len(trows))
            + " duplicate transaction(s) across overlapping files"
        )
    # Tag EVERY transaction (newly-extracted AND unchanged-file rows carried over)
    # from the current registry — one pure pass, the single source of tags.
    _ = retag(trows, reg)
    write_txn_rows(trows)
    # Backfill ML-rule tags (`<tag> : <question>`) for the NEWLY-extracted files
    # via the on-device model — the fuzzy tail no keyword captures, paid once at
    # index (carried-over rows keep their cached ML tags). Best-effort: a classify
    # failure (engine busy, chat model not serving) must never abort indexing.
    if len(emb_alias) > 0:
        try:
            var ml_changed = ml_backfill_rows(trows, reg, base_url, emb_alias)
            if ml_changed > 0:
                write_txn_rows(trows)
                print(
                    "  backfilled ML tags on "
                    + String(ml_changed)
                    + " transaction(s)"
                )
            # The freshly-inserted generation is now classified inline for every
            # active ML rule → advance the ledger markers so the between-questions
            # worker / `millfolio backfill` don't redo this generation's
            # negatives (only advances rules with no older backlog).
            ledger_note_backfilled(reg, trows, cur_gen)
        except e:
            print("  (ML tag pass skipped: " + String(e) + ")")
    _write_manifest(Manifest(new_entries^, next_id, next_alias, base, next_gen))
    print(
        "index updated — "
        + String(len(emb_idx))
        + " file(s) embedded, "
        + String(len(del_starts))
        + " range(s) removed; "
        + String(len(st.ids))
        + " chunk(s) total"
    )


# ── search ────────────────────────────────────────────────────────────────────


def search(query: String, k: Int, base_url: String) raises -> List[Chunk]:
    """Semantic search: embed `query`, k-NN over the LanceDB store, resolve each
    returned chunk_id back to (file_alias, text) via the side-table. Nearest
    first. Requires the index to exist and the embedding endpoint to be live."""
    if not exists(_sidetable_path()):
        raise Error(
            "no index side-table at "
            + _sidetable_path()
            + " — run `mill index` first"
        )
    var st = _load_sidetable()

    # Qwen3-Embedding is instruction-tuned: QUERIES get an instruction prefix,
    # documents (the indexed chunks) stay raw. This materially improves ranking.
    var q_instructed = (
        String(
            "Instruct: Given a search query, retrieve relevant passages that"
            " answer it.\nQuery: "
        )
        + query
    )
    var qvec = embed(base_url, q_instructed)
    var store = Store(_db_uri(), String(TABLE), EMBED_DIM)
    var result = store.search(qvec, k)
    var ids = result[0].copy()
    var dists = result[1].copy()

    var hits = List[Chunk]()
    for i in range(len(ids)):
        var cid = Int(ids[i])
        # ids are sparse — scan the side-table for this chunk id.
        for j in range(len(st.ids)):
            if st.ids[j] == cid:
                hits.append(
                    Chunk(st.aliases[j].copy(), st.texts[j].copy(), dists[i])
                )
                break
    return hits^


# ── enumeration (complete coverage, not similarity-ranked) ────────────────────


def file_chunks(file_alias: String) raises -> List[String]:
    """EVERY indexed chunk of one file, in document order — the complete text the
    index already extracted, reachable by enumeration (unlike `search()`, which is
    similarity-ranked top-k and structurally undercounts aggregations).

    For count/sum/max over a file, read all of its chunks instead of gambling on the
    top-k. Returns `[]` for an unknown alias or an unindexed vault. (Ordering/filter
    logic is `transactions.texts_for_alias`, unit-tested hermetically.)"""
    if not exists(_sidetable_path()):
        return List[String]()
    var st = _load_sidetable()
    return texts_for_alias(st.ids, st.aliases, st.texts, file_alias)


# ── structured transactions (reconcile-validated, extracted at index time) ────
# The row type + (de)serialization + selection live in vault.extract.transactions
# (pure); the registry + tags + transactions.tsv I/O live in vault.derive.store
# (LanceDB-free, shared by the CLI + app server). `build_index` just calls them.


def file_transactions(file_alias: String) raises -> List[Txn]:
    """The reconcile-VERIFIED transactions of one file (date/desc/amount/direction),
    extracted once at index time. EMPTY when the file has none or its transactions
    could not be reconciled against the statement's own totals — in which case the
    caller should fall back to `file_chunks()` + `ask_local`, not trust a guess.
    """
    return select_txns(load_txn_rows(), file_alias)

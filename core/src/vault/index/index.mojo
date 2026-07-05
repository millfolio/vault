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
    reconcile_txn_gens,
    select_txns,
    texts_for_alias,
    txn_rows_to_tsv,
    tsv_to_txn_rows,
)
from vault.extract.location import parse_location
from vault.derive.store import (
    config_dir,
    load_registry,
    load_txn_rows,
    load_ledger,
    write_txn_rows,
    retag,
    ml_backfill_rows,
    ledger_note_backfilled,
)


comptime CHUNK_SIZE = 512  # ~codepoints per chunk
comptime CHUNK_OVERLAP = 64  # codepoints carried into the next chunk for context
comptime TABLE = "chunks"
comptime EMBED_BATCH = 64  # chunks per /v1/embeddings request

# The extraction/parsing/chunking pipeline's PROCESSING version. BUMP this whenever
# that logic changes (a new Txn field, a better PDF extractor, different chunking)
# so existing indexes rebuild even though the file bytes — and thus the skip-hash —
# are unchanged. `build_index` persists the last-built value in a marker file and
# auto-forces a full rebuild on a mismatch. A MISSING marker reads as 0, so every
# index built before this mechanism landed counts as older and rebuilds once.
# v1: `.merchant`/`.state`/`.country` location fields filled by `parse_location`.
# v2: parse_location: strip trailing parenthetical annotations (e.g. `(return)`).
# v3: parse_location: extract city + zip.
# v4: direction-gated tags — expense tags apply only to debits, income tags
#     (transfers/rewards) only to credits (so a credit/ACH deposit never carries an
#     expense category); a re-index re-tags existing rows with the new gate.
comptime INDEX_PROCESSING_VERSION = 4


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


def _procversion_path() raises -> String:
    """The processing-version marker — a tiny file next to manifest.tsv holding just
    the integer version the index was last built under, so it moves with the store.
    """
    return config_dir() + "/.index.procversion"


# ── processing version (auto-force a rebuild when the pipeline changes) ────────


def _read_procversion() raises -> Int:
    """The stored index processing version. A missing OR unreadable marker reads as
    0 (older than any real version), so it triggers a one-time rebuild."""
    if not exists(_procversion_path()):
        return 0
    try:
        var text: String
        with open(_procversion_path(), "r") as f:
            text = f.read()
        return _atoi(String(text.strip()))
    except:
        return 0


def _write_procversion() raises:
    """Stamp the CURRENT processing version. Call ONLY after a fully successful
    build — an aborted/failed index must not stamp the new version, or it would
    wrongly skip the rebuild it still owes on the next run."""
    with open(_procversion_path(), "w") as f:
        f.write(String(INDEX_PROCESSING_VERSION))


def index_effective_force(stored_version: Int, force: Bool) -> Bool:
    """Whether this run must rebuild-from-scratch even for byte-unchanged files:
    an explicit `--force`, OR a stored processing version that differs from the
    current INDEX_PROCESSING_VERSION (the extraction/parse/chunk logic changed).
    """
    return force or (stored_version != INDEX_PROCESSING_VERSION)


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
    (len == len(chunks) * EMBED_DIM).

    TEST HOOK: when `MILLFOLIO_FAKE_EMBED` is set (non-empty), skip the network and
    return deterministic unit vectors of the right shape. Only the chunk COUNT (not
    the embedding VALUES) influences the manifest / side-table / transaction bytes,
    so this lets the hermetic index-parity tests drive `build_index` /
    `index_one_file` end-to-end without a live embeddings endpoint."""
    if getenv("MILLFOLIO_FAKE_EMBED", "") != "":
        var out = List[Float32]()
        for _c in range(len(chunks)):
            for d in range(EMBED_DIM):
                out.append(Float32(1) if d == 0 else Float32(0))
        return out^
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


# ── build (incremental) — factored into per-file steps + a finalize settle ─────
# The indexer is now driven ONE FILE AT A TIME so the app-server orchestrator can
# pause / yield to an interactive query between files (see app/server
# ORCHESTRATOR.md §2.1). `build_index` is exactly:
#     _prepare_index_run(base, force)          # fresh-reset decision (run-level)
#     for f in files: index_one_file(f, base)  # embed ONE file, COMMIT it
#     finalize_index(files, base)              # prune removed + reconcile + retag
# Each `index_one_file` persists its manifest row + chunks + txn rows before it
# returns, so a pause/crash between files leaves a CONSISTENT partial index a later
# run resumes (the `#meta` counters — next_id / next_alias / next_gen — live in the
# manifest, so they carry across steps). `finalize_index` is the end-of-run settle:
# it prunes files no longer tracked, runs the dedupe + `reconcile_txn_gens` + retag
# + ML-backfill pass, and closes the generation. Driving the whole directory
# through this loop reproduces the old monolithic `build_index` byte-for-byte (same
# manifest, same gens, same tags) — the parity net the index-steps test pins.


@fieldwise_init
struct FileStepResult(Copyable, Movable, Writable):
    """What `index_one_file` did to one file. `action` is `"embedded"` (new or
    content-changed → re-embedded), `"skipped"` (name + hash unchanged), or
    `"unsupported"` (not a CSV/PDF/Markdown/DOCX). `falias` is the file's stable
    alias; `chunk_count` the number of chunks it now has (0 for unsupported)."""

    var action: String
    var falias: String
    var chunk_count: Int

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            self.action, " ", self.falias, " (", self.chunk_count, " chunk(s))"
        )


def _has_str(xs: List[String], s: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == s:
            return True
    return False


# ── prev-row stash (crash-safe reconcile input across per-file steps) ──────────
# `reconcile_txn_gens` needs the FULL pre-run transaction set so an unchanged row
# keeps its `added_gen` across a re-index. But per-file steps EVICT a changed /
# removed file's old rows the moment they run (so a query between files never
# double-counts), which would erase them from that pre-run set. So every eviction
# APPENDS the evicted rows to a durable stash file; `finalize_index` reads it (∪
# the still-present old rows) as `prev`, then clears it. The stash survives a pause
# — that's what keeps the gen-reconciliation from regressing in the sliced model.


def _prevstash_path() raises -> String:
    return config_dir() + "/.index.pending_prev.tsv"


def _append_prevstash(rows: List[TxnRow]) raises:
    """Append evicted rows to the prev stash (read-modify-write; the stash only ever
    holds one run's evicted rows, so it stays small)."""
    if len(rows) == 0:
        return
    var prior = String("")
    if exists(_prevstash_path()):
        with open(_prevstash_path(), "r") as f:
            prior = f.read()
    with open(_prevstash_path(), "w") as f:
        f.write(prior + txn_rows_to_tsv(rows))


def _load_prevstash() raises -> List[TxnRow]:
    if not exists(_prevstash_path()):
        return List[TxnRow]()
    var text: String
    with open(_prevstash_path(), "r") as f:
        text = f.read()
    return tsv_to_txn_rows(text)


def _clear_prevstash() raises:
    if exists(_prevstash_path()):
        remove(_prevstash_path())


def _drop_ge(st: SideTable, threshold: Int) raises -> SideTable:
    """A copy of `st` with every chunk whose id is >= `threshold` removed — the
    crash cleanup: committed chunks always sit below `next_id`, so anything at or
    above it is an orphan left by a per-file step that died before its manifest
    commit."""
    var ids = List[Int]()
    var aliases = List[String]()
    var texts = List[String]()
    for i in range(len(st.ids)):
        if st.ids[i] < threshold:
            ids.append(st.ids[i])
            aliases.append(st.aliases[i].copy())
            texts.append(st.texts[i].copy())
    return SideTable(ids^, aliases^, texts^)


def _rows_for_aliases(
    rows: List[TxnRow], aliases: List[String]
) raises -> List[TxnRow]:
    """The subset of `rows` whose alias is in `aliases` (the rows about to be
    evicted — stashed so `finalize_index` can reconcile against them)."""
    var out = List[TxnRow]()
    for i in range(len(rows)):
        if _has_str(aliases, rows[i].falias):
            out.append(rows[i].copy())
    return out^


def _extract_txn_rows(
    path: String, kind: String, body: String, falias: String, gen: Int
) raises -> List[TxnRow]:
    """The structured-transaction extraction for ONE file, stamped with insertion
    generation `gen` and alias `falias`. CSV exports map columns directly (every row
    is a record); PDF/text statements are trusted only when they RECONCILE against
    the statement's own arithmetic. Tags are left empty here (the single retag pass
    in `finalize_index` is the source of tags). Extracted identically to the old
    monolithic embed loop, so the persisted rows are byte-for-byte the same."""
    var rows = List[TxnRow]()
    if kind == "csv":
        var ctxns = csv_transactions(csv_rows(path))
        for x in range(len(ctxns)):
            ref ct = ctxns[x]
            var loc = parse_location(ct.desc)
            rows.append(
                TxnRow(
                    falias.copy(),
                    ct.date.copy(),
                    ct.amount,
                    ct.direction.copy(),
                    ct.desc.copy(),
                    List[String](),
                    gen,
                    ct.year,
                    loc.merchant.copy(),
                    loc.country.copy(),
                    loc.state.copy(),
                    loc.city.copy(),
                    loc.zip.copy(),
                )
            )
    else:
        # PDF/text: needs COLUMN-ALIGNED text; for PDFs re-extract layout-preserved
        # (`body` is stream-order, good for chunks/search but not column direction).
        var txn_src = readers.pdf_text_layout(path) if kind == "pdf" else body
        var ext = extract_transactions(txn_src)
        if ext.reconciled:
            var syear = statement_year(txn_src)
            for x in range(len(ext.txns)):
                ref tx = ext.txns[x]
                var loc = parse_location(tx.desc)
                rows.append(
                    TxnRow(
                        falias.copy(),
                        tx.date.copy(),
                        tx.amount,
                        tx.direction.copy(),
                        tx.desc.copy(),
                        List[String](),
                        gen,
                        syear,
                        loc.merchant.copy(),
                        loc.country.copy(),
                        loc.state.copy(),
                        loc.city.copy(),
                        loc.zip.copy(),
                    )
                )
    return rows^


def _prepare_index_run(base: String, force: Bool) raises:
    """Run-level setup BEFORE the per-file loop: decide whether this run must
    rebuild from scratch (an explicit `--force`, a processing-version bump, no
    manifest, or a changed source dir) and, if so, wipe the store / side-table /
    manifest and re-establish an empty manifest at the SAME `next_gen` (preserved so
    the ML-backfill ledger stays monotonic — see the old build's fresh block). The
    incremental case leaves the existing manifest untouched. The prev stash is
    cleared so a leaked stash from a crashed prior run can't leak into this one.
    `transactions.tsv` is deliberately KEPT even on a fresh rebuild — the per-file
    steps evict its rows into the stash so `reconcile_txn_gens` can still restore
    unchanged rows' generations. The processing-version marker is stamped only by
    `finalize_index`, after a fully successful run."""
    var have_manifest = exists(_manifest_path())
    var man = _load_manifest()
    var stored_version = _read_procversion()
    var effective_force = index_effective_force(stored_version, force)
    if stored_version != INDEX_PROCESSING_VERSION:
        print(
            "index processing version changed (v"
            + String(stored_version)
            + " → v"
            + String(INDEX_PROCESSING_VERSION)
            + "): rebuilding all files"
        )
    var fresh = (
        effective_force
        or (not have_manifest)
        or (len(man.entries) > 0 and man.source_dir != base)
    )
    _clear_prevstash()
    if fresh:
        var run_gen = (
            man.next_gen
        )  # preserve — MUST stay monotonic across rebuild
        _rmtree(_db_uri())
        if exists(_sidetable_path()):
            remove(_sidetable_path())
        if exists(_manifest_path()):
            remove(_manifest_path())
        # A valid empty manifest so the first `index_one_file` resumes from a clean,
        # consistent state (ids/aliases reset to 0, source dir + open generation set).
        _write_manifest(Manifest(List[FileEntry](), 0, 0, base, run_gen))


def index_one_file(
    path: String, base: String, base_url: String
) raises -> FileStepResult:
    """Ensure ONE file is indexed against the CURRENT persisted index, and COMMIT it.

    Hashes `path`; if its name + content hash already match the manifest, it's a
    no-op skip (no writes). Otherwise it embeds the file into a FRESH id range —
    reusing the file's stable alias when the file changed, minting a new one when
    it's new — appends its chunks (side-table + LanceDB) and its reconcile-validated
    transaction rows (stamped the manifest's open generation), and rewrites the
    manifest row LAST. Because the manifest (the authoritative `#meta` counters) is
    written after the side-table + txn rows, a crash before that commit leaves the
    file looking un-indexed, so a later run re-embeds it cleanly (any orphan chunks
    at id >= next_id, or orphan rows under the alias, are purged first). Its old rows
    are stashed for `finalize_index`'s generation reconcile. Returns what it did.
    """
    var infos = manifest_for_files([path])
    if len(infos) == 0:
        return FileStepResult(String("unsupported"), String(""), 0)
    var kind = infos[0].kind.copy()
    var size = infos[0].size
    var name = _relpath(path, base)
    var sha = sha256_file_hex(path)

    var man = _load_manifest()
    var run_gen = man.next_gen  # the OPEN insertion generation for this run
    var oi = _find_by_name(man.entries, name)
    if oi >= 0 and man.entries[oi].sha == sha:
        # Unchanged (same name + same content hash) — nothing to do.
        return FileStepResult(
            String("skipped"),
            man.entries[oi].falias.copy(),
            man.entries[oi].chunk_count,
        )

    # This file needs (re-)embedding. Load the side state.
    var st = _load_sidetable()
    var trows = load_txn_rows()
    var store = Store(_db_uri(), String(TABLE), EMBED_DIM)
    var did_delete = False

    var falias: String
    if oi >= 0:
        # Changed: drop the old chunk range + reuse the stable alias.
        falias = man.entries[oi].falias.copy()
        var os = man.entries[oi].id_start
        var oc = man.entries[oi].chunk_count
        if oc > 0:
            store.delete(
                String("id >= ") + String(os) + " AND id < " + String(os + oc)
            )
            did_delete = True
        st = _drop_ranges(st, [os], [oc])
    else:
        # New: mint a fresh alias.
        falias = String("file_") + String(man.next_alias)
        man.next_alias += 1

    # Crash cleanup: purge any orphan chunks a died-mid-commit prior attempt left at
    # id >= next_id (committed chunks are always below next_id).
    var has_orphan = False
    for i in range(len(st.ids)):
        if st.ids[i] >= man.next_id:
            has_orphan = True
            break
    if has_orphan:
        store.delete(String("id >= ") + String(man.next_id))
        did_delete = True
        st = _drop_ge(st, man.next_id)

    # Evict any rows already stored under this alias (a changed re-embed, a fresh
    # rebuild reusing the alias, or a crashed prior attempt) and STASH them so the
    # finalize reconcile still sees this file's pre-run rows.
    var evicted = _rows_for_aliases(trows, [falias])
    if len(evicted) > 0:
        _append_prevstash(evicted)
        trows = drop_aliases(trows, [falias])

    # Extract this file's transactions (stamped the open generation) + its chunks.
    var body = _file_text(path, kind)
    var newrows = _extract_txn_rows(path, kind, body, falias, run_gen)
    for r in range(len(newrows)):
        trows.append(newrows[r].copy())

    var chunks = _chunk_text(body)
    var id_start = man.next_id
    var ids = List[Int64]()
    for c in range(len(chunks)):
        var cid = man.next_id + c
        ids.append(Int64(cid))
        st.ids.append(cid)
        st.aliases.append(falias.copy())
        st.texts.append(chunks[c].copy())
    var vectors = _embed_chunks(base_url, chunks)
    store.add(ids, vectors)
    man.next_id += len(chunks)
    if did_delete:
        store.optimize()  # compact soft-delete tombstones

    var entry = FileEntry(
        falias.copy(),
        name.copy(),
        kind.copy(),
        size,
        sha.copy(),
        id_start,
        len(chunks),
    )
    if oi >= 0:
        man.entries[oi] = entry^
    else:
        man.entries.append(entry^)

    # COMMIT — side-table + txn rows first, manifest LAST (its `#meta` counters are
    # the authoritative record of what's committed).
    man.source_dir = base
    _write_sidetable(st)
    write_txn_rows(trows)
    _write_manifest(man)
    return FileStepResult(String("embedded"), falias, len(chunks))


def finalize_index(files: List[String], base: String, base_url: String) raises:
    """The end-of-run settle after any number (0..N) of `index_one_file` steps —
    idempotent and safe to call however many files ran. Prunes manifest entries (+
    their chunks + txn rows) for files no longer in `files` (the tracked set), then
    runs the SAME closing pass the old monolithic build did: dedupe cross-file
    duplicate transactions, `reconcile_txn_gens` the freshly-extracted rows against
    the pre-run set (so unchanged rows keep their generation + cached ML tags),
    retag from the current registry, ML-backfill this run's new rows, close the
    generation, and stamp the processing-version marker. Reproduces the old build's
    output byte-for-byte when the whole directory was driven through the loop.
    """
    var man = _load_manifest()
    var run_gen = man.next_gen

    var tracked = List[String]()
    for i in range(len(files)):
        tracked.append(_relpath(files[i], base))

    # ── prune files no longer tracked (removed since the last index) ────────────
    var kept = List[FileEntry]()
    var removed_aliases = List[String]()
    var del_starts = List[Int]()
    var del_counts = List[Int]()
    for i in range(len(man.entries)):
        ref e = man.entries[i]
        if _has_str(tracked, e.name):
            kept.append(e.copy())
        else:
            removed_aliases.append(e.falias.copy())
            del_starts.append(e.id_start)
            del_counts.append(e.chunk_count)

    var trows = load_txn_rows()
    if len(removed_aliases) > 0:
        man.entries = kept^
        var st = _load_sidetable()
        st = _drop_ranges(st, del_starts, del_counts)
        _write_sidetable(st)
        if exists(_db_uri()):
            var store = Store(_db_uri(), String(TABLE), EMBED_DIM)
            var did_delete = False
            for r in range(len(del_starts)):
                if del_counts[r] > 0:
                    store.delete(
                        String("id >= ")
                        + String(del_starts[r])
                        + " AND id < "
                        + String(del_starts[r] + del_counts[r])
                    )
                    did_delete = True
            if did_delete:
                store.optimize()
        # Evict removed files' rows — stash them so `prev` stays the full pre-run set.
        var removed_rows = _rows_for_aliases(trows, removed_aliases)
        if len(removed_rows) > 0:
            _append_prevstash(removed_rows)
        trows = drop_aliases(trows, removed_aliases)

    # Did this run add any transactions? (rows at the open generation, pre-dedupe) —
    # this is what advances the generation, mirroring the old `len(trows) > before`.
    var has_new = False
    var emb_aliases = List[String]()
    for i in range(len(trows)):
        if trows[i].added_gen == run_gen:
            has_new = True
            if not _has_str(emb_aliases, trows[i].falias):
                emb_aliases.append(trows[i].falias.copy())

    # `prev` = the FULL pre-run transaction set = the stash (evicted changed/removed
    # rows) ∪ the still-present old rows (gen < the open generation). Built BEFORE the
    # dedupe so it matches the old build's pre-dedupe snapshot.
    var prev = _load_prevstash()
    for i in range(len(trows)):
        if trows[i].added_gen < run_gen:
            prev.append(trows[i].copy())

    var reg = load_registry()

    # Dedupe cross-file duplicate transactions (same record in more than one file).
    var pre_dedup = len(trows)
    trows = dedupe_txns(trows)
    if pre_dedup > len(trows):
        print(
            "  deduped "
            + String(pre_dedup - len(trows))
            + " duplicate transaction(s) across overlapping files"
        )

    # Reconcile the freshly-extracted rows against the pre-run set (unchanged rows
    # reuse their prior generation + cached ML tags), then retag from the registry.
    _ = reconcile_txn_gens(trows, prev)
    _ = retag(trows, reg)
    write_txn_rows(trows)

    # Backfill ML-rule tags for THIS run's newly-extracted files (best-effort — a
    # classify failure must never abort the index). Gated on `has_new`: with no new
    # rows there is nothing to classify (the drain / worker owns any older backlog).
    if has_new:
        try:
            var ml_changed = ml_backfill_rows(
                trows, reg, base_url, emb_aliases, load_ledger()
            )
            if ml_changed > 0:
                write_txn_rows(trows)
                print(
                    "  backfilled ML tags on "
                    + String(ml_changed)
                    + " transaction(s)"
                )
            ledger_note_backfilled(reg, trows, run_gen)
        except e:
            print("  (ML tag pass skipped: " + String(e) + ")")

    # Close the generation only if this run added rows (so `next_gen` counts
    # insertion epochs, not index runs), then persist the manifest + version marker.
    if has_new:
        man.next_gen = run_gen + 1
    man.source_dir = base
    _write_manifest(man)
    _write_procversion()
    _clear_prevstash()

    var total_chunks = 0
    for i in range(len(man.entries)):
        total_chunks += man.entries[i].chunk_count
    print(
        "index updated — "
        + String(len(man.entries))
        + " file(s), "
        + String(len(removed_aliases))
        + " removed; "
        + String(total_chunks)
        + " chunk(s) total"
    )


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

    This is the whole-directory driver over the per-file entrypoints: a run-level
    fresh-reset decision, then `index_one_file` for every candidate, then
    `finalize_index`. Behaves identically to the old monolithic build (same manifest
    bytes, same generations, same tags) — that parity is the safety net."""
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

    # The candidate file set (sorted, kind-filtered) — the tracked set finalize prunes
    # against, and the files the loop drives one at a time.
    var infos = manifest_for_files(allpaths)
    print(
        "scanning "
        + String(len(infos))
        + " file(s) under "
        + base
        + " for changes…"
    )
    var files = List[String]()
    for i in range(len(infos)):
        files.append(infos[i].path.copy())
        print(
            "  • " + _relpath(infos[i].path, base) + " [" + infos[i].kind + "]"
        )

    _prepare_index_run(base, force)
    for i in range(len(files)):
        var res = index_one_file(files[i], base, base_url)
        if res.action == "embedded":
            print(
                "  ["
                + String(i + 1)
                + "/"
                + String(len(files))
                + "] "
                + res.falias
                + " — "
                + String(res.chunk_count)
                + " chunk(s), embedded"
            )
    finalize_index(files, base, base_url)


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

"""Index-steps parity — the SAFETY NET for the per-file / finalize refactor.

`build_index` was factored into per-file steps so the app-server scheduler can
drive indexing one file at a time (pausable between files): the whole-directory
build is now exactly `_prepare_index_run` → `index_one_file` per candidate →
`finalize_index`. This test pins that the sliced path stays behaviourally
identical to the monolithic build and that a partial (paused) index is consistent:

  1. PARITY — N per-file steps + finalize produce a BYTE-IDENTICAL manifest.tsv,
     transactions.tsv, and chunks.tsv (same aliases, id ranges, generations, and
     tags) as one `build_index` over the same directory.
  2. PARTIAL — a single `index_one_file` COMMITS that one file (its manifest row +
     chunks + txn rows) and leaves the OTHER files un-indexed — a consistent
     partial index a later run resumes.
  3. PRUNE — `finalize_index` over a REDUCED tracked set removes a file's manifest
     entry, chunks, and transactions (the removed-file path moved out of the
     per-file loop and into finalize).

A real `build_index` needs a live embeddings endpoint; this runs hermetically via
the `MILLFOLIO_FAKE_EMBED` hook in `_embed_chunks` (deterministic unit vectors —
only the chunk COUNT, not the embedding values, affects the compared bytes), a
pinned `MILLFOLIO_DATA_DIR`, and hand-written CSV/Markdown fixtures (no private
data). The default registry has no ML rules, so no model call is made.
`pixi run test-index-steps`.
"""

from std.os import getenv, makedirs, remove
from std.os.path import exists

from vault.index.index import (
    build_index,
    index_one_file,
    finalize_index,
    FileStepResult,
    _manifest_path,
    _sidetable_path,
    _procversion_path,
    _prevstash_path,
    _db_uri,
    _rmtree,
)
from vault.index.manifest import (
    collect_index_paths,
    common_base,
    manifest_for_files,
)
from vault.derive.tags import config_dir, txns_path, ledger_path
from vault.extract.transactions import tsv_to_txn_rows, TxnRow


comptime FAKE_URL = "http://127.0.0.1:1/v1"


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def _write(path: String, content: String) raises:
    with open(path, "w") as f:
        f.write(content)


def _read(path: String) raises -> String:
    if not exists(path):
        return String("")
    with open(path, "r") as f:
        return f.read()


def _clear_index() raises:
    """Remove every persisted index artefact so each build starts from an identical
    clean slate (the fixtures + categories.txt are left in place — the latter is the
    deterministic default, shared by both builds)."""
    for p in [
        _manifest_path(),
        _sidetable_path(),
        _procversion_path(),
        _prevstash_path(),
        txns_path(),
        ledger_path(),
    ]:
        if exists(p):
            remove(p)
    _rmtree(_db_uri())


def _load_txns() raises -> List[TxnRow]:
    return tsv_to_txn_rows(_read(txns_path()))


def _rows_for(rows: List[TxnRow], falias: String) -> Int:
    var n = 0
    for i in range(len(rows)):
        if rows[i].falias == falias:
            n += 1
    return n


def _chunks_for(falias: String) raises -> Int:
    """Count side-table (chunks.tsv) rows whose alias == `falias`."""
    var n = 0
    var lines = _read(_sidetable_path()).split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        var cols = line.split("\t")
        if len(cols) >= 2 and String(cols[1]) == falias:
            n += 1
    return n


def main() raises:
    var dd = String(getenv("MILLFOLIO_DATA_DIR", "").strip())
    expect(dd != "", "MILLFOLIO_DATA_DIR must be set by the test task")
    expect(
        getenv("MILLFOLIO_FAKE_EMBED", "") != "",
        "MILLFOLIO_FAKE_EMBED must be set by the test task",
    )
    makedirs(dd, exist_ok=True)

    # ── fixtures: two CSV exports (with transactions) + a chunk-only markdown ────
    var vault = dd + "/vault"
    makedirs(vault, exist_ok=True)
    _write(
        vault + "/a.csv",
        String("Transaction Date,Description,Type,Amount (USD)\n")
        + "01/15/2025,STARBUCKS STORE 04821 SEATTLE WA USA,Purchase,4.50\n"
        + "02/03/2026,ACH TRANSFER PAYROLL,Payment,-100.00\n",
    )
    _write(
        vault + "/b.csv",
        String("Transaction Date,Description,Type,Amount (USD)\n")
        + "03/20/2026,WHOLE FOODS MKT SEATTLE WA USA,Purchase,56.78\n"
        + "03/22/2026,SAFEWAY 3031 DALY CITY CA USA,Purchase,12.34\n",
    )
    _write(
        vault + "/notes.md",
        String("# Notes\n\nSome travel notes about coffee and rent.\n"),
    )

    # The tracked file set (sorted, kind-filtered) — the SAME order build_index
    # drives, so aliases (file_0..) line up between the two paths.
    var base = common_base([vault])
    var infos = manifest_for_files(collect_index_paths([vault]))
    var files = List[String]()
    for i in range(len(infos)):
        files.append(infos[i].path.copy())
    expect(len(files) == 3, "3 candidate files (a.csv, b.csv, notes.md)")

    # ── 1) PARITY: build_index vs per-file loop + finalize ──────────────────────
    _clear_index()
    build_index([vault], FAKE_URL)
    var man_a = _read(_manifest_path())
    var txn_a = _read(txns_path())
    var chk_a = _read(_sidetable_path())
    expect(man_a.byte_length() > 0, "build_index wrote a manifest")
    expect(txn_a.byte_length() > 0, "build_index wrote transactions")
    expect(chk_a.byte_length() > 0, "build_index wrote chunks")

    _clear_index()
    for i in range(len(files)):
        var res = index_one_file(files[i], base, FAKE_URL)
        expect(res.action == "embedded", "clean-run step embeds " + files[i])
    finalize_index(files, base, FAKE_URL)
    var man_b = _read(_manifest_path())
    var txn_b = _read(txns_path())
    var chk_b = _read(_sidetable_path())

    expect(
        man_a == man_b,
        "manifest.tsv byte-identical (same aliases / id ranges / next_gen)",
    )
    expect(
        txn_a == txn_b,
        "transactions.tsv byte-identical (same rows / gens / tags)",
    )
    expect(chk_a == chk_b, "chunks.tsv byte-identical (same chunk ids / text)")
    # The generation closed once (rows were added) → #meta next_gen advanced to 2.
    expect(
        man_b.find("\t2\n") != -1,
        "the run closed the generation (next_gen bumped to 2)",
    )

    # Prove the parity was over REAL content (transactions extracted from both CSVs).
    var rows_full = _load_txns()
    expect(len(rows_full) == 4, "4 transactions extracted across a.csv + b.csv")
    for i in range(len(rows_full)):
        expect(
            rows_full[i].added_gen == 1,
            "every fresh transaction carries the run's generation (1)",
        )

    # ── 2) PARTIAL: one index_one_file commits that file, others absent ─────────
    _clear_index()
    var one = index_one_file(files[0], base, FAKE_URL)  # a.csv → file_0
    expect(one.action == "embedded", "single step embeds a.csv")
    expect(one.falias == "file_0", "first file mints file_0")
    expect(one.chunk_count > 0, "a.csv produced chunks")

    var man_one = _read(_manifest_path())
    expect(man_one.find("\ta.csv\t") != -1, "manifest has the committed a.csv")
    expect(man_one.find("\tb.csv\t") == -1, "b.csv is NOT indexed yet")
    expect(man_one.find("\tnotes.md\t") == -1, "notes.md is NOT indexed yet")
    var rows_one = _load_txns()
    expect(_rows_for(rows_one, "file_0") == 2, "a.csv's 2 rows are committed")
    expect(len(rows_one) == 2, "no other file's rows are present")
    expect(
        _chunks_for("file_0") == one.chunk_count,
        "committed chunk count matches the manifest row",
    )
    # #meta next_id equals the one committed file's chunk count (ids [0, count)).
    expect(
        man_one.find(String("#meta\t") + String(one.chunk_count) + "\t1\t")
        != -1,
        (
            "the #meta counters advanced by exactly one file (next_id,"
            " next_alias=1)"
        ),
    )

    # ── 3) PRUNE: finalize over a reduced tracked set removes a file ────────────
    # Rebuild the full index, then re-run the (unchanged) survivors + finalize with
    # b.csv dropped from the tracked set — the removed-file path lives in finalize.
    _clear_index()
    for i in range(len(files)):
        _ = index_one_file(files[i], base, FAKE_URL)
    finalize_index(files, base, FAKE_URL)
    expect(_rows_for(_load_txns(), "file_1") == 2, "b.csv (file_1) rows exist")
    expect(_chunks_for("file_1") > 0, "b.csv (file_1) chunks exist")

    var survivors = [files[0], files[2]]  # a.csv, notes.md — b.csv removed
    for i in range(len(survivors)):
        var r = index_one_file(survivors[i], base, FAKE_URL)
        expect(
            r.action == "skipped", "unchanged survivor skips: " + survivors[i]
        )
    finalize_index(survivors, base, FAKE_URL)

    var man_pruned = _read(_manifest_path())
    expect(
        man_pruned.find("\tb.csv\t") == -1,
        "finalize pruned b.csv's manifest entry",
    )
    expect(man_pruned.find("\ta.csv\t") != -1, "a.csv survives the prune")
    expect(man_pruned.find("\tnotes.md\t") != -1, "notes.md survives the prune")
    expect(
        _rows_for(_load_txns(), "file_1") == 0,
        "finalize evicted b.csv's transactions",
    )
    expect(_chunks_for("file_1") == 0, "finalize dropped b.csv's chunks")
    expect(
        _rows_for(_load_txns(), "file_0") == 2,
        "a.csv's transactions are untouched by the prune",
    )

    print("ok: all index-steps parity/partial/prune tests passed")

"""Unit test for the DOC / whole-document storage seam (vault/storage — DocStore).

Build + run via pixi:  pixi run test-docstore
(hermetic: the task mkdir's a throwaway MILLFOLIO_DATA_DIR under /tmp and rm's it after,
so the `default_*_store()` factories resolve there — no real on-device docs are touched.)

Covers the contract the three whole-document rewrites (categories.txt / manifest.tsv /
indexed-paths.json) rely on:
  - load of a MISSING doc RAISES (mirrors the old inline `with open(path,"r")` — so each
    owner keeps its own exists()-guard / try/except)
  - save → load roundtrip: the document is stored + read back WHOLE, byte-for-byte
  - overwrite: last-write-wins (save truncates + replaces, no append)
  - mode: save uses a plain `"w"` open (owner-writable default umask — NOT tightened to
    0600 like the log/kv-secret files)
  - the per-doc factories resolve their dir from MILLFOLIO_DATA_DIR (the Phase-5 swap
    points), and dir+key is byte-identical to the owners' `<data-dir>/<basename>` paths
"""
from std.os import getenv
from std.ffi import external_call, c_int
from std.memory import alloc
from vault.storage import (
    FileDocStore,
    default_categories_store,
    default_manifest_store,
    default_indexed_paths_store,
    DOC_CATEGORIES,
    DOC_MANIFEST,
    DOC_INDEXED_PATHS,
)


def expect(cond: Bool, msg: String) -> Int:
    if cond:
        print("  ok  ", msg)
        return 0
    print("  FAIL", msg)
    return 1


def _mode_of(path: String) -> Int:
    """The st_mode permission bits of `path` via libc stat(2), or -1 on error. Uses the
    macOS `stat` layout (st_mode is a uint16 at byte offset 4 in `struct stat`).
    """
    var buf = alloc[UInt8](256)
    for i in range(256):
        buf[i] = 0
    var rc = external_call["stat", c_int](path.unsafe_ptr(), buf)
    var mode = -1
    if Int(rc) == 0:
        var lo = Int(buf[4])
        var hi = Int(buf[5])
        mode = ((hi << 8) | lo) & 0o777
    buf.free()
    return mode


def main() raises:
    var fails = 0
    # MILLFOLIO_DATA_DIR is set + mkdir'd by the pixi task; use it as the store dir so
    # this exercises the SAME dir the default_*_store() factories resolve.
    var dir = String(
        getenv("MILLFOLIO_DATA_DIR", "/tmp/millfolio-docstore-test")
    )
    var store = FileDocStore(dir)

    # ── load of a missing doc RAISES (mirrors the old `with open(...,"r")`) ───────
    var raised = False
    try:
        _ = store.load(DOC_CATEGORIES)
    except:
        raised = True
    fails += expect(
        raised, "load of a missing doc raises (owner keeps its exists-guard)"
    )

    # ── save → load roundtrip (stored WHOLE, byte-for-byte) ───────────────────────
    var registry = String(
        "# managed-checksum: abc123\nphone (mobile) = verizon, at&t\ntravel :"
        " is this a travel expense?\n"
    )
    store.save(DOC_CATEGORIES, registry)
    fails += expect(
        store.load(DOC_CATEGORIES) == registry,
        "save then load returns the exact document (categories.txt shape)",
    )

    # A TSV manifest (embedded tabs + newlines) round-trips unchanged.
    var manifest = String(
        "#meta\t7\t3\t/Users/x/Statements\t2\nfile_0\tq1.pdf\tpdf\t1024\tdead"
        "beef\t0\t5\n"
    )
    store.save(DOC_MANIFEST, manifest)
    fails += expect(
        store.load(DOC_MANIFEST) == manifest,
        "a TSV manifest (tabs + #meta header) round-trips whole",
    )

    # A JSON registry (the indexed-paths shape) round-trips unchanged.
    var tracked = String(
        '{"folders":[{"path":"/Users/x/Statements","lastIndexed":"1720000000"}]}'
    )
    store.save(DOC_INDEXED_PATHS, tracked)
    fails += expect(
        store.load(DOC_INDEXED_PATHS) == tracked,
        "a JSON indexed-paths doc round-trips whole",
    )

    # ── overwrite: last-write-wins (truncate + replace, NOT append) ───────────────
    var shorter = String("phone = verizon\n")
    store.save(DOC_CATEGORIES, shorter)
    fails += expect(
        store.load(DOC_CATEGORIES) == shorter,
        "save overwrites (truncates — last-write-wins, no append)",
    )

    # ── mode: plain "w" open → owner-writable, NOT forced to 0600 ─────────────────
    var mode = _mode_of(dir + "/" + DOC_CATEGORIES)
    fails += expect(
        (mode & 0o600) == 0o600,
        "saved doc is owner read+write (plain umask 'w' mode)",
    )

    # ── the per-doc factories resolve their dir from MILLFOLIO_DATA_DIR ────────────
    default_categories_store().save(DOC_CATEGORIES, "via-cat-default\n")
    fails += expect(
        default_categories_store().load(DOC_CATEGORIES) == "via-cat-default\n",
        "default_categories_store round-trips over the resolved dir",
    )
    fails += expect(
        store.load(DOC_CATEGORIES) == "via-cat-default\n",
        "  …the same file the explicit-dir store sees (dir matches config_dir)",
    )

    # indexed-paths factory is the SAME dir; manifest factory takes the dir explicitly.
    default_indexed_paths_store().save(DOC_INDEXED_PATHS, '{"folders":[]}')
    fails += expect(
        store.load(DOC_INDEXED_PATHS) == '{"folders":[]}',
        "default_indexed_paths_store writes the config-dir doc",
    )
    default_manifest_store(dir).save(DOC_MANIFEST, "#meta\t0\t0\t\t1\n")
    fails += expect(
        store.load(DOC_MANIFEST) == "#meta\t0\t0\t\t1\n",
        "default_manifest_store(dir) writes the dir-resolved doc",
    )

    print("")
    if fails == 0:
        print("PASS — all DocStore invariants hold")
    else:
        raise Error(String(fails) + " doc-store test failure(s)")

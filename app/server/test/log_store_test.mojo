"""Unit test for the append-log storage seam (src/storage.mojo — LogStore).

Build + run via pixi:  pixi run test-logstore
(uses throwaway /tmp files + a temp MILLFOLIO_OPS_FILE, so it's hermetic; the task
rm's the temp files first).

Covers the contract the three logs (operations/stats/asks) rely on:
  - append → read_all roundtrip: each record becomes one newline-terminated line
  - append ordering: records read back in the exact order they were appended
  - read_all on a MISSING file RAISES (so each caller keeps its try/except→empty)
  - torn/malformed line: read_all returns the RAW bytes; the pure builder
    (operations_records_array, unchanged in store.mojo) skips it — the split of
    responsibility the seam preserves, byte-identical to before
  - rewrite: whole-file overwrite (the asks delete-record compaction)
  - the default_*_store factory + its path helper honor the per-log env override
"""
from std.os import setenv
from vault.storage import (
    FileLogStore,
    default_operations_store,
    operations_log_path,
)
from store import operations_records_array


def expect(cond: Bool, msg: String) -> Int:
    if cond:
        print("  ok  ", msg)
        return 0
    print("  FAIL", msg)
    return 1


def main() raises:
    var fails = 0
    var path = String("/tmp/millfolio-logstore-test.jsonl")
    var store = FileLogStore(path)

    # ── read_all on a missing file RAISES (mirrors the old `with open(...,"r")`) ──
    # The pixi task rm's the file first, so this path does not exist yet.
    var raised = False
    try:
        _ = store.read_all()
    except:
        raised = True
    fails += expect(
        raised,
        "read_all on a missing file raises (caller keeps try/except→empty)",
    )

    # ── append → read_all roundtrip + ordering ──────────────────────────────────
    store.append('{"ts":1,"q":"a"}')
    store.append('{"ts":2,"q":"b"}')
    store.append('{"ts":3,"q":"c"}')
    var raw = store.read_all()
    fails += expect(
        raw == '{"ts":1,"q":"a"}\n{"ts":2,"q":"b"}\n{"ts":3,"q":"c"}\n',
        "append writes one JSONL line each; read_all returns them in order",
    )

    # ── torn/malformed line: store keeps raw bytes; the builder skips it ─────────
    with open(path, "a") as f:
        f.write('{"type":"index","star')  # crash mid-write: no close/newline
    var raw2 = store.read_all()
    fails += expect(
        raw2.endswith('{"type":"index","star'),
        "read_all returns raw bytes including a torn trailing write",
    )
    var arr = operations_records_array(raw2, 100)
    fails += expect(
        arr.find('"star') == -1,
        (
            "operations_records_array skips the torn line (seam preserves"
            " builder skip)"
        ),
    )
    fails += expect(
        arr.find('"ts":3') != -1,
        "  valid records survive alongside the skipped torn line",
    )

    # ── rewrite: whole-file overwrite (the asks delete compaction) ───────────────
    store.rewrite('{"ts":9,"q":"z"}\n')
    var raw3 = store.read_all()
    fails += expect(
        raw3 == '{"ts":9,"q":"z"}\n', "rewrite overwrites the whole file"
    )

    # ── factory + env override: default_operations_store honors MILLFOLIO_OPS_FILE ─
    var ops_override = String("/tmp/millfolio-logstore-test-ops.jsonl")
    _ = setenv("MILLFOLIO_OPS_FILE", ops_override, True)
    fails += expect(
        operations_log_path() == ops_override,
        "operations_log_path honors MILLFOLIO_OPS_FILE",
    )
    default_operations_store().append('{"type":"index","status":"done"}')
    fails += expect(
        default_operations_store().read_all()
        == '{"type":"index","status":"done"}\n',
        "default_operations_store round-trips over the env-resolved path",
    )
    _ = setenv("MILLFOLIO_OPS_FILE", "", True)  # reset

    print("")
    if fails == 0:
        print("PASS — all LogStore invariants hold")
    else:
        raise Error(String(fails) + " log-store test failure(s)")

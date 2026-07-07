"""Unit test for the KV / small-marker storage seam (src/storage.mojo — KvStore).

Build + run via pixi:  pixi run test-kvstore
(hermetic: the task mkdir's a throwaway MILLFOLIO_DATA_DIR under /tmp and rm's it after,
so `default_kv_store()` resolves there — no real on-device markers are touched.)

Covers the contract the ~dozen single-value markers (.index.state / .index.pid /
.index.op / .index.runtotal / .demo.state / .demo.op / .model_download.state /
.model_download.model) rely on:
  - get on a MISSING key RAISES (mirrors the old inline `with open(path,"r")` — so each
    caller keeps its own try/except → default)
  - set → get roundtrip: the value is stored + read back WHOLE, byte-for-byte
  - overwrite: last-write-wins (set replaces the prior value, no append)
  - exists: false before a set, true after, false again after delete
  - delete: removes the key (get raises again; delete of an absent key raises like
    os.remove — the pending-op finalize guards on exists() first)
  - default_kv_store() resolves its dir from MILLFOLIO_DATA_DIR (the Phase-5 swap point)
"""
from std.os import getenv
from storage import (
    FileKvStore,
    default_kv_store,
    KV_INDEX_STATE,
    KV_INDEX_RUNTOTAL,
    KV_DEMO_OP,
)


def expect(cond: Bool, msg: String) -> Int:
    if cond:
        print("  ok  ", msg)
        return 0
    print("  FAIL", msg)
    return 1


def main() raises:
    var fails = 0
    # MILLFOLIO_DATA_DIR is set + mkdir'd by the pixi task; use it as the store dir so
    # this exercises the SAME dir default_kv_store() resolves.
    var dir = String(
        getenv("MILLFOLIO_DATA_DIR", "/tmp/millfolio-kvstore-test")
    )
    var store = FileKvStore(dir)

    # ── get on a missing key RAISES (mirrors the old `with open(...,"r")`) ────────
    var raised = False
    try:
        _ = store.get(KV_INDEX_STATE)
    except:
        raised = True
    fails += expect(
        raised, "get on a missing key raises (caller keeps try/except→default)"
    )
    fails += expect(
        not store.exists(KV_INDEX_STATE), "exists is False before any set"
    )

    # ── set → get roundtrip (stored WHOLE, byte-for-byte) ────────────────────────
    store.set(KV_INDEX_STATE, "indexing")
    fails += expect(
        store.get(KV_INDEX_STATE) == "indexing",
        "set then get returns the exact value",
    )
    fails += expect(store.exists(KV_INDEX_STATE), "exists is True after a set")

    # A JSON-blob marker (the pending-op shape) round-trips unchanged too.
    var blob = String('{"type":"demo","started":1720000000}')
    store.set(KV_DEMO_OP, blob)
    fails += expect(
        store.get(KV_DEMO_OP) == blob,
        "a JSON pending-op blob round-trips whole",
    )

    # ── overwrite: last-write-wins (no append) ───────────────────────────────────
    store.set(KV_INDEX_STATE, "done")
    fails += expect(
        store.get(KV_INDEX_STATE) == "done", "set overwrites (last-write-wins)"
    )

    # A numeric marker (the runtotal shape) stores its digits verbatim.
    store.set(KV_INDEX_RUNTOTAL, "42")
    fails += expect(
        store.get(KV_INDEX_RUNTOTAL) == "42", "a numeric marker round-trips"
    )

    # ── delete: removes the key; get raises again; exists flips back to False ─────
    store.delete(KV_INDEX_STATE)
    fails += expect(
        not store.exists(KV_INDEX_STATE), "exists is False after delete"
    )
    var raised2 = False
    try:
        _ = store.get(KV_INDEX_STATE)
    except:
        raised2 = True
    fails += expect(raised2, "get on a deleted key raises again")

    # delete of an absent key raises (like os.remove — callers guard on exists first)
    var raised3 = False
    try:
        store.delete(KV_INDEX_STATE)
    except:
        raised3 = True
    fails += expect(raised3, "delete of an absent key raises (like os.remove)")

    # ── default_kv_store() resolves its dir from MILLFOLIO_DATA_DIR ───────────────
    default_kv_store().set(KV_DEMO_OP, "via-default")
    fails += expect(
        default_kv_store().get(KV_DEMO_OP) == "via-default",
        "default_kv_store round-trips over the MILLFOLIO_DATA_DIR-resolved dir",
    )
    fails += expect(
        store.get(KV_DEMO_OP) == "via-default",
        (
            "  …the same file the explicit-dir store sees (dir matches"
            " _config_dir)"
        ),
    )

    print("")
    if fails == 0:
        print("PASS — all KvStore invariants hold")
    else:
        raise Error(String(fails) + " kv-store test failure(s)")

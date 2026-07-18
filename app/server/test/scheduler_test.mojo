"""Unit test for the pure scheduler seams (src/scheduler.mojo).

Build + run via pixi:  pixi run test-scheduler

Covers the decision logic the scheduler loop relies on, hermetically (no queue
file, no engine, no disk):
  - index_run_plan: prepare → per-file index → finalize, correct payloads + prio
  - split_payload: round-trips the tab-joined payloads
  - index_active / index_pending_files / index_current: status from a queue snapshot
  - query_active: runqueue head≠tail gate
  - should_reconcile: only a provably-dead running item reconciles
  - parse_pending_total: reads the backfill readiness signal
"""
from scheduler import (
    EnqSpec,
    index_run_plan,
    split_payload,
    basename,
    short_payload,
    index_active,
    index_pending_files,
    index_current,
    query_active,
    should_reconcile,
    parse_pending_total,
    is_index_kind,
    KIND_PREPARE,
    KIND_INDEX,
    KIND_FINALIZE,
    KIND_BACKFILL,
    KIND_DEMO,
)
from work_queue import WorkItem, PRIO_INDEX, PRIO_FINALIZE, PRIO_BACKFILL


def expect(cond: Bool, msg: String) -> Int:
    if cond:
        print("  ok  ", msg)
        return 0
    print("  FAIL", msg)
    return 1


def _pending(kind: String, payload: String) -> WorkItem:
    return WorkItem(0, kind, payload, 0, PRIO_INDEX, "pending", 0, 0)


def _running(kind: String, payload: String, pid: Int) -> WorkItem:
    return WorkItem(0, kind, payload, 0, PRIO_INDEX, "running", pid, 0)


def main() raises:
    print("scheduler_test — pure scheduler seams")
    var fails = 0

    # ── index_run_plan ─────────────────────────────────────────────────────────
    var files = [String("/v/a.csv"), String("/v/b.pdf")]
    var plan = index_run_plan("/v", files)
    fails += expect(len(plan) == 4, "plan = prepare + 2 files + finalize")
    fails += expect(
        plan[0].kind == KIND_PREPARE and plan[0].payload == "/v",
        "plan[0] = prepare, payload=base",
    )
    fails += expect(
        plan[1].kind == KIND_INDEX and plan[1].payload == "/v\t/v/a.csv",
        "plan[1] = index a.csv (base\\tpath)",
    )
    fails += expect(
        plan[2].kind == KIND_INDEX and plan[2].payload == "/v\t/v/b.pdf",
        "plan[2] = index b.pdf",
    )
    fails += expect(
        plan[3].kind == KIND_FINALIZE
        and plan[3].payload == "/v\t/v/a.csv\t/v/b.pdf",
        "plan[3] = finalize with the whole file set",
    )
    fails += expect(
        plan[0].prio == PRIO_INDEX and plan[3].prio == PRIO_FINALIZE,
        "prios: index-family=10, finalize=10",
    )

    # empty file set → prepare + finalize(base only), still settles the run
    var empty = index_run_plan("/v", List[String]())
    fails += expect(
        len(empty) == 2
        and empty[0].kind == KIND_PREPARE
        and empty[1].kind == KIND_FINALIZE
        and empty[1].payload == "/v",
        "empty run → prepare + finalize(base)",
    )

    # ── split_payload round-trips ──────────────────────────────────────────────
    var f = split_payload(plan[3].payload)
    fails += expect(
        len(f) == 3
        and f[0] == "/v"
        and f[1] == "/v/a.csv"
        and f[2] == "/v/b.pdf",
        "split_payload(finalize) → [base, a, b]",
    )
    var one = split_payload(plan[0].payload)
    fails += expect(
        len(one) == 1 and one[0] == "/v", "split_payload(base) → [base]"
    )

    fails += expect(
        is_index_kind(KIND_PREPARE)
        and is_index_kind(KIND_INDEX)
        and is_index_kind(KIND_FINALIZE)
        and not is_index_kind(KIND_BACKFILL),
        "is_index_kind covers prepare/index/finalize, not backfill",
    )

    # ── status derived from a queue snapshot ───────────────────────────────────
    var q = List[WorkItem]()
    q.append(_running(KIND_INDEX, "/v\t/v/a.csv", 4242))  # file 1 running
    q.append(_pending(KIND_INDEX, "/v\t/v/b.pdf"))  # file 2 pending
    q.append(_pending(KIND_INDEX, "/v\t/v/c.pdf"))  # file 3 pending
    q.append(_pending(KIND_FINALIZE, "/v\t…"))
    fails += expect(index_active(q), "index_active true with items queued")
    fails += expect(
        index_pending_files(q) == 2,
        "2 files still pending (running one excluded)",
    )
    fails += expect(
        index_current(3, q) == 1, "current = 3 total − 2 pending = 1 (of 3)"
    )

    var backfill_only = List[WorkItem]()
    backfill_only.append(_pending(KIND_BACKFILL, "slice"))
    fails += expect(
        not index_active(backfill_only), "a backfill item is not an index run"
    )
    fails += expect(
        index_active(List[WorkItem]()) == False, "empty queue → not active"
    )
    fails += expect(
        index_current(3, List[WorkItem]()) == 3, "no pending → current=total"
    )

    # ── loop gating predicates ─────────────────────────────────────────────────
    fails += expect(query_active(0, 1), "tail>head → a query holds the engine")
    fails += expect(
        not query_active(5, 5), "head==tail → idle, run background work"
    )

    fails += expect(
        should_reconcile("running", False), "running + dead pid → reconcile"
    )
    fails += expect(
        not should_reconcile("running", True), "running + live pid → keep"
    )
    fails += expect(
        not should_reconcile("pending", False), "pending item never reconciled"
    )

    # ── backfill readiness signal ──────────────────────────────────────────────
    fails += expect(
        parse_pending_total('{"status":"idle","perTag":[],"pendingTotal":17}')
        == 17,
        "parse_pending_total reads 17",
    )
    fails += expect(
        parse_pending_total('{"pendingTotal":0}') == 0, "pendingTotal 0 → idle"
    )
    fails += expect(parse_pending_total('{"status":"idle"}') == 0, "absent → 0")

    # ── payload shortening (for /api/scheduler/queue) ───────────────────────
    fails += expect(basename("/v/sub/a.csv") == "a.csv", "basename strips dirs")
    fails += expect(basename("a.csv") == "a.csv", "basename no-slash → itself")
    fails += expect(
        short_payload(KIND_INDEX, "/v\t/v/sub/a.csv") == "a.csv",
        "index payload → file basename",
    )
    fails += expect(
        short_payload(KIND_FINALIZE, "/v\t/v/a.csv\t/v/b.pdf") == "2 files",
        "finalize payload → 'N files'",
    )
    fails += expect(
        short_payload(KIND_FINALIZE, "/v\t/v/a.csv") == "1 file",
        "finalize with one file → '1 file' (singular)",
    )
    fails += expect(
        short_payload(KIND_PREPARE, "/v/sub") == "sub",
        "prepare payload → base basename",
    )
    fails += expect(
        short_payload(KIND_BACKFILL, "groceries") == "groceries",
        "backfill payload passes through (already a short scope)",
    )
    # The sample-data import item renders as a fixed label (its payload is the demo
    # dir's absolute path — never leak it in the Operations queue view).
    fails += expect(
        short_payload(KIND_DEMO, "/Users/x/Library/.../demo-vault")
        == "sample data",
        "demo-download payload → 'sample data' (no path leak)",
    )
    fails += expect(
        not is_index_kind(KIND_DEMO),
        "demo-download is not an index kind",
    )

    if fails == 0:
        print("scheduler_test: ALL PASS")
    else:
        print("scheduler_test:", fails, "FAILURE(S)")
        raise Error("scheduler_test failed")

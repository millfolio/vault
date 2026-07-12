"""Unit test for the disk-backed work queue (src/work_queue.mojo).

Build + run via pixi:  pixi run test-workqueue
(the task points MILLFOLIO_WORKQ_PATH at a throwaway temp file).

Covers the invariants the orchestrator will rely on:
  - enqueue assigns increasing ids; wq_list returns them
  - priority + FIFO: peek returns lowest prio, ties by enq_at then id
  - dedup: an identical (kind, payload) that's pending/running coalesces
  - lifecycle: take → running (peek skips it) → done removes; fail removes
  - persistence: state + ids survive a fresh load; the id counter keeps climbing
  - corrupt: a garbage line is skipped, valid items still load
"""
from work_queue import (
    WorkItem,
    wq_reset,
    wq_enqueue,
    wq_peek,
    wq_take,
    wq_done,
    wq_fail,
    wq_list,
    wq_running,
    work_queue_path,
    PRIO_INDEX,
    PRIO_FINALIZE,
    PRIO_BACKFILL,
)


def expect(cond: Bool, msg: String) -> Int:
    if cond:
        print("  ok  ", msg)
        return 0
    print("  FAIL", msg)
    return 1


def main() raises:
    print("work_queue_test — state file:", work_queue_path())
    var fails = 0

    # ── enqueue assigns increasing ids; wq_list returns them ───────────────────
    wq_reset()
    var e1 = wq_enqueue("index", "a.csv", 100, PRIO_INDEX)
    var e2 = wq_enqueue("index", "b.csv", 101, PRIO_INDEX)
    var e3 = wq_enqueue("backfill", "rule1", 102, PRIO_BACKFILL)
    fails += expect(e1 == 1, "first enqueue → id 1")
    fails += expect(e2 == 2, "second enqueue → id 2")
    fails += expect(e3 == 3, "third enqueue → id 3")
    fails += expect(len(wq_list()) == 3, "wq_list has 3 items")

    # ── priority + FIFO order ──────────────────────────────────────────────────
    # prio 10 beats 20; within prio 10, earlier enq_at wins; equal enq_at → lower id
    wq_reset()
    var p_bf = wq_enqueue("backfill", "r", 50, PRIO_BACKFILL)  # id1 prio20
    var p_ix = wq_enqueue("index", "x", 60, PRIO_INDEX)  # id2 prio10 enq60
    var p_fin = wq_enqueue(
        "finalize", "run", 55, PRIO_FINALIZE
    )  # id3 prio10 enq55
    var top = wq_peek()
    fails += expect(top.__bool__(), "peek returns an item")
    fails += expect(
        top.value().id == p_fin,
        "peek → finalize (prio10, enq55 earliest) over index/backfill",
    )
    # add an even-earlier prio-10 item → it becomes the head
    var p_early = wq_enqueue("index", "p", 40, PRIO_INDEX)  # id4 prio10 enq40
    fails += expect(
        wq_peek().value().id == p_early, "earlier enq_at preempts as new head"
    )
    # list is fully ordered: prio then enq_at then id
    var ordered = wq_list()
    fails += expect(ordered[0].id == p_early, "list[0] = enq40 index")
    fails += expect(ordered[1].id == p_fin, "list[1] = enq55 finalize")
    fails += expect(ordered[2].id == p_ix, "list[2] = enq60 index")
    fails += expect(ordered[3].id == p_bf, "list[3] = backfill (prio20 last)")

    # tie-break by id when prio AND enq_at are equal
    wq_reset()
    var t_a = wq_enqueue("index", "one", 70, PRIO_INDEX)  # id1
    var t_b = wq_enqueue("index", "two", 70, PRIO_INDEX)  # id2 same prio+enq
    fails += expect(
        wq_peek().value().id == t_a, "equal prio+enq_at → lower id wins (FIFO)"
    )

    # ── dedup ──────────────────────────────────────────────────────────────────
    wq_reset()
    var d1 = wq_enqueue("index", "file", 10, PRIO_INDEX)
    var d2 = wq_enqueue("index", "file", 99, PRIO_INDEX)  # identical → coalesce
    fails += expect(d2 == d1, "dup (kind,payload) returns existing id")
    fails += expect(len(wq_list()) == 1, "dup did not grow the queue")
    var d3 = wq_enqueue("index", "other", 10, PRIO_INDEX)  # different payload
    fails += expect(d3 != d1, "different payload → new id")
    fails += expect(len(wq_list()) == 2, "different payload grows the queue")
    # dedup also holds against a RUNNING item
    _ = wq_take(d1, 1234, 500)
    var d4 = wq_enqueue("index", "file", 11, PRIO_INDEX)
    fails += expect(d4 == d1, "dup vs a RUNNING item coalesces too")
    fails += expect(
        len(wq_list()) == 2, "dup-vs-running did not grow the queue"
    )

    # ── lifecycle: take → running → done/fail ──────────────────────────────────
    wq_reset()
    var l1 = wq_enqueue("index", "f1", 10, PRIO_INDEX)
    var l2 = wq_enqueue("backfill", "r", 11, PRIO_BACKFILL)
    fails += expect(wq_take(l1, 4321, 999), "take(l1) → True")
    var run = wq_running()
    fails += expect(run.__bool__(), "wq_running returns the running item")
    fails += expect(run.value().id == l1, "  running id == l1")
    fails += expect(run.value().pid == 4321, "  running pid recorded")
    fails += expect(
        run.value().started_ts == 999, "  running started_ts recorded"
    )
    fails += expect(run.value().state == "running", "  state == running")
    fails += expect(
        wq_peek().value().id == l2, "peek SKIPS the running item → l2"
    )
    fails += expect(not wq_take(l1, 1, 1), "take on a running item → False")
    fails += expect(not wq_take(9999, 1, 1), "take on a missing id → False")
    fails += expect(wq_done(l1), "done(l1) → True (existed)")
    fails += expect(not wq_running().__bool__(), "no running item after done")
    fails += expect(wq_fail(l2, "boom"), "fail(l2) → True (removed)")
    fails += expect(len(wq_list()) == 0, "queue empty after done + fail")
    fails += expect(not wq_done(123), "done on a missing id → False")

    # ── persistence: state + ids survive a reload; counter keeps climbing ───────
    # Every wq_* call reloads from disk, so reading back IS a fresh-from-disk load.
    wq_reset()
    var s1 = wq_enqueue("index", "aa", 10, PRIO_INDEX)  # id1
    var s2 = wq_enqueue("index", "bb", 11, PRIO_INDEX)  # id2
    var reloaded = wq_list()
    fails += expect(len(reloaded) == 2, "2 items survive a fresh load")
    fails += expect(
        reloaded[0].id == s1 and reloaded[1].id == s2, "  ids survive"
    )
    fails += expect(reloaded[0].payload == "aa", "  payload survives")
    var s3 = wq_enqueue("index", "cc", 12, PRIO_INDEX)
    fails += expect(s3 == s2 + 1, "counter increments across reloads")
    # drain everything → the header keeps next_id, so ids stay monotonic (no reuse)
    _ = wq_done(s1)
    _ = wq_done(s2)
    _ = wq_done(s3)
    fails += expect(len(wq_list()) == 0, "queue drained")
    var s4 = wq_enqueue("index", "dd", 13, PRIO_INDEX)
    fails += expect(s4 == s3 + 1, "id counter monotonic even after full drain")

    # ── corrupt line is skipped, valid items still load ────────────────────────
    wq_reset()
    var c1 = wq_enqueue("index", "valid1", 10, PRIO_INDEX)
    var c2 = wq_enqueue("index", "valid2", 11, PRIO_INDEX)
    with open(work_queue_path(), "a") as f:
        f.write("this-is-garbage-not-a-record\n")  # 1 field → skipped
        f.write("also\tbad\tline\n")  # 3 fields → skipped
        f.write(
            "xx\ta\tb\tc\td\te\tf\tg\n"
        )  # 8 fields but non-numeric → skipped
    var survivors = wq_list()
    fails += expect(
        len(survivors) == 2, "garbage lines skipped, 2 valid items load"
    )
    var have1 = False
    var have2 = False
    for i in range(len(survivors)):
        if survivors[i].payload == "valid1":
            have1 = True
        if survivors[i].payload == "valid2":
            have2 = True
    fails += expect(
        have1 and have2, "both valid payloads intact after corrupt lines"
    )
    _ = c1
    _ = c2

    print("")
    if fails == 0:
        print("PASS — all work-queue invariants hold")
    else:
        raise Error(String(fails) + " work-queue test failure(s)")

"""Unit test for the serial run-queue state file (src/runqueue.mojo).

Build + run via pixi:  pixi run test-runqueue
(the task points MILLFOLIO_RUNQ_PATH at a throwaway temp file).

Checks the FIFO ticket invariants the multi-worker app server relies on:
  - take() hands out monotonically increasing tickets and bumps `tail`
  - done(my) advances `head` to my+1 (and never backwards)
  - a waiter with ticket T runs once head == T; position = T - head + 1
  - reset() zeroes the queue
"""
from runqueue import (
    runq_reset, runq_take, runq_peek, runq_done, runq_read, runq_path,
)


def expect(cond: Bool, msg: String) -> Int:
    if cond:
        print("  ok  ", msg)
        return 0
    print("  FAIL", msg)
    return 1


def main() raises:
    print("runqueue_test — state file:", runq_path())
    var fails = 0

    # reset → empty queue
    runq_reset()
    var ht = runq_read()
    fails += expect(ht[0] == 0 and ht[1] == 0, "reset → head=0 tail=0")

    # three tickets handed out in order; tail tracks the count
    var t0 = runq_take()
    fails += expect(t0 == 0, "take #1 → ticket 0")
    fails += expect(runq_read()[1] == 1, "  tail == 1 after take")
    var t1 = runq_take()
    fails += expect(t1 == 1, "take #2 → ticket 1")
    var t2 = runq_take()
    fails += expect(t2 == 2, "take #3 → ticket 2")
    var st = runq_peek()
    fails += expect(st[0] == 0 and st[1] == 3, "peek → head=0 tail=3 (3 queued, ticket 0 running)")

    # position of each ticket = ticket - head + 1
    fails += expect((t0 - st[0] + 1) == 1, "ticket 0 is position 1 (its turn)")
    fails += expect((t2 - st[0] + 1) == 3, "ticket 2 is position 3")

    # done() advances head one ticket at a time, in order
    runq_done(t0)
    fails += expect(runq_peek()[0] == 1, "done(0) → head advances to 1")
    runq_done(t1)
    fails += expect(runq_peek()[0] == 2, "done(1) → head advances to 2")
    runq_done(t2)
    var fin = runq_peek()
    fails += expect(fin[0] == 3 and fin[1] == 3, "done(2) → head==tail==3 (queue drained)")

    # done() never moves head backwards (a stale/duplicate done is a no-op)
    runq_done(0)
    fails += expect(runq_peek()[0] == 3, "stale done(0) does not rewind head")

    # reset() clears it again
    runq_reset()
    fails += expect(runq_read()[1] == 0, "reset → tail back to 0")
    # next ticket after reset is 0 again
    fails += expect(runq_take() == 0, "take after reset → ticket 0")

    print("")
    if fails == 0:
        print("PASS — all run-queue invariants hold")
    else:
        raise Error(String(fails) + " run-queue test failure(s)")

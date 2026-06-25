"""Serial run-queue state — a per-port FIFO ticket counter, so the multi-worker app
server runs at most one sandboxed program at a time and each waiter can show its
position. State lives in `/tmp/millfolio-runq-<MILLFOLIO_PORT>` as two ints `head tail`:

  - `tail` is the next ticket to hand out; `runq_take()` returns it and bumps tail.
  - `head` is the ticket currently allowed to run; `runq_done(my)` advances it past `my`.
  - a waiter with ticket T runs once `head == T`; its position is `T - head + 1`.

Mutual exclusion is an `flock(LOCK_EX)` on a sibling `.lock` file (raw libc); the state
itself is read/written by PATH with Mojo file I/O (libc pread/pwrite did not persist
reliably here). Unit-tested by `test/runqueue_test.mojo`.
"""
from std.ffi import external_call, c_char
from std.memory import alloc
from std.os import getenv
from flare.prelude import *  # MutUntrackedOrigin

comptime _O_RDWR: Int = 0x0002
comptime _O_CREAT: Int = 0x0200
comptime _LOCK_EX: Int = 0x0002
comptime _LOCK_UN: Int = 0x0008


def runq_path() -> String:
    """The per-port state file. MILLFOLIO_RUNQ_PATH overrides it (tests use that)."""
    var override = String(getenv("MILLFOLIO_RUNQ_PATH", ""))
    if len(override) > 0:
        return override
    return String("/tmp/millfolio-runq-") + String(getenv("MILLFOLIO_PORT", "0"))


def _cstr(s: String) -> UnsafePointer[c_char, MutUntrackedOrigin]:
    var n = s.byte_length()
    var p = alloc[c_char](n + 1)
    var sp = s.unsafe_ptr()
    for i in range(n):
        (p + i).init_pointee_copy(c_char(Int(sp[i])))
    (p + n).init_pointee_copy(c_char(0))
    return p


def _lock() -> Int32:
    var cpath = _cstr(runq_path() + ".lock")
    var fd = external_call["open", Int32](cpath, Int32(_O_RDWR | _O_CREAT), Int32(0o600))
    cpath.free()
    if fd >= Int32(0):
        _ = external_call["flock", Int32](fd, Int32(_LOCK_EX))
    return fd


def _unlock(fd: Int32):
    if fd >= Int32(0):
        _ = external_call["flock", Int32](fd, Int32(_LOCK_UN))
        _ = external_call["close", Int32](fd)


def runq_read() -> Tuple[Int, Int]:
    """(head, tail) from the state file; (0, 0) if missing/empty/garbage."""
    var vals = List[Int]()
    try:
        var s: String
        with open(runq_path(), "r") as f:
            s = f.read()
        var cur = 0
        var indig = False
        var b = s.as_bytes()
        for i in range(len(b)):
            var c = Int(b[i])
            if c >= 48 and c <= 57:
                cur = cur * 10 + (c - 48); indig = True
            elif indig:
                vals.append(cur); cur = 0; indig = False
        if indig:
            vals.append(cur)
    except:
        pass
    var head = vals[0] if len(vals) >= 1 else 0
    var tail = vals[1] if len(vals) >= 2 else 0
    return (head, tail)


def runq_write(head: Int, tail: Int):
    try:
        with open(runq_path(), "w") as f:
            f.write(String(head) + " " + String(tail) + "\n")
    except:
        pass


def runq_take() -> Int:
    """Enter the queue: atomically grab the next ticket and return it."""
    var lk = _lock()
    var ht = runq_read()
    var my = ht[1]
    runq_write(ht[0], ht[1] + 1)
    _unlock(lk)
    return my


def runq_peek() -> Tuple[Int, Int]:
    """(head, tail) snapshot — head = ticket now running, tail = next to hand out."""
    var lk = _lock()
    var ht = runq_read()
    _unlock(lk)
    return ht


def runq_done(my: Int):
    """Leave the run slot: advance head past our ticket so the next waiter proceeds."""
    var lk = _lock()
    var ht = runq_read()
    var nh = ht[0]
    if my + 1 > nh:
        nh = my + 1
    runq_write(nh, ht[1])
    _unlock(lk)


def runq_reset():
    """Reset to (0, 0) — at startup, so stale head/tail from a prior process don't stall."""
    var lk = _lock()
    runq_write(0, 0)
    _unlock(lk)

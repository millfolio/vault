"""Ledger — the ML-materialization completion marker (pure, LanceDB-free).

An ML category rule (`<tag> : <question>`) costs a model call per transaction, so
its verdicts are materialized once and cached in the `.tags` column. This module
holds the tiny durable bookkeeping that says HOW FAR each rule got, so a pass is
incremental, resumable, and never re-does a true negative.

Coverage is keyed on a monotonic **insertion generation** (`added_gen`), NOT the
transaction's date: every transaction gets an `added_gen` at index time from a
persisted counter, so a back-dated statement indexed late still gets a HIGH gen →
correctly pending. Per rule we keep ONE marker `(rule, qhash, done_gen)`: rule R
is materialized for every row with `added_gen <= done_gen` at question-hash
`qhash`; the pending set is `{ rows : added_gen > done_gen }`. Negatives are
implicit (the marker covers the whole in-range span; positives live in `.tags`),
so the mostly-negative case costs O(1) per rule.

This file is deliberately PURE — parse/serialize + the coverage predicates, no
file I/O, no engine, no FFI — so the hermetic test suite exercises it directly
(`pixi run test-ledger`). The worker that reads/writes `ml_ledger.tsv` under the
run-queue `flock` lives elsewhere (see `QUERY_FLOW.md` → ML materialization).
"""

from vault.index.sha256 import sha256_hex


# ── constants ─────────────────────────────────────────────────────────────────

comptime LEDGER_HEADER = "# ml_ledger v1"
comptime QHASH_LEN = 8  # hex chars of the question digest kept in the marker
comptime GEN_ABSENT = -1  # a rule with no marker → done_gen treated as -1


# ── the question hash ─────────────────────────────────────────────────────────


def qhash(prompt: String) -> String:
    """A short, stable hash of an ML rule's question — the first `QHASH_LEN` hex
    chars of its SHA-256. Editing the question changes `qhash`, so the old marker
    stops matching → that rule (only) re-materializes from scratch."""
    var b = List[UInt8]()
    var p = prompt.unsafe_ptr()
    for i in range(prompt.byte_length()):
        b.append(p[i])
    var hex = sha256_hex(b)
    var out = String("")
    var n = QHASH_LEN if QHASH_LEN <= hex.byte_length() else hex.byte_length()
    for i in range(n):
        out += String(hex[byte=i])
    return out^


# ── the marker ────────────────────────────────────────────────────────────────


@fieldwise_init
struct RuleMarker(Copyable, Movable):
    """One durable line: rule R is materialized for every transaction with
    `added_gen <= done_gen`, evaluated at question-hash `qhash`. If `qhash` no
    longer matches the rule's current question the marker is stale (the whole
    rule re-queues)."""

    var rule: String
    var qhash: String
    var done_gen: Int


# ── coverage predicates (the pure core the worker + readiness gate call) ──────


def is_pending(
    added_gen: Int, marker_qhash: String, done_gen: Int, cur_qhash: String
) -> Bool:
    """Does the transaction at `added_gen` still need classifying for a rule whose
    marker is `(marker_qhash, done_gen)` and whose current question hashes to
    `cur_qhash`? A `qhash` mismatch (edited question, or absent marker) means the
    whole rule is pending; otherwise a row is pending iff it was inserted after
    the marker (`added_gen > done_gen`)."""
    if marker_qhash != cur_qhash:
        return True
    return added_gen > done_gen


def is_ready(
    marker_qhash: String, done_gen: Int, cur_qhash: String, max_added_gen: Int
) -> Bool:
    """Is a rule fully materialized — safe to advertise to codegen as a fast exact
    `.tags` filter rather than classified inline? True iff the marker matches the
    current question AND covers the highest inserted generation. An empty vault
    (`max_added_gen == GEN_ABSENT`) is trivially ready."""
    if marker_qhash != cur_qhash:
        return False
    return done_gen >= max_added_gen


def count_pending(
    added_gens: List[Int],
    marker_qhash: String,
    done_gen: Int,
    cur_qhash: String,
) -> Int:
    """How many of `added_gens` (the insertion gens of the stored transactions)
    are still pending for this rule — the per-tag "N left" the UI shows."""
    var n = 0
    for i in range(len(added_gens)):
        if is_pending(added_gens[i], marker_qhash, done_gen, cur_qhash):
            n += 1
    return n


# ── parse / serialize (skip-malformed; the file is a rebuildable cache) ───────


def _parse_int(s: String) -> Tuple[Int, Bool]:
    """Parse a (possibly negative) base-10 integer. Returns `(value, ok)`; `ok`
    is False for empty or non-numeric input so the caller can skip the line."""
    var t = String(s.strip())
    if t.byte_length() == 0:
        return (0, False)
    var p = t.unsafe_ptr()
    var i = 0
    var neg = False
    if Int(p[0]) == 45:  # '-'
        neg = True
        i = 1
        if t.byte_length() == 1:
            return (0, False)
    var v = 0
    while i < t.byte_length():
        var c = Int(p[i])
        if c < 48 or c > 57:
            return (0, False)
        v = v * 10 + (c - 48)
        i += 1
    return (-v if neg else v, True)


def parse_ledger(text: String) raises -> List[RuleMarker]:
    """Parse `ml_ledger.tsv` into markers. The first non-blank line must be the
    exact `LEDGER_HEADER` (version tag) — any other header means a format we don't
    understand, so we DISCARD everything and return empty (rebuild-from-scratch,
    which is always safe: the ledger is a cache). Data lines are
    `rule <TAB> qhash <TAB> done_gen`; blank lines, `#` comments, and any
    unparseable line are skipped (a truncated tail from a crashed append just
    re-queues those rows)."""
    var out = List[RuleMarker]()
    var lines = text.split("\n")
    var seen_header = False
    for i in range(len(lines)):
        var line = String(lines[i])
        var stripped = String(line.strip())
        if stripped.byte_length() == 0:
            continue
        if not seen_header:
            # The first non-blank line decides the format.
            if stripped != LEDGER_HEADER:
                return List[RuleMarker]()
            seen_header = True
            continue
        if stripped.startswith("#"):
            continue
        var cols = line.split("\t")
        if len(cols) < 3:
            continue
        var rule = String(cols[0].strip())
        var qh = String(cols[1].strip())
        if rule.byte_length() == 0 or qh.byte_length() == 0:
            continue
        var parsed = _parse_int(String(cols[2]))
        if not parsed[1]:
            continue
        out.append(RuleMarker(rule^, qh^, parsed[0]))
    return out^


def serialize_ledger(markers: List[RuleMarker]) -> String:
    """Render markers back to the versioned TSV, header first. Rule names may
    contain spaces but never a tab (the categorize parser forbids it), so no
    escaping is needed — one `rule <TAB> qhash <TAB> done_gen` line each."""
    var out = String(LEDGER_HEADER) + "\n"
    for i in range(len(markers)):
        ref m = markers[i]
        out += m.rule + "\t" + m.qhash + "\t" + String(m.done_gen) + "\n"
    return out^


# ── marker lookup / upsert (small helpers over the marker list) ───────────────


def find_marker(markers: List[RuleMarker], rule: String) -> Int:
    """Index of the marker for `rule`, or -1 if the rule has none yet."""
    for i in range(len(markers)):
        if markers[i].rule == rule:
            return i
    return -1


def marker_done_gen(
    markers: List[RuleMarker], rule: String, cur_qhash: String
) -> Int:
    """The effective `done_gen` for `rule` at the current question hash: the
    stored value when the marker matches `cur_qhash`, else `GEN_ABSENT` (a missing
    OR stale marker means nothing is materialized → the whole rule is pending).
    """
    var idx = find_marker(markers, rule)
    if idx < 0:
        return GEN_ABSENT
    if markers[idx].qhash != cur_qhash:
        return GEN_ABSENT
    return markers[idx].done_gen


def upsert_marker(
    mut markers: List[RuleMarker],
    rule: String,
    cur_qhash: String,
    done_gen: Int,
):
    """Record that `rule` is materialized through `done_gen` at `cur_qhash`. If a
    marker exists it's overwritten (a re-hash from an edited question resets its
    generation); otherwise a new line is appended."""
    var idx = find_marker(markers, rule)
    if idx < 0:
        markers.append(RuleMarker(rule, cur_qhash, done_gen))
        return
    var m = markers[idx].copy()
    m.qhash = cur_qhash
    m.done_gen = done_gen
    markers[idx] = m^


def drop_marker(mut markers: List[RuleMarker], rule: String):
    """Remove `rule`'s marker (tag cancel / delete) — its rows re-queue if the
    rule ever returns. No-op when absent."""
    var idx = find_marker(markers, rule)
    if idx < 0:
        return
    var out = List[RuleMarker]()
    for i in range(len(markers)):
        if i != idx:
            out.append(markers[i].copy())
    markers = out^

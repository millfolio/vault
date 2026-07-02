"""Ledger_test — the ML-backfill completion marker (pure).

Builds + runs as a plain Mojo program with only `-I core/src` (no FFI/network):
`pixi run test-ledger`. Pins the marker contract: the insertion-generation
coverage predicates (`is_pending`/`is_ready`/`count_pending`), the `qhash`
question hash (stable + edit-sensitive), the versioned TSV parse/serialize
(skip-malformed, wrong-header→discard), and the marker upsert/drop helpers —
including the migration case (absent marker → everything pending, once).
"""

from vault.derive.ledger import (
    RuleMarker,
    qhash,
    is_pending,
    is_ready,
    count_pending,
    parse_ledger,
    serialize_ledger,
    find_marker,
    marker_done_gen,
    upsert_marker,
    drop_marker,
    LEDGER_HEADER,
    QHASH_LEN,
    GEN_ABSENT,
)


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def main() raises:
    # ── qhash: stable, right length, edit-sensitive ─────────────────────────────
    var q = qhash("is this a gym?")
    expect(q.byte_length() == QHASH_LEN, "qhash is QHASH_LEN hex chars")
    expect(qhash("is this a gym?") == q, "qhash is deterministic")
    expect(
        qhash("is this a gym membership?") != q,
        "editing the question changes qhash",
    )
    # Hex-only (lowercase 0-9a-f).
    for i in range(q.byte_length()):
        var c = Int(q.unsafe_ptr()[i])
        expect(
            (c >= 48 and c <= 57) or (c >= 97 and c <= 102),
            "qhash is lowercase hex",
        )

    # ── is_pending: qhash match + generation boundary ───────────────────────────
    var cur = q  # current question hash for the "gym" rule
    # Marker matches, done_gen = 10 → rows at gen <= 10 done, > 10 pending.
    expect(not is_pending(10, cur, 10, cur), "gen == done_gen → backfilled")
    expect(not is_pending(5, cur, 10, cur), "gen < done_gen → backfilled")
    expect(is_pending(11, cur, 10, cur), "gen > done_gen → pending")
    # Stale/absent marker (qhash mismatch) → everything pending regardless of gen.
    expect(
        is_pending(0, "stale", 999, cur),
        "qhash mismatch → pending even for an old low-gen row",
    )
    # Migration: absent marker modeled as done_gen = GEN_ABSENT(-1) → gen 0 pending.
    expect(
        is_pending(0, cur, GEN_ABSENT, cur),
        "GEN_ABSENT marker → gen-0 row pending (first run backfills all)",
    )

    # ── is_ready: covers the max inserted generation, matching qhash ────────────
    expect(is_ready(cur, 42, cur, 42), "done_gen == max → ready")
    expect(is_ready(cur, 43, cur, 42), "done_gen > max → ready")
    expect(not is_ready(cur, 41, cur, 42), "done_gen < max → not ready")
    expect(not is_ready("stale", 999, cur, 42), "qhash mismatch → not ready")
    expect(
        is_ready(cur, GEN_ABSENT, cur, GEN_ABSENT),
        "empty vault (no rows) → trivially ready",
    )

    # ── count_pending over a set of insertion gens ──────────────────────────────
    var gens = [0, 1, 2, 3, 4, 5]
    expect(
        count_pending(gens, cur, 2, cur) == 3,
        "gens 3,4,5 pending past done_gen=2",
    )
    expect(
        count_pending(gens, cur, 5, cur) == 0, "done_gen=5 covers all six rows"
    )
    expect(
        count_pending(gens, "stale", 5, cur) == 6,
        "stale qhash → every row pending",
    )
    expect(
        count_pending(gens, cur, GEN_ABSENT, cur) == 6,
        "absent marker → every row pending (migration)",
    )

    # ── parse / serialize round-trip ────────────────────────────────────────────
    var markers = [
        RuleMarker("gym", "9f3a1b2c", 412),
        RuleMarker("café", "1b7e0011", 412),
    ]
    var text = serialize_ledger(markers)
    expect(text.startswith(LEDGER_HEADER + "\n"), "serialize writes the header")
    var back = parse_ledger(text)
    expect(len(back) == 2, "round-trip preserves both markers")
    expect(back[0].rule == "gym" and back[0].done_gen == 412, "gym round-trips")
    expect(
        back[1].rule == "café" and back[1].qhash == "1b7e0011",
        "unicode rule name round-trips",
    )

    # ── wrong / missing header → discard (rebuildable cache) ─────────────────────
    expect(
        len(parse_ledger("# ml_ledger v2\ngym\t9f3a1b2c\t1\n")) == 0,
        "unknown version header → discard everything",
    )
    expect(len(parse_ledger("")) == 0, "empty file → no markers")
    expect(
        len(parse_ledger("gym\t9f3a1b2c\t1\n")) == 0,
        (
            "data with no header → discard (first non-blank line must be the"
            " header)"
        ),
    )

    # ── skip-malformed data lines (crashed-append tail, junk) ───────────────────
    var messy = String(LEDGER_HEADER) + "\n"
    messy += "# a comment inside\n"
    messy += "gym\t9f3a1b2c\t100\n"  # good
    messy += "twocols\tonly\n"  # too few columns → skip
    messy += "badgen\tabcd1234\tnotanint\n"  # non-numeric gen → skip
    messy += "\t\t5\n"  # empty rule/qhash → skip
    messy += "\n"  # blank → skip
    messy += "travel\tdeadbeef\t-1\n"  # good, negative gen (GEN_ABSENT)
    var parsed = parse_ledger(messy)
    expect(len(parsed) == 2, "only the two well-formed data lines survive")
    expect(parsed[0].rule == "gym" and parsed[0].done_gen == 100, "gym kept")
    expect(
        parsed[1].rule == "travel" and parsed[1].done_gen == -1,
        "negative done_gen parses",
    )

    # ── find_marker / marker_done_gen ───────────────────────────────────────────
    expect(find_marker(markers, "gym") == 0, "find_marker locates gym")
    expect(find_marker(markers, "nope") == -1, "find_marker misses → -1")
    expect(
        marker_done_gen(markers, "gym", "9f3a1b2c") == 412,
        "marker_done_gen at matching qhash → stored gen",
    )
    expect(
        marker_done_gen(markers, "gym", "different") == GEN_ABSENT,
        "marker_done_gen with mismatched qhash → GEN_ABSENT (rule re-queues)",
    )
    expect(
        marker_done_gen(markers, "absent", "9f3a1b2c") == GEN_ABSENT,
        "marker_done_gen for an unmarked rule → GEN_ABSENT",
    )

    # ── upsert_marker: insert, then overwrite (edited question resets gen) ───────
    var m2 = [RuleMarker("gym", "9f3a1b2c", 100)]
    upsert_marker(m2, "travel", "cafef00d", 50)
    expect(len(m2) == 2 and m2[1].rule == "travel", "upsert appends a new rule")
    upsert_marker(m2, "gym", "9f3a1b2c", 250)  # same qhash, advance
    expect(
        m2[0].done_gen == 250, "upsert advances done_gen on the existing marker"
    )
    upsert_marker(m2, "gym", "newhash0", 0)  # question edited → reset
    expect(
        m2[0].qhash == "newhash0" and m2[0].done_gen == 0,
        "upsert with a new qhash resets the rule's generation",
    )
    expect(len(m2) == 2, "upsert never duplicates a rule")

    # ── drop_marker: tag cancel ─────────────────────────────────────────────────
    drop_marker(m2, "gym")
    expect(
        len(m2) == 1 and m2[0].rule == "travel", "drop_marker removes just gym"
    )
    drop_marker(m2, "ghost")
    expect(len(m2) == 1, "drop_marker on an absent rule is a no-op")

    print("ledger_test: all assertions passed")

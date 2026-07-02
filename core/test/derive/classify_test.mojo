"""Classify_test — the EXACT-dedup mapping for ML backfill (pure).

Builds + runs with only `-I core/src` (no FFI/engine): `pixi run test-classify`.
Pins `dedup_descs`: distinct descriptions in first-seen order + a per-row index
into that distinct list, so the backfill can classify each unique merchant string
once and fan the verdict back to every row that shares it (recurring charges).
"""

from vault.derive.classify import dedup_descs, DedupMap, normalize_desc


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def main() raises:
    # ── empty input ────────────────────────────────────────────────────────────
    var m0 = dedup_descs(List[String]())
    expect(len(m0.unique) == 0, "empty → no unique")
    expect(len(m0.per_row) == 0, "empty → no per_row")

    # ── all distinct → 1:1, no collapse ─────────────────────────────────────────
    var distinct: List[String] = ["a", "b", "c"]
    var md = dedup_descs(distinct)
    expect(len(md.unique) == 3, "3 distinct → 3 unique")
    expect(len(md.per_row) == 3, "per_row aligned to input")
    expect(
        md.per_row[0] == 0 and md.per_row[1] == 1 and md.per_row[2] == 2,
        "identity map",
    )

    # ── duplicates collapse, first-seen order, correct fan-out ──────────────────
    # rows:      0:NFLX 1:AMZN 2:NFLX 3:RENT 4:AMZN 5:NFLX
    var descs: List[String] = ["NFLX", "AMZN", "NFLX", "RENT", "AMZN", "NFLX"]
    var m = dedup_descs(descs)
    expect(len(m.unique) == 3, "3 distinct merchants (NFLX/AMZN/RENT)")
    expect(m.unique[0] == "NFLX", "first-seen order: NFLX")
    expect(m.unique[1] == "AMZN", "first-seen order: AMZN")
    expect(m.unique[2] == "RENT", "first-seen order: RENT")
    expect(len(m.per_row) == 6, "per_row has one entry per input row")
    # every row maps to its merchant's unique slot
    expect(m.per_row[0] == 0, "row0 NFLX -> 0")
    expect(m.per_row[1] == 1, "row1 AMZN -> 1")
    expect(m.per_row[2] == 0, "row2 NFLX -> 0 (dup)")
    expect(m.per_row[3] == 2, "row3 RENT -> 2")
    expect(m.per_row[4] == 1, "row4 AMZN -> 1 (dup)")
    expect(m.per_row[5] == 0, "row5 NFLX -> 0 (dup)")
    # rows sharing a description map to the SAME slot → same verdict on fan-out
    expect(
        m.per_row[0] == m.per_row[2] and m.per_row[2] == m.per_row[5],
        "identical descriptions share one classification",
    )

    # ── exact match only: a differing suffix is NOT collapsed ────────────────────
    var near: List[String] = ["ACME #1", "ACME #2", "ACME #1"]
    var mn = dedup_descs(near)
    expect(len(mn.unique) == 2, "exact dedup keeps #1 and #2 distinct")
    expect(mn.per_row[0] == mn.per_row[2], "the two identical #1 rows collapse")
    expect(
        mn.per_row[0] != mn.per_row[1], "#1 and #2 stay separate (exact match)"
    )

    # ── normalize_desc: strip trailing IDs, keep the merchant, fold near-dupes ───
    expect(
        normalize_desc("NETFLIX.COM") == "netflix.com", "lowercases, no tail"
    )
    expect(
        normalize_desc("ACME STORE #4471") == "acme store",
        "strips a trailing # ref",
    )
    expect(
        normalize_desc("ACME STORE #4471")
        == normalize_desc("ACME STORE #4472"),
        "different store numbers normalize together",
    )
    expect(
        normalize_desc("WALMART 1234") == "walmart", "strips a trailing number"
    )
    # merchant tokens that merely CONTAIN a digit are preserved
    expect(
        normalize_desc("7-ELEVEN 123") == "7-eleven",
        "keeps 7-eleven, drops 123",
    )
    # payload after a `*` marker is NOT the trailing token → preserved
    expect(
        normalize_desc("SQ *BLUE BOTTLE") == "sq *blue bottle",
        "keeps the merchant after SQ *",
    )
    # never strips the only remaining token (never empties)
    expect(normalize_desc("4471") == "4471", "a bare number is left intact")
    # collapses internal whitespace
    expect(normalize_desc("FOO   BAR") == "foo bar", "collapses whitespace")

    # ── normalization folds near-dupes that exact dedup keeps separate ──────────
    var idlike: List[String] = ["ACME #1", "ACME #2", "ACME #3"]
    expect(len(dedup_descs(idlike).unique) == 3, "exact: 3 distinct")
    var normed = List[String]()
    for i in range(len(idlike)):
        normed.append(normalize_desc(idlike[i]))
    expect(len(dedup_descs(normed).unique) == 1, "normalized: all fold to 1")

    print("classify_test: all assertions passed")

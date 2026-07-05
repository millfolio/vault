"""Store_test — the REAL materialization path (`retag`) for tag references.

`derive_ref_tags` is unit-tested directly in `categorize_test`; this pins the
integration in `vault.derive.store.retag`, which is what actually writes group
tags into the `.tags` column. It links `classify` (flare HTTP) but never calls
it — `retag` is pure (no model call, no file I/O), operating on the in-memory
rows + registry passed in. Two guarantees:

  1. a keyword member row gains BOTH the member tag and the group tag;
  2. a row carrying a cached ML tag KEEPS it and gains a group that `@refs` it —
     i.e. refs derive AFTER the ML carry-over and never clobber it.
"""

from vault.derive.categorize import Registry, parse_rules
from vault.derive.store import retag
from vault.extract.transactions import TxnRow


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def _has(tags: List[String], tag: String) -> Bool:
    for i in range(len(tags)):
        if tags[i] == tag:
            return True
    return False


def _row(var desc: String, var tags: List[String]) -> TxnRow:
    """A minimal reconciled row for the retag path (only desc + tags matter)."""
    return TxnRow(
        String("stmt.pdf"),  # falias
        String("2026-01-15"),  # date
        Float64(12.34),  # amount
        String("debit"),  # direction
        desc^,
        tags^,
        0,  # added_gen
        2026,  # year
        String(""),  # merchant
        String(""),  # country
        String(""),  # state
        String(""),  # city
        String(""),  # zip
    )


def main() raises:
    # ── (a) keyword member → member tag AND group tag land in .tags ──────────────
    var reg = Registry(
        parse_rules(
            String(
                "groceries = costco\n"
                "essentials = @groceries\n"  # group referencing the member
            )
        )
    )
    var rows = List[TxnRow]()
    rows.append(_row(String("COSTCO WHSE #0044"), List[String]()))
    rows.append(_row(String("ACME WIDGETS LLC 0099"), List[String]()))
    var changed = retag(rows, reg)
    expect(
        changed == 1,
        "retag: only the Costco row changed (the other matches nothing)",
    )
    expect(
        _has(rows[0].tags, "groceries") and _has(rows[0].tags, "essentials"),
        (
            "retag materializes BOTH the member (groceries) and the group"
            " (essentials)"
        ),
    )
    expect(len(rows[1].tags) == 0, "the unmatched row stays untagged")

    # idempotent: a second retag over the now-tagged rows changes nothing.
    var changed2 = retag(rows, reg)
    expect(changed2 == 0, "retag is idempotent (no row changes on re-run)")

    # ── (b) a cached ML tag is PRESERVED and a group that @refs it is added ───────
    # `wellness = @gym` where `gym` is an ML rule: the row already carries the
    # backfilled `gym` tag (a prior model call). retag must NOT strip `gym` (it's
    # ML, carried over) AND must derive `wellness` from it — refs run AFTER the
    # ML carry-over.
    var mlreg = Registry(
        parse_rules(
            String(
                "gym : is this a gym or fitness studio?\n"  # ML member
                "wellness = @gym\n"  # group referencing the ML tag
            )
        )
    )
    var seeded = List[String]()
    seeded.append(String("gym"))  # simulate the cached ML tag on the row
    var mlrows = List[TxnRow]()
    mlrows.append(_row(String("PLANET FITNESS 0042"), seeded^))
    var mlchanged = retag(mlrows, mlreg)
    expect(mlchanged == 1, "retag: the row gained the group tag → changed")
    expect(
        _has(mlrows[0].tags, "gym"),
        (
            "cached ML tag `gym` is PRESERVED (not stripped by the"
            " deterministic pass)"
        ),
    )
    expect(
        _has(mlrows[0].tags, "wellness"),
        "group `wellness` derived from the carried-over ML tag (@gym)",
    )

    # a row WITHOUT the ML tag doesn't get the group (nothing seeds it).
    var mlrows2 = List[TxnRow]()
    mlrows2.append(_row(String("SOME MERCHANT 0001"), List[String]()))
    _ = retag(mlrows2, mlreg)
    expect(
        len(mlrows2[0].tags) == 0,
        (
            "no ML tag present → no group tag (and the ML rule never matches by"
            " keyword)"
        ),
    )

    print("ok: all store tests passed")

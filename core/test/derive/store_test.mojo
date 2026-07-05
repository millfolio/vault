"""Store_test — the REAL materialization path (`retag`) for tag references.

`derive_ref_tags` is unit-tested directly in `categorize_test`; this pins the
integration in `vault.derive.store.retag`, which is what actually writes group
tags into the `.tags` column. It links `classify` (flare HTTP) but never calls
it — `retag` is pure (no model call, no file I/O), operating on the in-memory
rows + registry passed in. Guarantees:

  1. a keyword member row gains BOTH the member tag and the group tag;
  2. a row carrying a cached ML tag KEEPS it and gains a group that `@refs` it —
     i.e. refs derive AFTER the ML carry-over and never clobber it;
  3. the DIRECTION gate — expense tags never survive on a credit (the "coffee
     shop on an ACH deposit" bug), income tags (transfers/rewards) never on a
     debit; `ml_backfill_rows` skips wrong-direction rows too (exercised on a
     no-eligible-rows credit path, so it returns 0 without any network call).
"""

from vault.derive.categorize import Registry, parse_rules, default_registry
from vault.derive.store import retag, ml_backfill_rows, note_backfilled_tag
from vault.extract.transactions import TxnRow


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def _has(tags: List[String], tag: String) -> Bool:
    for i in range(len(tags)):
        if tags[i] == tag:
            return True
    return False


def _row_dir(
    var desc: String, var tags: List[String], var direction: String
) -> TxnRow:
    """A minimal reconciled row for the retag path (only desc/tags/direction
    matter here)."""
    return TxnRow(
        String("stmt.pdf"),  # falias
        String("2026-01-15"),  # date
        Float64(12.34),  # amount
        direction^,
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


def _row(var desc: String, var tags: List[String]) -> TxnRow:
    """A debit row (the common case) — the existing ref/ML tests are all debits.
    """
    return _row_dir(desc^, tags^, String("debit"))


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

    # ── (c) direction-gated tags: expense tags never land on income ─────────────
    # The reported bug: an "ACH DEPOSIT / INTERNET TRANSFER" credit was tagged
    # "coffee shop" (an expense category). retag must gate every tag by direction —
    # a credit gets only income tags (transfers/rewards), a debit only expense.
    var dreg = default_registry()

    # The failing case: an ACH-deposit CREDIT whose descriptor ALSO contains a
    # coffee keyword. It must get `transfers` (income, credit-side) and NOT
    # `restaurant` (expense) — the expense tag is gated off the credit.
    var drows = List[TxnRow]()
    drows.append(
        _row_dir(
            String("ACH DEPOSIT INTERNET TRANSFER COFFEE ROASTERS"),
            List[String](),
            String("credit"),
        )
    )
    # The SAME coffee merchant as a DEBIT (an actual purchase) still gets its
    # expense tag — the gate doesn't over-reach.
    drows.append(
        _row_dir(
            String("COFFEE ROASTERS #123 SEATTLE"),
            List[String](),
            String("debit"),
        )
    )
    _ = retag(drows, dreg)
    expect(
        _has(drows[0].tags, "transfers")
        and not _has(drows[0].tags, "restaurant"),
        (
            "ACH-deposit CREDIT → transfers (income), NEVER restaurant"
            " (expense) — the reported bug"
        ),
    )
    expect(
        _has(drows[1].tags, "restaurant"),
        "the same coffee merchant as a DEBIT still gets restaurant (expense)",
    )

    # A `transfers`/`rewards` keyword on a DEBIT (e.g. a card-payment transfer OUT)
    # is gated off — income tags are credit-only under the current per-set split.
    var xrows = List[TxnRow]()
    xrows.append(
        _row_dir(
            String("ONLINE TRANSFER TO VISA CARD"),
            List[String](),
            String("debit"),
        )
    )
    _ = retag(xrows, dreg)
    expect(
        not _has(xrows[0].tags, "transfers"),
        "a `transfers` keyword on a DEBIT is gated off (income = credit-only)",
    )

    # ── (d) ML backfill is direction-gated: an expense ML rule skips credits ─────
    # An expense ML rule (tag not in the income set) must never classify a credit —
    # with ONLY credit rows there are no eligible descriptions, so ml_backfill_rows
    # returns 0 WITHOUT reaching the network (no server in this unit test).
    var mlonly = Registry(
        parse_rules(String("gym : is this a gym or fitness studio?\n"))
    )
    var creditrows = List[TxnRow]()
    creditrows.append(
        _row_dir(
            String("PLANET FITNESS DEPOSIT"),
            List[String](),
            String("credit"),
        )
    )
    var no_alias = List[String]()
    var ml_gated = ml_backfill_rows(
        creditrows, mlonly, String("http://127.0.0.1:0/v1"), no_alias
    )
    expect(
        ml_gated == 0 and len(creditrows[0].tags) == 0,
        (
            "expense ML rule skips a credit row → 0 changed, no tag, no network"
            " call"
        ),
    )

    # ── (e) backfill tag-attribution: report a tag only when it tagged a row ─────
    # `note_backfilled_tag` is the pure attribution `_ml_drain_locked`/
    # `ml_backfill_slice` use to name WHICH AI tags a backfill session applied (the
    # Operations "AI-tag backfill complete: <tags>" detail). A tag is reported iff
    # the rule's running change count grew this call, and only once (deduped).
    var reported = List[String]()
    note_backfilled_tag(reported, String("gym"), 0, 2)  # 0→2: tagged → reported
    expect(
        len(reported) == 1 and reported[0] == "gym",
        "note_backfilled_tag: a rule whose change count grew IS reported",
    )
    note_backfilled_tag(reported, String("gym"), 2, 3)  # grew again, same tag
    expect(len(reported) == 1, "the same tag is not reported twice (deduped)")
    note_backfilled_tag(reported, String("dining"), 3, 5)  # a second grown tag
    expect(
        len(reported) == 2 and reported[1] == "dining",
        "a second, distinct grown tag is added",
    )
    note_backfilled_tag(reported, String("coffee"), 5, 5)  # no growth → skip
    expect(
        len(reported) == 2,
        "a rule that changed nothing this call is NOT reported (no false name)",
    )

    print("ok: all store tests passed")

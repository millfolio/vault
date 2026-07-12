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
from vault.derive.store import (
    retag,
    ml_backfill_rows,
    note_backfilled_tag,
    _pending_gens,
)
from vault.derive.ledger import (
    RuleMarker,
    qhash,
    upsert_marker,
    marker_done_gen,
)
from vault.extract.transactions import TxnRow, reconcile_txn_gens


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

    # A `transfers` keyword on a DEBIT (a card-payment transfer OUT) now TAGS:
    # transfers is BOTH-side — the checking leg of a card payment is a debit, and
    # gating it off made spending() double-count card payments against the card's
    # own itemized purchases (the credit-card-payment guard never fired).
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
        _has(xrows[0].tags, "transfers"),
        "a `transfers` keyword on a DEBIT tags (both-side: the payment leg)",
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
    var no_markers = List[RuleMarker]()
    var ml_gated = ml_backfill_rows(
        creditrows,
        mlonly,
        String("http://127.0.0.1:0/v1"),
        no_alias,
        no_markers,
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

    # ── (f) re-index reconcile: identical data → ZERO pending (the reported bug) ──
    # A row builder with an explicit generation + tags, for the reconcile scenarios.
    def _txnr(
        var fa: String,
        var date: String,
        amt: Float64,
        var dir: String,
        var desc: String,
        var tags: List[String],
        gen: Int,
    ) -> TxnRow:
        return TxnRow(
            fa^,
            date^,
            amt,
            dir^,
            desc^,
            tags^,
            gen,
            2026,  # year
            String(""),
            String(""),
            String(""),
            String(""),
            String(""),
        )

    # The stored vault after a backfill: three rows at insertion gens 1..3, two of
    # them carrying the cached `coffee` ML tag (positives), one a cached negative.
    var prev = List[TxnRow]()
    prev.append(
        _txnr(
            "file_0",
            "1/05",
            5.0,
            "debit",
            "BLUE BOTTLE COFFEE",
            [String("coffee")],
            1,
        )
    )
    prev.append(
        _txnr("file_0", "1/06", 9.0, "debit", "SHELL GAS", List[String](), 2)
    )
    prev.append(
        _txnr(
            "file_1", "2/01", 4.0, "debit", "STARBUCKS", [String("coffee")], 3
        )
    )

    # The `coffee` ML rule, backfilled THROUGH gen 3 (marker done_gen = 3).
    var cur = qhash("is this a coffee shop?")
    var markers = List[RuleMarker]()
    upsert_marker(markers, "coffee", cur, 3)
    var mdg = marker_done_gen(markers, "coffee", cur)
    expect(mdg == 3, "marker records the vault backfilled through gen 3")

    # A FULL re-index re-extracts every row with a FRESH, higher generation (7) and
    # EMPTY tags (extraction is tag-agnostic). Before the fix these would all read as
    # pending (added_gen 7 > done_gen 3) → the whole vault re-classifies.
    def _fresh_identical() -> List[TxnRow]:
        var f = List[TxnRow]()
        f.append(
            _txnr(
                "file_0",
                "1/05",
                5.0,
                "debit",
                "BLUE BOTTLE COFFEE",
                List[String](),
                7,
            )
        )
        f.append(
            _txnr(
                "file_0", "1/06", 9.0, "debit", "SHELL GAS", List[String](), 7
            )
        )
        f.append(
            _txnr(
                "file_1", "2/01", 4.0, "debit", "STARBUCKS", List[String](), 7
            )
        )
        return f^

    var fresh = _fresh_identical()
    var reused = reconcile_txn_gens(fresh, prev)
    expect(reused == 3, "reconcile: all three unchanged rows match a prior row")
    expect(
        fresh[0].added_gen == 1
        and fresh[1].added_gen == 2
        and fresh[2].added_gen == 3,
        "reconcile restores each row's PRIOR insertion generation",
    )
    expect(
        _has(fresh[0].tags, "coffee") and _has(fresh[2].tags, "coffee"),
        "reconcile carries over the cached ML tag onto the positives",
    )
    expect(
        len(fresh[1].tags) == 0,
        "the cached NEGATIVE carries no tag (its gen makes it already-covered)",
    )
    # THE FIX: with generations restored, nothing is past done_gen=3 → 0 pending.
    var pend = _pending_gens(fresh, mdg)
    expect(
        len(pend) == 0,
        (
            "re-index of identical data → 0 pending generations (was 1 before"
            " the fix)"
        ),
    )

    # ── (g) a genuinely NEW row is pending; the unchanged one is not ─────────────
    var fresh2 = List[TxnRow]()
    fresh2.append(
        _txnr(
            "file_0",
            "1/05",
            5.0,
            "debit",
            "BLUE BOTTLE COFFEE",
            List[String](),
            7,
        )
    )  # unchanged
    fresh2.append(
        _txnr("file_0", "3/09", 6.0, "debit", "PEETS COFFEE", List[String](), 7)
    )  # NEW
    var reused2 = reconcile_txn_gens(fresh2, prev)
    expect(
        reused2 == 1, "reconcile: only the unchanged row matches a prior row"
    )
    expect(fresh2[0].added_gen == 1, "the unchanged row is restored to gen 1")
    expect(
        fresh2[1].added_gen == 7, "the genuinely-new row keeps the fresh gen 7"
    )
    var pend2 = _pending_gens(fresh2, mdg)
    expect(
        len(pend2) == 1 and pend2[0] == 7,
        "exactly the new row's generation is pending → only it re-classifies",
    )

    # ── (h) a CHANGED descriptor is re-classified; unchanged rows are not ────────
    var fresh3 = List[TxnRow]()
    fresh3.append(
        _txnr(
            "file_0",
            "1/05",
            5.0,
            "debit",
            "BLUE BOTTLE COFFEE",
            List[String](),
            7,
        )
    )  # unchanged
    fresh3.append(
        _txnr(
            "file_0",
            "1/06",
            9.0,
            "debit",
            "SHELL GAS STATION #42",
            List[String](),
            7,
        )
    )  # desc CHANGED
    fresh3.append(
        _txnr("file_1", "2/01", 4.0, "debit", "STARBUCKS", List[String](), 7)
    )  # unchanged
    var reused3 = reconcile_txn_gens(fresh3, prev)
    expect(
        reused3 == 2,
        (
            "reconcile: the two unchanged rows match; the changed descriptor"
            " does not"
        ),
    )
    expect(
        fresh3[1].added_gen == 7 and len(fresh3[1].tags) == 0,
        (
            "the changed-descriptor row keeps the fresh gen + no cached tag →"
            " re-classified"
        ),
    )
    var pend3 = _pending_gens(fresh3, mdg)
    expect(
        len(pend3) == 1 and pend3[0] == 7,
        "only the changed row's generation is pending",
    )

    # ── (i) multiplicity: N identical charges reuse N prior gens; the extra is new ─
    var prevm = List[TxnRow]()
    prevm.append(
        _txnr("file_0", "4/02", 5.0, "debit", "COFFEE", [String("coffee")], 1)
    )
    prevm.append(
        _txnr("file_0", "4/02", 5.0, "debit", "COFFEE", [String("coffee")], 2)
    )
    var freshm = List[TxnRow]()
    freshm.append(
        _txnr("file_0", "4/02", 5.0, "debit", "COFFEE", List[String](), 7)
    )
    freshm.append(
        _txnr("file_0", "4/02", 5.0, "debit", "COFFEE", List[String](), 7)
    )
    freshm.append(
        _txnr("file_0", "4/02", 5.0, "debit", "COFFEE", List[String](), 7)
    )  # a genuine third
    var reusedm = reconcile_txn_gens(freshm, prevm)
    expect(
        reusedm == 2,
        (
            "reconcile: only two prior copies exist → two reuse, the third"
            " stays new"
        ),
    )
    expect(
        freshm[0].added_gen == 1
        and freshm[1].added_gen == 2
        and freshm[2].added_gen == 7,
        (
            "the extra identical charge keeps the fresh generation (correct"
            " multiplicity)"
        ),
    )

    print("ok: all store tests passed")

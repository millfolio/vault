"""Golden-output snapshot — the REGRESSION GUARD for the HUMAN step of bumping
`INDEX_PROCESSING_VERSION`.

`build_index` skips files whose name+content-hash are unchanged, so when the
extraction/parse/chunk LOGIC changes the OUTPUT written to the index silently
drifts for existing vaults unless a developer remembers to bump
`INDEX_PROCESSING_VERSION` (index.mojo) — which forces the one-time rebuild.

This test pins the EXACT on-disk output of the PURE parts of that pipeline — the
parts that fill the persisted index fields — against a small hand-written
fixture:
  • `csv_transactions` + `parse_location` — the CSV index path (index.mojo maps
    each CSV row to a `TxnRow`, then splits the descriptor into
    merchant/country/state);
  • `extract_transactions` + `statement_year` + `parse_location` — the PDF/text
    statement path;
  • `_chunk_text` — the chunker that produces the embedded chunk text (pure —
    no embeddings needed, so it IS asserted here).

Its assertions change ONLY when the indexed output changes. So a green diff that
touches the extractor must ALSO bump `INDEX_PROCESSING_VERSION` and refresh the
values below — the failure message says exactly that. No private data: every
fixture is hand-written.  `pixi run test-golden`.
"""

from std.os.path import exists
from std.testing import assert_equal, assert_true

from vault.extract.transactions import (
    csv_transactions,
    extract_transactions,
    statement_year,
)
from vault.extract.location import parse_location
from vault.index.index import _chunk_text
from vault.index.sha256 import sha256_file_hex


# The message every golden assertion carries — read it when this test goes red.
comptime BUMP_MSG = (
    "Extraction output changed. If this changes what gets written to the index,"
    " BUMP INDEX_PROCESSING_VERSION in index.mojo (so existing indexes rebuild)"
    " and update this golden."
)


def _close(a: Float64, b: Float64) -> Bool:
    var d = a - b
    return d < 0.005 and d > -0.005


# ── net 2: source fingerprint of the PURE extraction modules ──────────────────
# A change to either file below flips its sha256 → a red reminder to CONSIDER a
# version bump. index.mojo is DELIBERATELY excluded (it churns for unrelated
# reasons — embedding, manifest, LanceDB — which would make this noisy). Paths
# are relative to the pixi manifest dir (vault root), the cwd the test runs in.
comptime LOCATION_SRC = "core/src/vault/extract/location.mojo"
comptime TRANSACTIONS_SRC = "core/src/vault/extract/transactions.mojo"
# Set from a first run (the test PRINTS the computed value when the constant is
# "" — see the fingerprint block in main()).
comptime EXPECTED_LOCATION_FP = (
    "542356856ca44ae371c523804832af26f532c6c42394ce1c6c7a2b07d8eaaf23"
)
comptime EXPECTED_TRANSACTIONS_FP = (
    "ba3001c9c853ab1c27e1a9f27244a2f0d640e397dd5b83645a61bee5a8d95b4f"
)


def _golden_csv() raises -> List[List[String]]:
    """A 2-row CSV export: one LOCATED row (trailing US state + ISO3 country +
    a store-number digit run) and one NON-LOCATED transfer. Pins both the
    csv_transactions column mapping AND the parse_location split."""
    var rows = List[List[String]]()
    rows.append(
        [
            String("Transaction Date"),
            String("Description"),
            String("Type"),
            String("Amount (USD)"),
        ]
    )
    rows.append(
        [
            String("01/15/2025"),
            String("STARBUCKS STORE 04821 SEATTLE WA USA"),
            String("Purchase"),
            String("4.50"),
        ]
    )
    rows.append(
        [
            String("02/03/2026"),
            String("ACH TRANSFER PAYROLL"),
            String("Payment"),
            String("-100.00"),
        ]
    )
    # A refund row whose descriptor carries a trailing `(return)` annotation: the
    # persisted `.desc` keeps it, but parse_location strips it to recover the geo.
    rows.append(
        [
            String("03/20/2026"),
            String("WHOLE FOODS MKT SEATTLE WA USA (return)"),
            String("Purchase"),
            String("-12.34"),
        ]
    )
    return rows^


def _golden_statement() raises -> String:
    """A tiny flat checking statement (date / desc / amount / running-balance)
    that reconciles via the balance recurrence, with a located + a foreign + a
    non-located descriptor. Flat history (no inter-row section headers) so no
    descriptor absorbs a following line. Pins the PDF/text index path
    (extract_transactions + statement_year + parse_location)."""
    var s = String("Wells Fargo Everyday Checking\n")
    s += "Statement period 04/01/2026 - 04/30/2026\n"
    s += "Beginning balance on 4/01  1,000.00\n"
    s += "4/02\nACH TRANSFER PAYROLL\n500.00\n1,500.00\n"
    s += "4/05\nSTARBUCKS STORE 04821 SEATTLE WA USA\n4.50\n1,495.50\n"
    s += "4/10\nTESCO STORES 3421 LONDON GBR\n89.99\n1,405.51\n"
    s += "Total deposits and other additions  500.00\n"
    s += "Total withdrawals and other debits  94.49\n"
    s += "Ending balance  1,405.51\n"
    return s^


def main() raises:
    # ── CSV path: csv_transactions + parse_location, EXACT per-row output ──────
    var ct = csv_transactions(_golden_csv())
    assert_equal(len(ct), 3, BUMP_MSG + " [csv row count]")

    # Row 0 — LOCATED: STARBUCKS STORE 04821 SEATTLE WA USA, a $4.50 purchase.
    assert_equal(ct[0].date, "1/15", BUMP_MSG + " [csv[0].date]")
    assert_equal(ct[0].year, 2025, BUMP_MSG + " [csv[0].year]")
    assert_equal(ct[0].direction, "debit", BUMP_MSG + " [csv[0].direction]")
    assert_true(_close(ct[0].amount, 4.50), BUMP_MSG + " [csv[0].amount]")
    assert_equal(
        ct[0].desc,
        "STARBUCKS STORE 04821 SEATTLE WA USA",
        BUMP_MSG + " [csv[0].desc]",
    )
    var loc0 = parse_location(ct[0].desc)
    assert_equal(
        loc0.merchant, "STARBUCKS STORE", BUMP_MSG + " [loc0.merchant]"
    )
    assert_equal(loc0.state, "WA", BUMP_MSG + " [loc0.state]")
    assert_equal(loc0.country, "USA", BUMP_MSG + " [loc0.country]")

    # Row 1 — NON-LOCATED: an ACH transfer, a $100 credit, no geo.
    assert_equal(ct[1].date, "2/3", BUMP_MSG + " [csv[1].date]")
    assert_equal(ct[1].year, 2026, BUMP_MSG + " [csv[1].year]")
    assert_equal(ct[1].direction, "credit", BUMP_MSG + " [csv[1].direction]")
    assert_true(_close(ct[1].amount, 100.00), BUMP_MSG + " [csv[1].amount]")
    assert_equal(
        ct[1].desc, "ACH TRANSFER PAYROLL", BUMP_MSG + " [csv[1].desc]"
    )
    var loc1 = parse_location(ct[1].desc)
    assert_equal(
        loc1.merchant, "ACH TRANSFER PAYROLL", BUMP_MSG + " [loc1.merchant]"
    )
    assert_equal(loc1.state, "", BUMP_MSG + " [loc1.state]")
    assert_equal(loc1.country, "", BUMP_MSG + " [loc1.country]")

    # Row 2 — REFUND with a trailing `(return)` annotation. The persisted `.desc`
    # keeps the FULL original string; parse_location strips the parenthetical so
    # the trailing geo tokens (WA / USA) parse and the merchant stays the brand.
    assert_equal(
        ct[2].desc,
        "WHOLE FOODS MKT SEATTLE WA USA (return)",
        BUMP_MSG + " [csv[2].desc keeps (return)]",
    )
    var loc2 = parse_location(ct[2].desc)
    assert_equal(
        loc2.merchant,
        "WHOLE FOODS MKT SEATTLE",
        BUMP_MSG + " [loc2.merchant]",
    )
    assert_equal(loc2.state, "WA", BUMP_MSG + " [loc2.state]")
    assert_equal(loc2.country, "USA", BUMP_MSG + " [loc2.country]")

    # ── PDF/text path: extract_transactions + statement_year + parse_location ──
    var ext = extract_transactions(_golden_statement())
    assert_true(ext.reconciled, BUMP_MSG + " [statement reconciled]")
    assert_equal(
        ext.method, "balance-recurrence", BUMP_MSG + " [statement method]"
    )
    assert_equal(len(ext.txns), 3, BUMP_MSG + " [statement txn count]")
    assert_equal(
        statement_year(_golden_statement()),
        2026,
        BUMP_MSG + " [statement year]",
    )
    # The located purchase row splits to merchant/state/country; the foreign one
    # yields an ISO3 country and no US state; the transfer stays location-less.
    var seen_starbucks = False
    var seen_tesco = False
    var seen_ach = False
    for i in range(len(ext.txns)):
        var loc = parse_location(ext.txns[i].desc)
        if loc.merchant == "STARBUCKS STORE":
            seen_starbucks = True
            assert_equal(loc.state, "WA", BUMP_MSG + " [stmt STARBUCKS state]")
            assert_equal(
                loc.country, "USA", BUMP_MSG + " [stmt STARBUCKS country]"
            )
            assert_equal(
                ext.txns[i].direction,
                "debit",
                BUMP_MSG + " [stmt STARBUCKS direction]",
            )
        elif loc.merchant == "TESCO STORES":
            seen_tesco = True
            assert_equal(loc.state, "", BUMP_MSG + " [stmt TESCO state]")
            assert_equal(loc.country, "GBR", BUMP_MSG + " [stmt TESCO country]")
        elif loc.merchant == "ACH TRANSFER PAYROLL":
            seen_ach = True
            assert_equal(loc.country, "", BUMP_MSG + " [stmt ACH country]")
            assert_equal(
                ext.txns[i].direction,
                "credit",
                BUMP_MSG + " [stmt ACH direction]",
            )
    assert_true(
        seen_starbucks and seen_tesco and seen_ach,
        BUMP_MSG + " [statement descriptors changed]",
    )

    # ── chunking: _chunk_text is PURE (no embeddings) → assert it directly ─────
    # A small multi-line body fits in one CHUNK_SIZE window, so the chunker emits
    # exactly one chunk equal to the lines rejoined with '\n'. Pins chunk count
    # and boundary text (the value that gets embedded + stored in chunks.tsv).
    var body = String(
        "Line one about coffee.\nLine two about rent.\nLine three about travel."
    )
    var chunks = _chunk_text(body)
    assert_equal(len(chunks), 1, BUMP_MSG + " [chunk count]")
    assert_equal(chunks[0], body, BUMP_MSG + " [chunk[0] text]")

    # ── net 2: source fingerprint of the pure extraction modules ──────────────
    # If a source file is missing (test run from a non-root cwd) SKIP rather than
    # fail — the golden snapshot above is the essential guard.
    if not (exists(LOCATION_SRC) and exists(TRANSACTIONS_SRC)):
        print(
            "SKIP fingerprint net: extraction sources not found (run from vault"
            " root)"
        )
    else:
        var loc_fp = sha256_file_hex(String(LOCATION_SRC))
        var txn_fp = sha256_file_hex(String(TRANSACTIONS_SRC))
        var fp_msg = (
            "An extraction module changed. If this changes indexed output, bump"
            " INDEX_PROCESSING_VERSION (index.mojo); then update"
            " EXPECTED_EXTRACT_FINGERPRINT here."
        )
        if EXPECTED_LOCATION_FP == "" or EXPECTED_TRANSACTIONS_FP == "":
            # Regenerate mode: no committed value yet — print the current
            # fingerprints so a developer can paste them into the constants.
            print("SET EXPECTED_LOCATION_FP =", loc_fp)
            print("SET EXPECTED_TRANSACTIONS_FP =", txn_fp)
        else:
            assert_equal(
                loc_fp, EXPECTED_LOCATION_FP, fp_msg + " [location.mojo]"
            )
            assert_equal(
                txn_fp,
                EXPECTED_TRANSACTIONS_FP,
                fp_msg + " [transactions.mojo]",
            )

    print("ok: all golden-output tests passed")

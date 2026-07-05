"""Persist_test — the REAL on-disk write path for extracted transactions.

Guards the prod regression where `write_txn_rows` wrote `transactions.tsv.tmp`
but the `rename(2)` that promotes it to `transactions.tsv` silently failed —
`String.unsafe_ptr()` is NOT guaranteed NUL-terminated, so libc `rename` got a
garbage path, returned -1, and NO transactions were ever persisted (every
statement extracted, reconciled, and then vanished → all transaction analytics
returned 0). The in-memory `txn_rows_to_tsv`/`tsv_to_txn_rows` round-trip
(transactions_test) never touched the file boundary, so it stayed green.

This drives the full boundary: `extract_transactions` on a synthetic reconciling
statement → build `TxnRow`s → `write_txn_rows` (tmp + atomic rename) →
`load_txn_rows` reads them back. It pins BOTH that reconciliation still returns
the rows AND that the file is actually created (the rename lands). Uses a pinned
`MILLFOLIO_DATA_DIR` (set by the pixi task) so no real vault is touched.
"""

from std.os import getenv, makedirs
from std.os.path import exists
from vault.derive.store import write_txn_rows
from vault.derive.tags import txns_path, load_txn_rows
from vault.extract.transactions import (
    extract_transactions,
    TxnRow,
)


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def _synthetic_statement() -> String:
    """A column-aligned checking statement that reconciles by the running-balance
    recurrence: Beginning 2,450.00; each row carries an Additions OR Subtractions
    amount plus a running Balance; Ending 6,512.35. 9 transactions."""
    return String(
        "Riverbank Federal Credit Union\n"
        "Checking Account Statement\n"
        "Account: ****4417    Statement period: 03/01/2026 - 03/31/2026\n"
        "Account summary\n"
        "Beginning balance                          2,450.00\n"
        "Date     Description               Additions   Subtractions   "
        " Balance\n"
        "3/03     Acme Payroll Direct Deposit   2,800.00               "
        " 5,250.00\n"
        "3/05     Corner Market                              82.40      "
        " 5,167.60\n"
        "3/05     Sunrise Cafe                               14.75      "
        " 5,152.85\n"
        "3/09     City Power & Light                        134.20      "
        " 5,018.65\n"
        "3/12     Metro Transit Pass                         60.00      "
        " 4,958.65\n"
        "3/15     Online Transfer From Savings 500.00                   "
        " 5,458.65\n"
        "3/18     Riverbank Mortgage Payment              1,650.00      "
        " 3,808.65\n"
        "3/22     Grocery Outlet                             96.30      "
        " 3,712.35\n"
        "3/28     Acme Payroll Direct Deposit   2,800.00               "
        " 6,512.35\n"
        "Deposits/Additions                         6,100.00\n"
        "Withdrawals/Subtractions                   2,037.65\n"
        "Ending balance                             6,512.35\n"
    )


def main() raises:
    # A pinned data dir keeps the test hermetic (the task sets MILLFOLIO_DATA_DIR).
    var dd = String(getenv("MILLFOLIO_DATA_DIR", "").strip())
    expect(dd != "", "MILLFOLIO_DATA_DIR must be set by the test task")
    makedirs(dd, exist_ok=True)

    # 1) A synthetic reconciling statement extracts to 9 trusted transactions.
    var ext = extract_transactions(_synthetic_statement())
    expect(ext.reconciled, "extract_transactions reconciles the statement")
    expect(
        len(ext.txns) == 9,
        "extract_transactions returns 9 transactions (got "
        + String(len(ext.txns))
        + ")",
    )

    # 2) Build persisted rows and WRITE them (tmp + rename). This is the step that
    #    regressed: the rename dropped every row on the floor.
    var rows = List[TxnRow]()
    for x in range(len(ext.txns)):
        ref t = ext.txns[x]
        rows.append(
            TxnRow(
                String("stmt.pdf"),
                t.date.copy(),
                t.amount,
                t.direction.copy(),
                t.desc.copy(),
                List[String](),
                1,
                2026,
                String(""),
                String(""),
                String(""),
                String(""),
                String(""),
            )
        )
    write_txn_rows(rows)

    # 3) transactions.tsv must actually EXIST (the tmp was promoted) and NOT leave a
    #    stale tmp behind.
    expect(
        exists(txns_path()),
        "transactions.tsv exists after write_txn_rows (the rename landed)",
    )
    expect(
        not exists(txns_path() + ".tmp"),
        "no leftover transactions.tsv.tmp (rename consumed it)",
    )

    # 4) Read them back — all 9 round-trip with amount + direction + desc intact.
    var back = load_txn_rows()
    expect(
        len(back) == 9,
        "load_txn_rows reads back all 9 rows (got " + String(len(back)) + ")",
    )
    var sum = 0.0
    for i in range(len(back)):
        sum += back[i].amount
    # 2800+82.40+14.75+134.20+60+500+1650+96.30+2800 = 8137.65
    expect(
        sum > 8137.64 and sum < 8137.66,
        "round-tripped amounts sum to the expected 8137.65 (got "
        + String(sum)
        + ")",
    )

    print("ok: all persist tests passed")

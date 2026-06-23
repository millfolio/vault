"""transactions-test — the invariant-aware extractor reconciles SYNTHETIC statement
text against its own arithmetic. NO private data: every fixture is hand-written
below. `pixi run test-transactions`.

Covers: (A) a checking statement validated by the running-balance recurrence;
(B) the same statement with one corrupted amount → must NOT reconcile (the gate
works); (C) a sectioned card statement validated by sum-vs-printed-total; and the
format-agnostic token scanners (money `.dd` filter, date-token rejection)."""

from vault.transactions import (
    extract_transactions, _money_tokens, _leading_date, Extraction,
    TxnRow, txn_rows_to_tsv, tsv_to_txn_rows, select_txns, drop_aliases,
    texts_for_alias,
)
from vault.amounts import parse_amount


def _say(ok: Bool, label: String):
    print("[" + ("PASS" if ok else "FAIL") + "] " + label)


def _close(a: Float64, b: Float64) -> Bool:
    var d = a - b
    return d < 0.005 and d > -0.005


# A checking statement: date / description / amount / running-balance columns,
# flattened to separate lines exactly like PDF text extraction produces.
def _checking(rent_amount: String) raises -> String:
    var s = String("Wells Fargo Everyday Checking\n")
    s += "Beginning balance on 4/01  1,000.00\n"
    s += "4/02\nPaycheck Deposit Acme Corp\n500.00\n1,500.00\n"
    s += "4/05\nGrocery Store Purchase\n120.00\n1,380.00\n"
    s += "4/10\nRent Payment Landlord LLC\n" + rent_amount + "\n580.00\n"
    s += "Total deposits and other additions  500.00\n"
    s += "Total withdrawals and other debits  920.00\n"
    s += "Ending balance  580.00\n"
    return s^


def _card() raises -> String:
    var s = String("Costco Anywhere Visa Card by Citi\n")
    s += "Payments and Other Credits\n"
    s += "4/03\nACME PAYMENT THANK YOU\n100.00\n"
    s += "Purchases and Adjustments\n"
    s += "4/06\nCOFFEE SHOP DOWNTOWN\n4.50\n"
    s += "4/12\nHARDWARE STORE\n89.99\n"
    s += "4/20\nONLINE RETAILER\n250.00\n"
    s += "Total payments and credits  100.00\n"
    s += "Total purchases  344.49\n"
    s += "New balance  244.49\n"
    return s^


# A LAYOUT-PRESERVED checking statement (columns aligned with spaces, exactly like
# pdftotext's extract_text_layout produces): date / description / Deposits column /
# Withdrawals column / Ending-daily-balance column. Includes INTRA-DAY rows — 4/06 has
# three transactions but only the LAST prints a running balance, and 4/14 has two — so
# per-transaction direction must come from the COLUMN a value sits in, validated by the
# running-balance recurrence. `dep1` lets a fixture corrupt one deposit (negative test).
#   begin 1,000.00
#   4/02  +500.00  -> 1,500.00          (one deposit, balance shown)
#   4/06  +250.00, -40.00, -110.00 -> 1,600.00   (intra-day: 1 deposit + 2 withdrawals)
#   4/10  -800.00 -> 800.00             (rent withdrawal)
#   4/14  +1,200.00, -300.00 -> 1,700.00 (intra-day: deposit + withdrawal)
#   deposits total 1,950.00 ; withdrawals total 1,250.00 ; ending 1,700.00
def _checking_layout(dep1: String) raises -> String:
    #        date  description (col ~22)                       deposits(~58)  withdrawals(~76)  balance(~96)
    var s = String("Wells Fargo Everyday Checking\n")
    s += "Statement period activity summary\n"
    s += "Beginning balance on 4/01                                                    1,000.00\n"
    s += "Deposits/Additions                                                           1,950.00\n"
    s += "Withdrawals/Subtractions                                                  -  1,250.00\n"
    s += "Ending balance on 4/30                                                       1,700.00\n"
    s += "Transaction history\n"
    s += " Date         Description                            Additions    Subtractions       balance\n"
    s += "4/02          Paycheck Deposit Acme Corp           " + dep1 + "                          1,500.00\n"
    s += "4/06          Mobile Deposit Refund                    250.00                                    \n"
    s += "4/06          Coffee Shop Downtown                                    40.00                      \n"
    s += "4/06          Hardware Store Purchase                                110.00              1,600.00\n"
    s += "4/10          Rent Payment Landlord LLC                              800.00                800.00\n"
    s += "4/14          Online Transfer From Savings           1,200.00                                    \n"
    s += "4/14          Utility Bill Autopay                                    300.00              1,700.00\n"
    s += "Totals                                                  1,950.00      1,250.00\n"
    return s^


def _max_debit(e: Extraction) -> Float64:
    var m = 0.0
    for i in range(len(e.txns)):
        if e.txns[i].direction == "debit" and e.txns[i].amount > m:
            m = e.txns[i].amount
    return m


def _sum_dir(e: Extraction, dir: String) -> Float64:
    var s = 0.0
    for i in range(len(e.txns)):
        if e.txns[i].direction == dir:
            s += e.txns[i].amount
    return s


def _count_dir(e: Extraction, dir: String) -> Int:
    var n = 0
    for i in range(len(e.txns)):
        if e.txns[i].direction == dir:
            n += 1
    return n


def main() raises:
    var ok = True

    # ── token scanners (format-agnostic primitives) ───────────────────────────
    var t1 = _money_tokens("the purchase price must have been more than $5")
    var s1 = (len(t1) == 0)
    _say(s1, "money: '$5' (no cents) is not an amount"); ok = s1 and ok

    var t2 = _money_tokens("Subtotal $1,234.56 over 100 miles away")
    var s2 = (len(t2) == 1 and _close(parse_amount(t2[0]), 1234.56))
    _say(s2, "money: keeps $1,234.56, drops bare 100"); ok = s2 and ok

    var s3 = (_leading_date("1330  Check  1,854.00") == "")
    _say(s3, "date: a check number (1330) is not a date"); ok = s3 and ok

    var s4 = (_leading_date("4/17  1330  Check") == "4/17")
    _say(s4, "date: 4/17 is a valid leading date"); ok = s4 and ok

    # ── A: checking statement reconciles via running balance ──────────────────
    var a = extract_transactions(_checking("800.00"))
    var sa = (a.reconciled and a.method == "balance-recurrence" and len(a.txns) == 3)
    _say(sa, "A: checking reconciles via balance-recurrence, 3 txns"); ok = sa and ok
    var sa2 = (_count_dir(a, "credit") == 1 and _count_dir(a, "debit") == 2)
    _say(sa2, "A: 1 credit (deposit) + 2 debits"); ok = sa2 and ok
    var sa3 = _close(_max_debit(a), 800.0)
    _say(sa3, "A: biggest debit = 800.00 (the rent)"); ok = sa3 and ok

    # ── B: corrupt one amount → the gate must REFUSE to reconcile ─────────────
    var b = extract_transactions(_checking("999.00"))   # balance no longer closes
    var sb = (not b.reconciled and b.method == "unreconciled")
    _say(sb, "B: a corrupted amount does NOT reconcile (gate works)"); ok = sb and ok

    # ── C: sectioned card statement reconciles via sum-vs-printed-total ────────
    var c = extract_transactions(_card())
    var sc = (c.reconciled and c.method == "sum-vs-total" and len(c.txns) == 4)
    _say(sc, "C: card reconciles via sum-vs-total, 4 txns"); ok = sc and ok
    var sc2 = (_count_dir(c, "credit") == 1 and _count_dir(c, "debit") == 3)
    _say(sc2, "C: 1 payment (credit) + 3 purchases (debit)"); ok = sc2 and ok
    var sc3 = _close(_max_debit(c), 250.0)
    _say(sc3, "C: most expensive purchase = 250.00"); ok = sc3 and ok

    # ── D: LAYOUT-PRESERVED checking with INTRA-DAY rows reconciles via columns ─
    # 4/06 and 4/14 each carry several transactions but only the day's LAST row prints
    # a balance, so direction is recovered from the deposit/withdrawal COLUMN, then the
    # running balance is asserted at each checkpoint (the trust gate).
    var d = extract_transactions(_checking_layout("500.00"))
    var sd0 = (d.reconciled and d.method == "column-direction" and len(d.txns) == 7)
    _say(sd0, "D: intra-day layout reconciles via column-direction, 7 txns"); ok = sd0 and ok
    var sd1 = (_count_dir(d, "credit") == 3 and _count_dir(d, "debit") == 4)
    _say(sd1, "D: 3 deposits (credit) + 4 withdrawals (debit)"); ok = sd1 and ok
    var sd2 = (_close(_sum_dir(d, "credit"), 1950.0) and _close(_sum_dir(d, "debit"), 1250.0))
    _say(sd2, "D: sum(credits)=1,950.00 + sum(debits)=1,250.00 match printed totals"); ok = sd2 and ok
    var sd3 = _close(_max_debit(d), 800.0)
    _say(sd3, "D: biggest debit = 800.00 (the rent)"); ok = sd3 and ok

    # ── E: corrupt one deposit in the layout statement → must NOT reconcile ─────
    # 4/02's deposit 500.00 → 600.00 breaks both the running balance AND the printed
    # Deposits/Additions total, so the column-direction gate (and every fallback) abstains.
    var e = extract_transactions(_checking_layout("600.00"))
    var se0 = (not e.reconciled and e.method == "unreconciled")
    _say(se0, "E: a corrupted deposit does NOT reconcile (column-direction gate works)"); ok = se0 and ok

    # ── enumeration helper: texts_for_alias returns ALL of a file, id-ordered ──
    var ids = List[Int]()
    var als = List[String]()
    var txt = List[String]()
    ids.append(2); als.append(String("file_1")); txt.append(String("B"))
    ids.append(0); als.append(String("file_0")); txt.append(String("a0"))
    ids.append(1); als.append(String("file_1")); txt.append(String("A"))
    ids.append(5); als.append(String("file_0")); txt.append(String("a5"))
    var f1 = texts_for_alias(ids, als, txt, String("file_1"))
    var se = (len(f1) == 2 and f1[0] == "A" and f1[1] == "B")   # id 1 ("A") before id 2 ("B")
    _say(se, "file_chunks: all of file_1's chunks, in document (id) order"); ok = se and ok

    # ── transactions persistence: TSV round-trip + per-file selection ─────────
    var rows = List[TxnRow]()
    rows.append(TxnRow(String("file_0"), String("4/02"), 500.0, String("credit"), String("Pay\tDay")))
    rows.append(TxnRow(String("file_0"), String("4/10"), 800.0, String("debit"), String("Rent")))
    rows.append(TxnRow(String("file_1"), String("4/06"), 4.50, String("debit"), String("Coffee")))
    var back = tsv_to_txn_rows(txn_rows_to_tsv(rows))
    var sr = (len(back) == 3 and back[0].desc == "Pay\tDay" and _close(back[1].amount, 800.0))
    _say(sr, "transactions: TSV round-trips (incl. an escaped tab in desc)"); ok = sr and ok
    var sel = select_txns(back, String("file_0"))
    var ss = (len(sel) == 2 and sel[0].direction == "credit" and _close(sel[1].amount, 800.0))
    _say(ss, "transactions: select_txns returns just file_0's two rows"); ok = ss and ok
    var dropped = drop_aliases(back, [String("file_0")])
    var sd = (len(dropped) == 1 and dropped[0].falias == "file_1")
    _say(sd, "transactions: drop_aliases evicts file_0, keeps file_1"); ok = sd and ok

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("transactions-test failed")

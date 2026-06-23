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


def _max_debit(e: Extraction) -> Float64:
    var m = 0.0
    for i in range(len(e.txns)):
        if e.txns[i].direction == "debit" and e.txns[i].amount > m:
            m = e.txns[i].amount
    return m


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

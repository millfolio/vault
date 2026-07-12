from vault import *

def main() raises:
    var n = 0
    var spent = 0.0
    var received = 0.0
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            n += 1
            if x.direction == "debit":
                spent += x.amount
            elif x.direction == "credit":
                received += x.amount
    if n > 0:
        print_answer("You have " + String(n) + " transactions in total: "
            + money(spent) + " out (debits/purchases) and "
            + money(received) + " in (credits/deposits).")
        return
    # Fallback: no reconciled transactions — scan all chunks
    progress("no reconciled transactions found, scanning chunks...")
    var total_debit = 0.0
    var total_credit = 0.0
    var count = 0
    for i in range(len(files)):
        progress("chunk-scanning " + files[i].alias)
        var chunks = file_chunks(files[i].alias)
        var cand = List[String]()
        for c in range(len(chunks)):
            if chunks[c].find(".") != -1:
                cand.append(chunks[c])
        if len(cand) == 0:
            continue
        var ans = ask_local_batch(
            "Use ONLY the text provided. If it clearly shows a financial transaction with an amount,"
            " reply as 'debit|AMOUNT' or 'credit|AMOUNT' (e.g. 'debit|42.10' or 'credit|500.00')."
            " If not a transaction, reply 'none'. Do not guess or invent.", cand)
        for a in range(len(ans)):
            var s = String(ans[a].strip())
            if s == "none" or s == "" or s.find("|") == -1:
                continue
            var parts = s.split("|")
            if len(parts) < 2:
                continue
            var direction = String(parts[0].strip())
            var amt = parse_amount(String(parts[1].strip()))
            if amt <= 0.0:
                continue
            count += 1
            if direction == "debit":
                total_debit += amt
            elif direction == "credit":
                total_credit += amt
    if count > 0:
        print_answer("Found approximately " + String(count) + " transactions: "
            + money(total_debit) + " out (debits) and "
            + money(total_credit) + " in (credits).")
    else:
        print_answer("I couldn't find any verified transactions in your vault.")
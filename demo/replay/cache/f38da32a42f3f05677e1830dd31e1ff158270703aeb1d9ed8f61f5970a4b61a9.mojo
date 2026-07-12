from vault import *

def main() raises:
    var total_spent = 0.0
    var total_received = 0.0
    var n_debits = 0
    var n_credits = 0
    var any_txns = False
    var files = manifest()

    for i in range(len(files)):
        progress("checking transactions in " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            any_txns = True
            ref x = txns[t]
            if x.direction == "debit":
                total_spent += x.amount
                n_debits += 1
            elif x.direction == "credit":
                total_received += x.amount
                n_credits += 1

    if any_txns:
        print_answer("Based on your vault:\n"
            + "  Total spent (debits): " + money(total_spent) + " across " + String(n_debits) + " transactions\n"
            + "  Total received (credits): " + money(total_received) + " across " + String(n_credits) + " transactions")
        return

    # Fallback: no reconciled transactions — scan all chunks
    progress("No reconciled transactions found, scanning file chunks...")
    var all_amounts = List[String]()
    var all_directions = List[String]()

    for i in range(len(files)):
        progress("scanning chunks in " + files[i].alias)
        var chunks = file_chunks(files[i].alias)
        var cand = List[String]()
        for c in range(len(chunks)):
            if chunks[c].find(".") != -1:
                cand.append(chunks[c])
        if len(cand) == 0:
            continue
        var ans = ask_local_batch(
            "Use ONLY the text provided. If this text contains a spending/purchase/debit transaction "
            "with a dollar amount, reply with just the amount as a number (e.g. 42.10). "
            "If it is a credit/deposit/refund, reply 'credit:AMOUNT' (e.g. 'credit:42.10'). "
            "Otherwise reply 'none'. Do not guess or invent.", cand)
        for a in range(len(ans)):
            var s = String(ans[a].strip())
            if s == "none" or s == "":
                continue
            if s.startswith("credit:"):
                var parts = s.split(":")
                if len(parts) >= 2:
                    all_amounts.append(String(parts[1].strip()))
                    all_directions.append("credit")
            else:
                all_amounts.append(s)
                all_directions.append("debit")

    if len(all_amounts) == 0:
        print_answer("I couldn't find any spending information in your vault.")
        return

    var spent2 = 0.0
    var received2 = 0.0
    var nd = 0
    var nc = 0
    for i in range(len(all_amounts)):
        var amt = parse_amount(all_amounts[i])
        if amt <= 0.0:
            continue
        if all_directions[i] == "debit":
            spent2 += amt
            nd += 1
        else:
            received2 += amt
            nc += 1

    if nd > 0 or nc > 0:
        print_answer("Based on your vault:\n"
            + "  Total spent (debits): " + money(spent2) + " across " + String(nd) + " transactions\n"
            + "  Total received (credits): " + money(received2) + " across " + String(nc) + " transactions")
    else:
        print_answer("I couldn't find any clear spending amounts in your vault.")
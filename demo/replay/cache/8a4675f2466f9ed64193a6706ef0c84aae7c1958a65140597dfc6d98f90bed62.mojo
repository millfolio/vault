from vault import *

def main() raises:
    var total_spent = 0.0
    var total_received = 0.0
    var n_debits = 0
    var n_credits = 0
    var files = manifest()

    for i in range(len(files)):
        progress("checking transactions in " + files[i].alias)
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction == "debit":
                total_spent += x.amount
                n_debits += 1
            elif x.direction == "credit":
                total_received += x.amount
                n_credits += 1

    if n_debits > 0 or n_credits > 0:
        print_answer("You spent " + money(total_spent) + " across " + String(n_debits) +
            " debit transactions, and received " + money(total_received) +
            " across " + String(n_credits) + " credit/deposit transactions.")
    else:
        # fallback: scan all chunks
        progress("no verified transactions found, scanning file chunks...")
        var cand = List[String]()
        var cand_sources = List[String]()
        for i in range(len(files)):
            progress("scanning chunks in " + files[i].alias)
            var chunks = file_chunks(files[i].alias)
            for c in range(len(chunks)):
                if chunks[c].find(".") != -1:
                    cand.append(chunks[c])
                    cand_sources.append(files[i].alias)

        var ans = ask_local_batch(
            "Use ONLY the text provided. If it contains a debit or purchase/payment amount, "
            "reply with just the numeric amount (e.g. 42.10). If it is a credit/deposit, "
            "reply 'credit:AMOUNT' (e.g. credit:100.00). Otherwise reply 'none'. "
            "Do not guess or invent.", cand)

        var fallback_spent = 0.0
        var fallback_received = 0.0
        var fb_debits = 0
        var fb_credits = 0
        for a in range(len(ans)):
            var s = String(ans[a].strip())
            if s == "none" or s == "":
                continue
            if s.startswith("credit:"):
                var parts = s.split(":")
                if len(parts) >= 2:
                    fallback_received += parse_amount(String(parts[1].strip()))
                    fb_credits += 1
            else:
                var amt = parse_amount(s)
                if amt > 0.0:
                    fallback_spent += amt
                    fb_debits += 1

        if fb_debits > 0 or fb_credits > 0:
            print_answer("You spent approximately " + money(fallback_spent) +
                " (across ~" + String(fb_debits) + " debit items) and received approximately " +
                money(fallback_received) + " (across ~" + String(fb_credits) + " credit items).")
        else:
            print_answer("I couldn't find any transaction amounts in your vault.")
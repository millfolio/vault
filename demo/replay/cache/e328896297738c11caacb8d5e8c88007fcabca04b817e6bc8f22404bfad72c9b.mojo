from vault import *
def main() raises:
    var n = 0
    var spent = 0.0
    var received = 0.0
    var files = manifest()
    for i in range(len(files)):
        progress("checking transactions in " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
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
            + money(received) + " in (credits/deposits). "
            + "Net: " + money(received - spent) + ".")
    else:
        # fallback: scan all chunks
        progress("no reconciled transactions found, scanning file chunks...")
        var all_amounts = List[String]()
        var chunk_dirs = List[String]()
        for i in range(len(files)):
            progress("scanning chunks of " + files[i].alias)
            var chunks = file_chunks(files[i].alias)
            for c in range(len(chunks)):
                if chunks[c].find(".") != -1:
                    all_amounts.append(chunks[c])
                    chunk_dirs.append(files[i].alias)
        var ans = ask_local_batch(
            "Use ONLY the text provided. If it contains a transaction with an amount, "
            "reply as 'debit|AMOUNT' or 'credit|AMOUNT' (e.g. 'debit|42.10'). "
            "Otherwise reply 'none'. Do not guess or invent.", all_amounts)
        var total_debit = 0.0
        var total_credit = 0.0
        var count = 0
        for a in range(len(ans)):
            var s = String(ans[a].strip())
            if s == "none" or s == "" or s.find("|") == -1:
                continue
            var parts = s.split("|")
            if len(parts) < 2:
                continue
            var dir = String(parts[0].strip())
            var amt = parse_amount(String(parts[1].strip()))
            if amt <= 0.0:
                continue
            count += 1
            if dir == "debit":
                total_debit += amt
            elif dir == "credit":
                total_credit += amt
        if count > 0:
            print_answer("Found approximately " + String(count) + " transactions: "
                + money(total_debit) + " out (debits) and "
                + money(total_credit) + " in (credits). "
                + "Net: " + money(total_credit - total_debit) + ".")
        else:
            print_answer("I couldn't find any transactions in your vault.")
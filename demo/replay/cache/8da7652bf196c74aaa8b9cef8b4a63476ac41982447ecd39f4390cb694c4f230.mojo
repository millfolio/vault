from vault import *

def main() raises:
    var n = 0
    var spent = 0.0
    var received = 0.0
    var files = manifest()
    for i in range(len(files)):
        progress("checking " + files[i].id)
        var txns = transactions(files[i].id)
        for t in range(len(txns)):
            ref x = txns[t]
            n += 1
            if x.direction == "debit":
                spent += x.amount
            elif x.direction == "credit":
                received += x.amount
    if n > 0:
        print_answer("You have " + String(n) + " transactions: "
            + money(spent) + " out (debits) and "
            + money(received) + " in (credits/deposits).")
    else:
        # fallback: scan all chunks and count transaction-like lines
        var count = 0
        for i in range(len(files)):
            progress("scanning chunks of " + files[i].id)
            var chunks = file_chunks(files[i].id)
            var cand = List[String]()
            for c in range(len(chunks)):
                if chunks[c].find(".") != -1:
                    cand.append(chunks[c])
            var ans = ask_local_batch(
                "Use ONLY the text provided. If it describes one or more financial"
                " transactions (purchases, payments, deposits, charges), reply with"
                " just the number of transactions you can clearly identify in the"
                " text. Otherwise reply 'none'. Do not guess or invent.", cand)
            for a in range(len(ans)):
                var s = String(ans[a].strip())
                if s != "none" and s != "":
                    var v = parse_amount(s)
                    if v > 0.0:
                        count += Int(v)
        if count > 0:
            print_answer("I found approximately " + String(count)
                + " transactions across your documents (estimated from text scanning).")
        else:
            print_answer("I couldn't find any transactions in your vault.")
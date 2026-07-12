from vault import *

def main() raises:
    var have = False
    var top_amount = 0.0
    var top_merchant = String("")
    var top_date = String("")
    var top_direction = String("")
    var files = manifest()

    # 1) EXACT path: reconcile-verified transactions
    for i in range(len(files)):
        progress("checking transactions in " + files[i].id)
        var txns = transactions(files[i].id)
        for t in range(len(txns)):
            ref x = txns[t]
            if not have or x.amount > top_amount:
                have = True
                top_amount = x.amount
                top_merchant = x.desc
                top_date = x.date
                top_direction = x.direction

    # 2) FALLBACK: scan all chunks for files with no reconciled transactions
    if not have:
        for i in range(len(files)):
            progress("scanning chunks in " + files[i].id)
            var chunks = file_chunks(files[i].id)
            var cand = List[String]()
            for c in range(len(chunks)):
                if chunks[c].find(".") != -1:
                    cand.append(chunks[c])
            if len(cand) == 0:
                continue
            var ans = ask_local_batch(
                "Use ONLY the text provided. If it contains a transaction or purchase,"
                " reply as 'MERCHANT | AMOUNT | DATE' (e.g. 'Corner Market | 42.10 | 2024-03-15')."
                " Otherwise reply 'none'. Do not guess or invent.", cand)
            for a in range(len(ans)):
                var s = String(ans[a]).strip()
                if s == "none" or s == "" or s.find("|") == -1:
                    continue
                var parts = s.split("|")
                if len(parts) < 2:
                    continue
                var amt = parse_amount(String(parts[1]).strip())
                if not have or amt > top_amount:
                    have = True
                    top_amount = amt
                    top_merchant = String(parts[0]).strip()
                    if len(parts) >= 3:
                        top_date = String(parts[2]).strip()

    if have:
        var direction_label = String("")
        if top_direction == "debit":
            direction_label = " (money out)"
        elif top_direction == "credit":
            direction_label = " (money in)"
        var date_part = String("")
        if top_date != "":
            date_part = " on " + top_date
        print_answer("Your biggest transaction was " + money(top_amount) + direction_label
            + " at/from: " + top_merchant + date_part + ".")
    else:
        print_answer("I couldn't find any transactions with amounts in your vault.")
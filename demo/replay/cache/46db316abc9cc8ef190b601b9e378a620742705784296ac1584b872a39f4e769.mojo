from vault import *

def main() raises:
    var total_spent = 0.0
    var total_received = 0.0
    var n_debits = 0
    var n_credits = 0
    var found_any = False

    var files = manifest()

    # First pass: try reconcile-verified transactions
    for i in range(len(files)):
        progress("checking transactions in " + files[i].alias)
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            found_any = True
            if x.direction == "debit":
                total_spent += x.amount
                n_debits += 1
            elif x.direction == "credit":
                total_received += x.amount
                n_credits += 1

    # Fallback: if no verified transactions found, scan all chunks
    if not found_any:
        for i in range(len(files)):
            progress("scanning chunks of " + files[i].alias)
            var chunks = file_chunks(files[i].alias)
            var cand = List[String]()
            for c in range(len(chunks)):
                if chunks[c].find(".") != -1:
                    cand.append(chunks[c])
            if len(cand) == 0:
                continue
            var answers = ask_local_batch(
                "Use ONLY the text provided. If it contains a purchase, payment, or debit transaction, "
                "reply with just the amount as a plain number (e.g. 42.10). "
                "If it is a deposit, credit, or money received, reply 'credit:' followed by the amount (e.g. credit:100.00). "
                "Otherwise reply 'none'. Do not guess or invent.", cand)
            for a in range(len(answers)):
                var s = String(answers[a].strip())
                if s == "none" or s == "":
                    continue
                if s.startswith("credit:"):
                    var parts = s.split(":")
                    if len(parts) >= 2:
                        var amt = parse_amount(String(parts[1].strip()))
                        if amt > 0.0:
                            total_received += amt
                            n_credits += 1
                            found_any = True
                else:
                    var amt = parse_amount(s)
                    if amt > 0.0:
                        total_spent += amt
                        n_debits += 1
                        found_any = True

    if found_any:
        var msg = String("You spent ") + money(total_spent) + " across " + String(n_debits) + " debit/purchase transaction(s)."
        if n_credits > 0:
            msg = msg + " You also received " + money(total_received) + " across " + String(n_credits) + " credit/deposit transaction(s)."
        print_answer(msg)
    else:
        print_answer("I couldn't find any spending transactions in your vault.")
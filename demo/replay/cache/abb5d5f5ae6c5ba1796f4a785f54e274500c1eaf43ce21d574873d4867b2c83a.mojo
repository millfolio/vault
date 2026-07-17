from vault import *

def main() raises:
    var files = manifest()
    var spent = 0.0
    var received = 0.0
    var n_spent = 0
    var n_received = 0
    var lo = String("")
    var hi = String("")

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.date != "":
                if lo == "" or x.date < lo:
                    lo = x.date
                if hi == "" or x.date > hi:
                    hi = x.date
            if x.direction == "debit":
                # exclude pure transfers (money moved between accounts, not purchases)
                var is_transfer = False
                for g in range(len(x.tags)):
                    if x.tags[g] == "transfers":
                        is_transfer = True
                        break
                if not is_transfer:
                    spent += x.amount
                    n_spent += 1
            elif x.direction == "credit":
                var is_transfer = False
                for g in range(len(x.tags)):
                    if x.tags[g] == "transfers":
                        is_transfer = True
                        break
                if not is_transfer:
                    received += x.amount
                    n_received += 1

    if n_spent == 0 and n_received == 0:
        print_answer("I couldn't find any transactions in your vault.")
        return

    var date_range = String("")
    if lo != "" and hi != "":
        date_range = " (from " + lo + " to " + hi + ")"

    result_text("You spent " + money(spent) + " across " + String(n_spent)
        + " purchases and received " + money(received) + " across "
        + String(n_received) + " credits" + date_range + ".")

    kpi("Total spent", money_val(spent))
    kpi("Total received", money_val(received))
    kpi("Purchase transactions", count(n_spent))
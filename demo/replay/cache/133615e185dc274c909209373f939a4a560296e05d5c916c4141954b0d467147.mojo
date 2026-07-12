from vault import *

def main() raises:
    var files = manifest()
    var n = 0
    var spent = 0.0
    var received = 0.0

    for i in range(len(files)):
        progress("scanning " + String(i + 1) + "/" + String(len(files)) + " (" + files[i].alias + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            n += 1
            if x.direction == "debit":
                spent += x.amount
            elif x.direction == "credit":
                received += x.amount

    if n > 0:
        result_text("You have " + String(n) + " transactions total: "
            + money(spent) + " out (debits) and "
            + money(received) + " in (credits/deposits).")
        kpi("Total spent (debits)", money_val(spent))
        kpi("Total received (credits)", money_val(received))
        kpi("Transaction count", count(n))
    else:
        print_answer("I couldn't find any verified transactions in your vault.")
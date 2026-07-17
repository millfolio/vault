from vault import *

def main() raises:
    var files = manifest()
    var total_n = 0
    var spent = 0.0
    var received = 0.0
    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            total_n += 1
            if x.direction == "debit":
                spent += x.amount
            elif x.direction == "credit":
                received += x.amount
    if total_n > 0:
        result_text("You have " + String(total_n) + " transactions in total: "
            + money(spent) + " out (debits) and " + money(received) + " in (credits/deposits).")
        kpi("Total transactions", count(total_n))
        kpi("Total debits (out)", money_val(spent))
        kpi("Total credits (in)", money_val(received))
    else:
        print_answer("I couldn't find any verified transactions in your vault.")
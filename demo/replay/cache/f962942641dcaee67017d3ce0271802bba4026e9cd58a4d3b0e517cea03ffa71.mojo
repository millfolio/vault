from vault import *
def main() raises:
    var files = manifest()
    var total_n = 0
    var spent = 0.0
    var received = 0.0
    for i in range(len(files)):
        progress("scanning " + String(i+1) + "/" + String(len(files)) + " (" + files[i].alias + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            total_n += 1
            if x.direction == "debit":
                spent += x.amount
            elif x.direction == "credit":
                received += x.amount
    if total_n > 0:
        result_text("You have " + String(total_n) + " transactions in your vault: "
            + money(spent) + " out (debits) and " + money(received) + " in (credits).")
        kpi("Total transactions", count(total_n))
        kpi("Total debits", money_val(spent))
        kpi("Total credits", money_val(received))
    else:
        result_text("I couldn't find any verified transactions in your vault.")
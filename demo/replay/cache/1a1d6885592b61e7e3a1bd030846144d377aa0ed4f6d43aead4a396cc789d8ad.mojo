from vault import *

def main() raises:
    var n = 0
    var spent = 0.0
    var received = 0.0
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            n += 1
            if x.direction == "debit":
                spent += x.amount
            elif x.direction == "credit":
                received += x.amount
    if n > 0:
        print_answer("You have " + String(n) + " transactions total: "
            + money(spent) + " out (debits/spending) and "
            + money(received) + " in (credits/deposits). "
            + "Net: " + money(received - spent) + ".")
    else:
        print_answer("I couldn't find any verified transactions in your vault.")
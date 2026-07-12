from vault import *

def main() raises:
    var files = manifest()
    var states = List[String]()
    var totals = List[Float64]()

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction != "debit":
                continue
            if x.state == "":
                continue
            var found = False
            for s in range(len(states)):
                if states[s] == x.state:
                    totals[s] += x.amount
                    found = True
                    break
            if not found:
                states.append(x.state)
                totals.append(x.amount)

    if len(states) == 0:
        print_answer("I couldn't find any transactions with a US state on them in your vault.")
        return

    var grand = 0.0
    for s in range(len(totals)):
        grand += totals[s]

    # Sort descending by total (selection sort)
    for a in range(len(totals)):
        var best = a
        for b in range(a + 1, len(totals)):
            if totals[b] > totals[best]:
                best = b
        if best != a:
            var tv = totals[a]
            totals[a] = totals[best]
            totals[best] = tv
            var sv = states[a]
            states[a] = states[best]
            states[best] = sv

    result_text("You spent " + money(grand) + " across " + String(len(states)) + " states. Your top state is " + states[0] + " at " + money(totals[0]) + ".")

    var gm = geo_map("Spending by state", "state")
    for s in range(len(states)):
        _ = gm.place(states[s], money_val(totals[s]))
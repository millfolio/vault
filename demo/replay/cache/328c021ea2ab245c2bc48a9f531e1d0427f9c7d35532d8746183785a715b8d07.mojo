from vault import *

def main() raises:
    var files = manifest()
    var state_codes = List[String]()
    var state_totals = List[Float64]()

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction != "debit":
                continue
            if x.state == "" or x.country != "USA":
                continue
            var found = False
            for s in range(len(state_codes)):
                if state_codes[s] == x.state:
                    state_totals[s] += x.amount
                    found = True
                    break
            if not found:
                state_codes.append(x.state)
                state_totals.append(x.amount)

    if len(state_codes) == 0:
        print_answer("I couldn't find any US state-tagged spending transactions in your vault.")
        return

    # selection sort descending
    for a in range(len(state_totals)):
        var best = a
        for b in range(a + 1, len(state_totals)):
            if state_totals[b] > state_totals[best]:
                best = b
        if best != a:
            var tv = state_totals[a]
            state_totals[a] = state_totals[best]
            state_totals[best] = tv
            var nv = state_codes[a]
            state_codes[a] = state_codes[best]
            state_codes[best] = nv

    result_text("Your top state for spending is " + state_codes[0] + " at " + money(state_totals[0]) + ".")

    var tbl = table(["State", "Total Spent"])
    var top = len(state_codes)
    if top > 10:
        top = 10
    for r in range(top):
        _ = tbl.row([state_codes[r], money_val(state_totals[r])])

    var gm = geo_map("Spending by US state", "state")
    for c in range(len(state_codes)):
        _ = gm.place(state_codes[c], money_val(state_totals[c]))
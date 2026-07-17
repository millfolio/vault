from vault import *

def main() raises:
    var files = manifest()
    var cutoff = months_ago(6)

    # Collect all debit transactions in the last 6 months
    # Key: (merchant, month "YYYY-MM") -> amount
    var merchants = List[String]()
    var months_list = List[String]()
    var amounts = List[Float64]()
    var tx_counts = List[Int]()  # per merchant total tx count

    # Also track per-merchant totals for top-10
    var merch_names = List[String]()
    var merch_totals = List[Float64]()
    var merch_counts = List[Int]()

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction != "debit":
                continue
            if x.date == "" or x.date < cutoff:
                continue
            var key_merch = x.merchant if x.merchant != "" else x.desc
            var p = x.date.split("-")
            if len(p) < 2:
                continue
            var mk = String(p[0]) + "-" + String(p[1])

            # Update (merchant, month) bucket
            var found_cell = False
            for c in range(len(merchants)):
                if merchants[c] == key_merch and months_list[c] == mk:
                    amounts[c] += x.amount
                    found_cell = True
                    break
            if not found_cell:
                merchants.append(key_merch)
                months_list.append(mk)
                amounts.append(x.amount)

            # Update per-merchant total + count
            var found_m = False
            for m in range(len(merch_names)):
                if merch_names[m] == key_merch:
                    merch_totals[m] += x.amount
                    merch_counts[m] += 1
                    found_m = True
                    break
            if not found_m:
                merch_names.append(key_merch)
                merch_totals.append(x.amount)
                merch_counts.append(1)

    # Filter to merchants with more than 2 transactions
    var qualified = List[String]()
    for m in range(len(merch_names)):
        if merch_counts[m] > 2:
            qualified.append(merch_names[m])

    if len(qualified) == 0:
        print_answer("No merchants had more than 2 transactions in the last 6 months.")
        return

    # Collect all unique months seen (sorted)
    var unique_months = List[String]()
    for c in range(len(months_list)):
        var mk = months_list[c]
        var found = False
        for u in range(len(unique_months)):
            if unique_months[u] == mk:
                found = True
                break
        if not found:
            unique_months.append(mk)

    # Sort unique_months ascending (ISO YYYY-MM sorts lexically)
    for a in range(len(unique_months)):
        for b in range(a + 1, len(unique_months)):
            if unique_months[b] < unique_months[a]:
                var tmp = unique_months[a]
                unique_months[a] = unique_months[b]
                unique_months[b] = tmp

    # Build table headers: Merchant + one col per month
    var headers = List[String]()
    headers.append("Merchant")
    for u in range(len(unique_months)):
        headers.append(unique_months[u])
    headers.append("Total")

    var tbl = table(headers)

    # For each qualified merchant, build a row
    for q in range(len(qualified)):
        var merch = qualified[q]
        var row_vals = List[String]()
        row_vals.append(merch)
        var merch_total = 0.0
        for u in range(len(unique_months)):
            var mk = unique_months[u]
            var cell_amt = 0.0
            for c in range(len(merchants)):
                if merchants[c] == merch and months_list[c] == mk:
                    cell_amt += amounts[c]
                    break
            merch_total += cell_amt
            if cell_amt > 0.0:
                row_vals.append(money(cell_amt))
            else:
                row_vals.append("-")
        row_vals.append(money(merch_total))
        _ = tbl.row(row_vals)

    # Sort qualified merchants by total spend descending (for top-10 line graphs)
    var q_totals = List[Float64]()
    for q in range(len(qualified)):
        var merch = qualified[q]
        for m in range(len(merch_names)):
            if merch_names[m] == merch:
                q_totals.append(merch_totals[m])
                break

    # Selection sort descending
    for a in range(len(qualified)):
        var best = a
        for b in range(a + 1, len(qualified)):
            if q_totals[b] > q_totals[best]:
                best = b
        if best != a:
            var tv = q_totals[a]
            q_totals[a] = q_totals[best]
            q_totals[best] = tv
            var nv = qualified[a]
            qualified[a] = qualified[best]
            qualified[best] = nv

    # Emit line graphs for top 10 qualified merchants
    var top_n = len(qualified)
    if top_n > 10:
        top_n = 10

    for q in range(top_n):
        var merch = qualified[q]
        var s = series(merch + " - monthly spending", "time")
        for u in range(len(unique_months)):
            var mk = unique_months[u]
            var cell_amt = 0.0
            for c in range(len(merchants)):
                if merchants[c] == merch and months_list[c] == mk:
                    cell_amt += amounts[c]
                    break
            _ = s.point(mk + "-01", money_val(cell_amt))

    result_text("Here is your monthly spending per merchant (last 6 months, merchants with more than 2 transactions). Line graphs show the top " + String(top_n) + " merchants by total spend.")
from vault import *

def main() raises:
    var files = manifest()
    var cutoff = months_ago(6)

    # Collect all debit transactions in the last 6 months
    # Key: (merchant, "YYYY-MM") -> total amount
    # Also track per-merchant transaction count and total for top-10 selection

    var merch_month_keys = List[String]()   # "MERCHANT|||YYYY-MM"
    var merch_month_totals = List[Float64]()

    var merch_keys = List[String]()         # unique merchants
    var merch_totals = List[Float64]()      # total per merchant
    var merch_counts = List[Int]()          # transaction count per merchant

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction != "debit":
                continue
            if x.date == "" or x.date < cutoff:
                continue
            var parts = x.date.split("-")
            if len(parts) < 2:
                continue
            var month_key = String(parts[0]) + "-" + String(parts[1])
            var merch = x.merchant if x.merchant != "" else x.desc
            var mm_key = merch + "|||" + month_key

            # Update merchant-month totals
            var found_mm = False
            for k in range(len(merch_month_keys)):
                if merch_month_keys[k] == mm_key:
                    merch_month_totals[k] += x.amount
                    found_mm = True
                    break
            if not found_mm:
                merch_month_keys.append(mm_key)
                merch_month_totals.append(x.amount)

            # Update merchant totals and counts
            var found_m = False
            for k in range(len(merch_keys)):
                if merch_keys[k] == merch:
                    merch_totals[k] += x.amount
                    merch_counts[k] += 1
                    found_m = True
                    break
            if not found_m:
                merch_keys.append(merch)
                merch_totals.append(x.amount)
                merch_counts.append(1)

    # Filter merchants with more than 2 transactions
    var filtered_merch = List[String]()
    var filtered_totals = List[Float64]()
    for m in range(len(merch_keys)):
        if merch_counts[m] > 2:
            filtered_merch.append(merch_keys[m])
            filtered_totals.append(merch_totals[m])

    if len(filtered_merch) == 0:
        print_answer("I couldn't find any merchants with more than 2 transactions in the last 6 months.")
        return

    # Collect all unique months seen
    var all_months = List[String]()
    for k in range(len(merch_month_keys)):
        var sep_idx = merch_month_keys[k].find("|||")
        if sep_idx == -1:
            continue
        var key_parts = merch_month_keys[k].split("|||")
        if len(key_parts) < 2:
            continue
        var mo = String(key_parts[1])
        var found = False
        for mm in range(len(all_months)):
            if all_months[mm] == mo:
                found = True
                break
        if not found:
            all_months.append(mo)

    # Sort months ascending (ISO strings compare lexically)
    for a in range(len(all_months)):
        for b in range(a + 1, len(all_months)):
            if all_months[b] < all_months[a]:
                var tmp = all_months[a]
                all_months[a] = all_months[b]
                all_months[b] = tmp

    # Build table header: Merchant + one column per month
    var headers = List[String]()
    headers.append("Merchant")
    for mm in range(len(all_months)):
        headers.append(all_months[mm])
    var tbl = table(headers)

    # Sort filtered merchants by total descending for the table
    for a in range(len(filtered_totals)):
        var best = a
        for b in range(a + 1, len(filtered_totals)):
            if filtered_totals[b] > filtered_totals[best]:
                best = b
        if best != a:
            var tv = filtered_totals[a]
            filtered_totals[a] = filtered_totals[best]
            filtered_totals[best] = tv
            var nv = filtered_merch[a]
            filtered_merch[a] = filtered_merch[best]
            filtered_merch[best] = nv

    for m in range(len(filtered_merch)):
        var merch = filtered_merch[m]
        var row_vals = List[String]()
        row_vals.append(merch)
        for mm in range(len(all_months)):
            var mo = all_months[mm]
            var mm_key = merch + "|||" + mo
            var amt = 0.0
            for k in range(len(merch_month_keys)):
                if merch_month_keys[k] == mm_key:
                    amt = merch_month_totals[k]
                    break
            row_vals.append(money(amt) if amt > 0.0 else "-")
        _ = tbl.row(row_vals)

    # Top 10 merchants by total (already sorted descending)
    var top_n = len(filtered_merch)
    if top_n > 10:
        top_n = 10

    # Emit one time-series per top merchant
    for m in range(top_n):
        var merch = filtered_merch[m]
        var s = series(merch, "time")
        for mm in range(len(all_months)):
            var mo = all_months[mm]
            var mm_key = merch + "|||" + mo
            var amt = 0.0
            for k in range(len(merch_month_keys)):
                if merch_month_keys[k] == mm_key:
                    amt = merch_month_totals[k]
                    break
            _ = s.point(mo + "-01", money_val(amt))

    result_text("Here is your monthly spending per merchant (merchants with more than 2 transactions) over the last 6 months, plus line graphs for the top " + String(top_n) + " merchants by total spend.")
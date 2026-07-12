from vault import *

def main() raises:
    var files = manifest()
    var cutoff = months_ago(6)

    # Collect all debit transactions in the last 6 months
    var merchant_names = List[String]()
    var merchant_totals = List[Float64]()
    var merchant_counts = List[Int]()

    # For weekly breakdown per merchant: store (merchant, week_key, amount)
    var week_merchant = List[String]()
    var week_key = List[String]()
    var week_amount = List[Float64]()

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction != "debit" or x.date == "" or x.date < cutoff:
                continue
            var key = x.merchant if x.merchant != "" else x.desc

            # Compute ISO week key: "YYYY-Www" from date
            # Parse date parts
            var parts = x.date.split("-")
            if len(parts) < 3:
                continue
            var yr = Int(atof(String(parts[0])))
            var mo = Int(atof(String(parts[1])))
            var dy = Int(atof(String(parts[2])))

            # Simple week number: day of year / 7 + 1
            var days_in_month = List[Int]()
            days_in_month.append(0)
            days_in_month.append(31)
            var feb = 28
            if (yr % 4 == 0 and yr % 100 != 0) or (yr % 400 == 0):
                feb = 29
            days_in_month.append(feb)
            days_in_month.append(31)
            days_in_month.append(30)
            days_in_month.append(31)
            days_in_month.append(30)
            days_in_month.append(31)
            days_in_month.append(31)
            days_in_month.append(30)
            days_in_month.append(31)
            days_in_month.append(30)
            days_in_month.append(31)
            var doy = dy
            for mm in range(1, mo):
                doy += days_in_month[mm]
            var wk = (doy - 1) // 7 + 1
            var wk_str = String(yr) + "-W"
            if wk < 10:
                wk_str = wk_str + "0"
            wk_str = wk_str + String(wk)

            # Update merchant totals
            var found = False
            for m in range(len(merchant_names)):
                if merchant_names[m] == key:
                    merchant_totals[m] += x.amount
                    merchant_counts[m] += 1
                    found = True
                    break
            if not found:
                merchant_names.append(key)
                merchant_totals.append(x.amount)
                merchant_counts.append(1)

            # Store weekly entry
            week_merchant.append(key)
            week_key.append(wk_str)
            week_amount.append(x.amount)

    # Filter merchants with more than 2 transactions
    var filtered_names = List[String]()
    var filtered_totals = List[Float64]()
    for m in range(len(merchant_names)):
        if merchant_counts[m] > 2:
            filtered_names.append(merchant_names[m])
            filtered_totals.append(merchant_totals[m])

    if len(filtered_names) == 0:
        print_answer("I couldn't find any merchants with more than 2 transactions in the last 6 months.")
        return

    # Sort filtered merchants by total descending
    for a in range(len(filtered_totals)):
        var best = a
        for b in range(a + 1, len(filtered_totals)):
            if filtered_totals[b] > filtered_totals[best]:
                best = b
        if best != a:
            var tv = filtered_totals[a]
            filtered_totals[a] = filtered_totals[best]
            filtered_totals[best] = tv
            var nv = filtered_names[a]
            filtered_names[a] = filtered_names[best]
            filtered_names[best] = nv

    # Build the weekly amount table for filtered merchants
    # Collect all unique weeks across filtered merchants
    var all_weeks = List[String]()
    for w in range(len(week_merchant)):
        var is_filtered = False
        for m in range(len(filtered_names)):
            if week_merchant[w] == filtered_names[m]:
                is_filtered = True
                break
        if not is_filtered:
            continue
        var wk = week_key[w]
        var wfound = False
        for aw in range(len(all_weeks)):
            if all_weeks[aw] == wk:
                wfound = True
                break
        if not wfound:
            all_weeks.append(wk)

    # Sort weeks ascending (string compare works for YYYY-Www)
    for a in range(len(all_weeks)):
        var best = a
        for b in range(a + 1, len(all_weeks)):
            if all_weeks[b] < all_weeks[best]:
                best = b
        if best != a:
            var tmp = all_weeks[a]
            all_weeks[a] = all_weeks[best]
            all_weeks[best] = tmp

    # Aggregate weekly totals per filtered merchant
    # merchant x week matrix stored as flat lists
    var mw_merchants = List[String]()
    var mw_weeks = List[String]()
    var mw_totals = List[Float64]()

    for m in range(len(filtered_names)):
        for aw in range(len(all_weeks)):
            mw_merchants.append(filtered_names[m])
            mw_weeks.append(all_weeks[aw])
            mw_totals.append(0.0)

    for w in range(len(week_merchant)):
        var mn = week_merchant[w]
        var wn = week_key[w]
        var amt = week_amount[w]
        # Find row
        for r in range(len(mw_merchants)):
            if mw_merchants[r] == mn and mw_weeks[r] == wn:
                mw_totals[r] += amt
                break

    # Build table headers: Merchant | Week | Amount
    result_text("Weekly spending per merchant (last 6 months, merchants with >2 transactions). Top 10 shown in line graphs below.")

    var tbl = table(["Merchant", "Week", "Amount"])
    for m in range(len(filtered_names)):
        for aw in range(len(all_weeks)):
            # Find the total for this merchant/week
            var amt = 0.0
            for r in range(len(mw_merchants)):
                if mw_merchants[r] == filtered_names[m] and mw_weeks[r] == all_weeks[aw]:
                    amt = mw_totals[r]
                    break
            if amt > 0.0:
                _ = tbl.row([filtered_names[m], all_weeks[aw], money_val(amt)])

    # Emit line graphs for top 10 merchants
    var top10 = len(filtered_names)
    if top10 > 10:
        top10 = 10

    for m in range(top10):
        var s = series(filtered_names[m], "time")
        for aw in range(len(all_weeks)):
            var amt = 0.0
            for r in range(len(mw_merchants)):
                if mw_merchants[r] == filtered_names[m] and mw_weeks[r] == all_weeks[aw]:
                    amt = mw_totals[r]
                    break
            # Use first day of the week as x-axis point (approximate with week key)
            # Convert YYYY-Www to a date string for the series (use YYYY-Www-1 approximation)
            # We'll use the week key directly as a label for the series point
            _ = s.point(all_weeks[aw] + "-1", money_val(amt))
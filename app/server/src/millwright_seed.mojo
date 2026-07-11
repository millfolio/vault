"""millwright_seed — the CURATED STARTER BOARD (design: designs/MILLWRIGHT.md v2 §1).

Pure DATA, no logic: the seed spec, the four curated programs (compile-tested
against the vault package — one per result-block kind: kpi / time series /
table / pie), and their canned PREVIEW results (fictional example numbers —
marked "preview": true so the Board renders them as examples until the user
refreshes them over their own vault). Consumed by handlers_millwright's
first-run seeding; unit-covered by test/millwright_seed_test.mojo (the spec
must pass validate_spec once its program docs exist; every result must parse).
"""

comptime SEED_AUTHOR = "millfolio"
comptime SEED_MESSAGE = "starter board"

comptime SEED_SPEC = """{"v":1,"kind":"dashboard","widgets":[{"id":"w-starter-30days","title":"Spent, last 30 days","q":"How much did I spend in the last 30 days?","w":1,"h":1},{"id":"w-starter-bymonth","title":"Spending by month","q":"What is my spending by month over the last 6 months?","w":2,"h":1},{"id":"w-starter-merchants","title":"Top merchants","q":"Who are my top 5 merchants by spending in the last 3 months?","w":1,"h":1},{"id":"w-starter-categories","title":"Spending by category","q":"What share of my spending last month went to each category?","w":2,"h":1}],"layout":{"cols":3,"order":["w-starter-30days","w-starter-bymonth","w-starter-merchants","w-starter-categories"]}}"""
"""The starter spec — version 1 of a fresh install's dashboard."""

comptime SEED_PROGRAM_30DAYS = """from vault import *


def main() raises:
    var total = 0.0
    var n = 0
    var cutoff = days_ago(30)
    for t in spending():
        if t.date >= cutoff:
            total += t.amount
            n += 1
    result_text(
        "You spent "
        + money(total)
        + " across "
        + String(n)
        + " purchases in the last 30 days."
    )
    kpi("Spent, last 30 days", money_val(total))
    kpi("Purchases", count(n))
"""

comptime SEED_RESULT_30DAYS = """{"v":1,"text":"You spent $1,482.55 across 47 purchases in the last 30 days.","data":[{"kind":"kpi","label":"Spent, last 30 days","value":{"type":"money","raw":1482.55,"text":"$1,482.55"}},{"kind":"kpi","label":"Purchases","value":{"type":"count","raw":47,"text":"47"}}]}"""

comptime SEED_PROGRAM_BYMONTH = """from vault import *


def main() raises:
    var cutoff = months_ago(6)
    var months = List[String]()
    var totals = List[Float64]()
    for t in spending():
        if t.date < cutoff or t.date == "":
            continue
        var parts = t.date.split("-")
        if len(parts) < 2:
            continue
        var key = String(parts[0]) + "-" + String(parts[1]) + "-01"
        var found = False
        for i in range(len(months)):
            if months[i] == key:
                totals[i] += t.amount
                found = True
                break
        if not found:
            months.append(key)
            totals.append(t.amount)
    # sort by month (ISO strings compare correctly)
    for i in range(len(months)):
        for j in range(i + 1, len(months)):
            if months[j] < months[i]:
                var tm = months[i]
                months[i] = months[j]
                months[j] = tm
                var tt = totals[i]
                totals[i] = totals[j]
                totals[j] = tt
    var s = series("Spending by month", "time")
    var grand = 0.0
    for i in range(len(months)):
        s.point(months[i], money_val(totals[i]))
        grand += totals[i]
    result_text(
        "You spent " + money(grand) + " over the last 6 months."
    )
"""

comptime SEED_RESULT_BYMONTH = """{"v":1,"text":"You spent $9,301.22 over the last 6 months.","data":[{"kind":"series","seriesKind":"time","title":"Spending by month","x":{"type":"date","values":["2026-02-01","2026-03-01","2026-04-01","2026-05-01","2026-06-01","2026-07-01"]},"y":{"type":"money","raw":[1610.4,1444.02,1721.88,1355.15,1687.22,1482.55],"text":["$1,610.40","$1,444.02","$1,721.88","$1,355.15","$1,687.22","$1,482.55"]}}]}"""

comptime SEED_PROGRAM_MERCHANTS = """from vault import *


def main() raises:
    var cutoff = months_ago(3)
    var names = List[String]()
    var totals = List[Float64]()
    for t in spending():
        if t.date < cutoff or t.merchant == "":
            continue
        var found = False
        for i in range(len(names)):
            if names[i] == t.merchant:
                totals[i] += t.amount
                found = True
                break
        if not found:
            names.append(t.merchant.copy())
            totals.append(t.amount)
    # sort descending by total
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            if totals[j] > totals[i]:
                var tt = totals[i]
                totals[i] = totals[j]
                totals[j] = tt
                var tn = names[i]
                names[i] = names[j]
                names[j] = tn
    var tbl = table(["Merchant", "Spent"])
    var top = 5 if len(names) > 5 else len(names)
    for i in range(top):
        _ = tbl.row([names[i], money_val(totals[i])])
    result_text(
        "Your top " + String(top) + " merchants over the last 3 months."
    )
"""

comptime SEED_RESULT_MERCHANTS = """{"v":1,"text":"Your top 5 merchants over the last 3 months.","data":[{"kind":"table","headers":["Merchant","Spent"],"rows":[[{"type":"text","value":"WHOLE FOODS"},{"type":"money","raw":612.4,"text":"$612.40"}],[{"type":"text","value":"COSTCO"},{"type":"money","raw":498.1,"text":"$498.10"}],[{"type":"text","value":"SHELL"},{"type":"money","raw":301.77,"text":"$301.77"}],[{"type":"text","value":"TRADER JOES"},{"type":"money","raw":264.02,"text":"$264.02"}],[{"type":"text","value":"CHIPOTLE"},{"type":"money","raw":187.6,"text":"$187.60"}]]}]}"""

comptime SEED_PROGRAM_CATEGORIES = """from vault import *


def main() raises:
    var cutoff = months_ago(1)
    var tags = List[String]()
    var totals = List[Float64]()
    for t in spending():
        if t.date < cutoff:
            continue
        var tag = String("other")
        if len(t.tags) > 0:
            tag = t.tags[0].copy()
        var found = False
        for i in range(len(tags)):
            if tags[i] == tag:
                totals[i] += t.amount
                found = True
                break
        if not found:
            tags.append(tag^)
            totals.append(t.amount)
    var p = pie("Spending by category, last month")
    var grand = 0.0
    for i in range(len(tags)):
        p.slice(tags[i], money_val(totals[i]))
        grand += totals[i]
    result_text(
        "You spent " + money(grand) + " in the last month, split by category."
    )
"""

comptime SEED_RESULT_CATEGORIES = """{"v":1,"text":"You spent $1,482.55 in the last month, split by category.","data":[{"kind":"pie","title":"Spending by category, last month","slices":[{"label":"groceries","value":{"type":"money","raw":542.1,"text":"$542.10"}},{"label":"restaurant","value":{"type":"money","raw":318.4,"text":"$318.40"}},{"label":"travel","value":{"type":"money","raw":289.5,"text":"$289.50"}},{"label":"phone","value":{"type":"money","raw":95.0,"text":"$95.00"}},{"label":"other","value":{"type":"money","raw":237.55,"text":"$237.55"}}]}]}"""


def seed_widget_ids() -> List[String]:
    """The seed widget ids, in board order (parallel to programs/results)."""
    return [
        String("w-starter-30days"),
        String("w-starter-bymonth"),
        String("w-starter-merchants"),
        String("w-starter-categories"),
    ]


def seed_programs() -> List[String]:
    """The curated programs, parallel to `seed_widget_ids()`."""
    return [
        String(SEED_PROGRAM_30DAYS),
        String(SEED_PROGRAM_BYMONTH),
        String(SEED_PROGRAM_MERCHANTS),
        String(SEED_PROGRAM_CATEGORIES),
    ]


def seed_results() -> List[String]:
    """The canned preview result-specs, parallel to `seed_widget_ids()`."""
    return [
        String(SEED_RESULT_30DAYS),
        String(SEED_RESULT_BYMONTH),
        String(SEED_RESULT_MERCHANTS),
        String(SEED_RESULT_CATEGORIES),
    ]

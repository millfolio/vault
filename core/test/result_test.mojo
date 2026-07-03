"""Result-test — the declarative RESULT SPEC serializer (COMPUTE_VS_RENDER Phase 1).

Pins the `v:1` wire contract the presenter consumes:

  - TEXT-ONLY parity: a spec with only `result_text` carries `"text"` and NO
    `"data"` → renders exactly as today.
  - the TYPED-MONEY INVARIANT: money crosses as
    `{"type":"money","raw":<float>,"text":"<money()>"}` — never a bare float,
    never only a formatted string.
  - `count`/`date` tag their type; table cells + series columns are typed;
    an optional `hint` attaches to the series.

Builds like a generated program (`from vault import *`, the vault include set) —
`pixi run test-result`. Pure at RUNTIME: it only calls `money()`/the builders (no
search/ask_local), so it never dlopens flare/lancedb.
"""

from vault import *


def _expect(name: String, cond: Bool, prev: Bool) -> Bool:
    print("[" + ("PASS" if cond else "FAIL") + "]", name)
    return prev and cond


def _has(hay: String, needle: String) -> Bool:
    return hay.find(needle) != -1


def main() raises:
    var ok = True

    # ── Phase A — text-only parity (no data builders) ───────────────────────────
    result_text("You spent $4,210.55 across 128 transactions.")
    var a = result_json()
    ok = _expect("text-only: versioned v:1", _has(a, '"v":1'), ok)
    ok = _expect(
        "text-only: carries the narrative",
        _has(a, '"text":"You spent $4,210.55 across 128 transactions."'),
        ok,
    )
    ok = _expect("text-only: NO data block", not _has(a, '"data"'), ok)

    # ── Phase B — typed data blocks ─────────────────────────────────────────────
    kpi("Total spent", money_val(1234.56))
    kpi("Transactions", count(3))
    var t = table(["Merchant", "Spent"])
    _ = t.row(["Coffee", money_val(12.50)])
    _ = t.row(["Rent", money_val(2000.0)])
    var s = series("Spending by month", "time")
    _ = s.point("2026-01-01", money_val(1203.10))
    _ = s.point("2026-02-01", money_val(980.44))
    hint("line")
    var b = result_json()

    # typed-money invariant: raw Float64 + the exact money() string, tagged.
    ok = _expect(
        "money is typed {type,raw,text}",
        _has(b, '{"type":"money","raw":1234.56,"text":"$1,234.56"}'),
        ok,
    )
    ok = _expect(
        "money text is the money() display, not a raw float",
        _has(b, '"text":"$1,234.56"') and not _has(b, "1234.5600000"),
        ok,
    )
    # count/date tag their type.
    ok = _expect(
        "count is typed {type,raw,text}",
        _has(b, '{"type":"count","raw":3,"text":"3"}'),
        ok,
    )
    # kpi / table / series blocks all present, in order.
    ok = _expect(
        "kpi block present", _has(b, '{"kind":"kpi","label":"Total spent"'), ok
    )
    ok = _expect(
        "table block present with headers",
        _has(b, '{"kind":"table","headers":["Merchant","Spent"]'),
        ok,
    )
    # a bare string cell becomes a typed TEXT cell.
    ok = _expect(
        "bare string row cell → typed text",
        _has(b, '{"type":"text","value":"Coffee"}'),
        ok,
    )
    # series: typed columns (x date, y money raw+text) + the optional hint.
    ok = _expect(
        "series present, time kind",
        _has(b, '{"kind":"series","seriesKind":"time"'),
        ok,
    )
    ok = _expect(
        "series x is a typed date column",
        _has(b, '"x":{"type":"date","values":["2026-01-01","2026-02-01"]}'),
        ok,
    )
    ok = _expect(
        "series y is a typed money column (raw + text)",
        _has(
            b,
            '"y":{"type":"money","raw":[1203.1,980.44],"text":["$1,203.10","$980.44"]}',
        ),
        ok,
    )
    ok = _expect("hint attaches to the series", _has(b, '"hint":"line"'), ok)
    # Phase B still carries the narrative + is still v:1.
    ok = _expect(
        "still v:1 with data", _has(b, '"v":1') and _has(b, '"data":['), ok
    )

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("result-test failed")

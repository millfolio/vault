"""Vault.result — the declarative RESULT SPEC a generated program emits for rich
output (COMPUTE_VS_RENDER.md, Phase 1).

The generated program stays platform-agnostic: instead of drawing anything, it
COMPUTES typed result DATA and appends it to a per-run result buffer through the
thin builders here. The runtime serializes that buffer to a versioned JSON spec
and emits it out-of-band on a `RESULT_SENTINEL`-prefixed line (the same channel
`progress()`/`_stat()` ride — see tools.mojo). A deterministic PRESENTER in the
client picks the visualization from the data's shape; the program never emits
markup, so the sandbox's "no markup out" property is preserved — every string
that crosses the seam is JSON-escaped DATA the client escapes again.

Builders (all part of `from vault import *`):

    result_text("You spent $4,210.55 across 128 transactions.")  # the narrative
    kpi("Total spent", money_val(4210.55))                       # a scalar tile
    var t = table(["Merchant", "Spent"])                         # a labeled table
    t.row(["Whole Foods", money_val(812.40)])
    var s = series("Spending by month", "time")                  # a time/category series
    s.point("2026-01-01", money_val(1203.10))
    hint("line")                                                 # OPTIONAL nudge

TYPED-MONEY INVARIANT (the single most important payload rule): a money value
crosses the seam as `{"type":"money","raw":<float>,"text":"<money()>"}` — NEVER a
bare float, NEVER only a formatted string. `raw` drives axes/aggregation; `text`
is the exact `money()` display. `count`/`date` likewise tag their type so the
presenter never guesses from a formatted string.

BACKWARD-COMPATIBLE: a program that only calls the existing `print_answer` (or
`result_text`) with no data builders emits either no spec at all (print_answer) or
a `{"v":1,"text":…}` spec with no `"data"` — either way it renders exactly as
today (text bubble). The presenter falls back to text-only on an unknown `"v"`.
"""

from std.ffi import external_call, c_char
from std.ffi import _Global

from vault.tools.tools import money


# The RESULT-line sentinel — one serialized spec per run rides a
# `RESULT_SENTINEL + <json> + "\n"` line on fd 1 (unbuffered raw write(2), like
# `progress()`). \x1f (US) can't appear in a normal answer, so it can't be spoofed
# by ordinary text. THREE copies of this literal must stay in lockstep: here, the
# orchestrator (privacy-box, which strips it from the captured answer + captures it
# separately), and the app server (which attaches it to the message event).
comptime RESULT_SENTINEL = "\x1f@@result@@\x1f"

# The wire contract version — bumped on any shape change so a client ignore-with-
# fallback (render `text` only) on an unknown `v` is a migration, not a break.
comptime RESULT_VERSION = 1


# ── typed values ────────────────────────────────────────────────────────────────


struct Cell(Copyable, Movable):
    """One typed value in the spec — a KPI value or a table/series cell. The `kind`
    tag ("money"|"count"|"date"|"text") is what lets the client format an axis by a
    number while displaying the exact string, never guessing a type from text.
    """

    var kind: String
    var raw: Float64  # money amount / count (as Float64); 0.0 for date/text
    var text: String  # money() string / String(n) / iso date / plain text

    def __init__(out self, kind: String, raw: Float64, text: String):
        self.kind = kind
        self.raw = raw
        self.text = text

    @implicit
    def __init__(out self, s: String):
        # A bare String in a row/point is a plain TEXT cell — lets
        # `t.row(["Whole Foods", money_val(...)])` mix labels + typed money.
        self.kind = String("text")
        self.raw = 0.0
        self.text = s


def money_val(x: Float64) raises -> Cell:
    """A typed MONEY value — carries BOTH the raw Float64 and the `money(x)` string
    (the typed-money invariant). Use this for every dollar amount in the spec.
    """
    return Cell(String("money"), x, money(x))


def count(n: Int) -> Cell:
    """A typed COUNT value (an integer quantity — transactions, files, …)."""
    return Cell(String("count"), Float64(n), String(n))


def date(iso: String) -> Cell:
    """A typed DATE value — an ISO `YYYY-MM-DD` string the presenter can place on a
    time axis."""
    return Cell(String("date"), 0.0, iso)


# ── the per-run result buffer (a process-global singleton) ──────────────────────


struct Block(Copyable, Movable):
    """One data block in the spec — a `kpi`, a `table`, or a `series`. A single
    struct with a `kind` tag + a field per variant keeps serialization trivial and
    avoids a heterogeneous container."""

    var kind: String  # "kpi" | "table" | "series" | "map"
    # kpi:
    var label: String
    var value: Cell
    # table:
    var headers: List[String]
    var rows: List[List[Cell]]
    # series:
    var title: String
    var series_kind: String  # "time" | "category"
    var hint: String  # optional presenter nudge ("line"/"bar"/…)
    var xs: List[String]  # x values (iso date / category label)
    var ys: List[Cell]  # y values (typed money column)
    # map (geo breakdown): `title` above is reused for the map title.
    var map_level: String  # "country" (ISO3) | "state" (US 2-letter)
    var codes: List[String]  # region codes, parallel to `mvals`
    var mvals: List[Cell]  # typed money per region

    def __init__(out self):
        self.kind = String("")
        self.label = String("")
        self.value = Cell(String("text"), 0.0, String(""))
        self.headers = List[String]()
        self.rows = List[List[Cell]]()
        self.title = String("")
        self.series_kind = String("")
        self.hint = String("")
        self.xs = List[String]()
        self.ys = List[Cell]()
        self.map_level = String("")
        self.codes = List[String]()
        self.mvals = List[Cell]()


struct Buf(Movable):
    var text: String
    var blocks: List[Block]

    def __init__(out self):
        self.text = String("")
        self.blocks = List[Block]()

    def __init__(out self, *, deinit take: Self):
        self.text = take.text^
        self.blocks = take.blocks^


def _init_buf() -> Buf:
    return Buf()


# The one buffer for this run. `_Global` gives a lazily-initialized, process-global
# singleton (Mojo has no module-level mutable globals); every builder appends to it
# and re-serializes.
comptime _BUF = _Global["millfolio_result_v1", _init_buf]


def _bufptr() raises -> UnsafePointer[Buf, MutUntrackedOrigin]:
    return _BUF.get_or_create_ptr()


# ── JSON serialization ──────────────────────────────────────────────────────────


def _jstr(s: String) raises -> String:
    """Quote + escape `s` as a JSON string (control chars → space). Mirrors the
    server's `json_escape` — the spec is DATA the client re-escapes, no markup path.
    """
    var o = String('"')
    for cp in s.codepoints():
        var c = Int(cp)
        if c == 34:
            o += '\\"'
        elif c == 92:
            o += "\\\\"
        elif c == 10:
            o += "\\n"
        elif c == 13:
            o += "\\r"
        elif c == 9:
            o += "\\t"
        elif c < 32:
            o += " "
        else:
            o += chr(c)
    o += '"'
    return o^


def _cell_json(c: Cell) raises -> String:
    if c.kind == "money":
        return (
            '{"type":"money","raw":'
            + String(c.raw)
            + ',"text":'
            + _jstr(c.text)
            + "}"
        )
    elif c.kind == "count":
        return (
            '{"type":"count","raw":'
            + String(Int(c.raw))
            + ',"text":'
            + _jstr(c.text)
            + "}"
        )
    elif c.kind == "date":
        return '{"type":"date","value":' + _jstr(c.text) + "}"
    return '{"type":"text","value":' + _jstr(c.text) + "}"


def _block_json(b: Block) raises -> String:
    if b.kind == "kpi":
        return (
            '{"kind":"kpi","label":'
            + _jstr(b.label)
            + ',"value":'
            + _cell_json(b.value)
            + "}"
        )
    elif b.kind == "table":
        var o = String('{"kind":"table","headers":[')
        for i in range(len(b.headers)):
            if i > 0:
                o += ","
            o += _jstr(b.headers[i])
        o += '],"rows":['
        for r in range(len(b.rows)):
            if r > 0:
                o += ","
            o += "["
            for c in range(len(b.rows[r])):
                if c > 0:
                    o += ","
                o += _cell_json(b.rows[r][c])
            o += "]"
        o += "]}"
        return o^
    elif b.kind == "series":
        var xtype = "date" if b.series_kind == "time" else "category"
        var o = String('{"kind":"series","seriesKind":') + _jstr(b.series_kind)
        o += ',"title":' + _jstr(b.title)
        if b.hint.byte_length() > 0:
            o += ',"hint":' + _jstr(b.hint)
        o += ',"x":{"type":' + _jstr(xtype) + ',"values":['
        for i in range(len(b.xs)):
            if i > 0:
                o += ","
            o += _jstr(b.xs[i])
        o += ']},"y":{"type":"money","raw":['
        for i in range(len(b.ys)):
            if i > 0:
                o += ","
            o += String(b.ys[i].raw)
        o += '],"text":['
        for i in range(len(b.ys)):
            if i > 0:
                o += ","
            o += _jstr(b.ys[i].text)
        o += "]}}"
        return o^
    elif b.kind == "map":
        # A geo breakdown: one typed-money value per region code. `level` tells the
        # client whether `code` is an ISO3 country or a US 2-letter state.
        var o = String('{"kind":"map","title":') + _jstr(b.title)
        o += ',"level":' + _jstr(b.map_level)
        o += ',"points":['
        for i in range(len(b.codes)):
            if i > 0:
                o += ","
            o += '{"code":' + _jstr(b.codes[i]) + ',"value":'
            o += _cell_json(b.mvals[i]) + "}"
        o += "]}"
        return o^
    return String("{}")


def result_json() raises -> String:
    """Serialize the current result buffer to the versioned `v:1` JSON spec. Pure —
    no I/O (the unit test asserts on this); `_emit` writes it on the sentinel line.
    """
    var p = _bufptr()
    var out = String('{"v":') + String(RESULT_VERSION)
    out += ',"text":' + _jstr(p[].text)
    if len(p[].blocks) > 0:
        out += ',"data":['
        for i in range(len(p[].blocks)):
            if i > 0:
                out += ","
            out += _block_json(p[].blocks[i])
        out += "]"
    out += "}"
    return out^


def _emit() raises:
    """Write the serialized spec on a `RESULT_SENTINEL` line to fd 1, unbuffered
    (raw write(2), like `progress()`), so it survives the run sandbox + the captured-
    stdout full-buffering and the server's poller sees it live. The builders re-emit
    after every mutation; the server keeps the LAST (complete) line."""
    var line = String(RESULT_SENTINEL) + result_json() + "\n"
    var n = line.byte_length()
    var ptr = line.unsafe_ptr().bitcast[c_char]()
    _ = external_call["write", Int](Int(1), ptr, Int(n))


# ── builders ────────────────────────────────────────────────────────────────────


def result_text(s: String) raises:
    """The narrative answer — same role as `print_answer`: it `print`s `s` (so the
    text reaches the reply through the normal captured-stdout path, unchanged from
    today) AND records it as the spec's `text`."""
    print(s)
    var p = _bufptr()
    p[].text = s
    _emit()


def kpi(label: String, value: Cell) raises:
    """A labeled scalar → a KPI tile. `value` is a typed `money_val`/`count`/`date`.
    """
    var p = _bufptr()
    var b = Block()
    b.kind = String("kpi")
    b.label = label
    b.value = value.copy()
    p[].blocks.append(b^)
    _emit()


def table(headers: List[String]) raises -> TableRef:
    """Start a labeled table with the given column `headers`; append rows with
    `.row([...])`. Returns a handle bound to this block."""
    var p = _bufptr()
    var b = Block()
    b.kind = String("table")
    b.headers = headers.copy()
    p[].blocks.append(b^)
    _emit()
    return TableRef(len(p[].blocks) - 1)


def series(title: String, kind: String) raises -> SeriesRef:
    """Start a titled series; `kind` is `"time"` (x = ISO date) or `"category"`
    (x = label). Append points with `.point(x, money_val(y))`."""
    var p = _bufptr()
    var b = Block()
    b.kind = String("series")
    b.title = title
    b.series_kind = kind
    p[].blocks.append(b^)
    _emit()
    return SeriesRef(len(p[].blocks) - 1)


def geo_map(title: String, level: String) raises -> MapRef:
    """Start a geo breakdown; `level` is `"country"` (codes are ISO3, e.g. `"USA"`)
    or `"state"` (codes are US 2-letter, e.g. `"WA"`). Append regions with
    `.place(code, money_val(total))`. Emit this for a spending-by-country / by-state
    question — the CLIENT draws the choropleth; the program never chooses the view.
    Group with the `Txn.country`/`Txn.state` fields (index-time, deterministic).

    Named `geo_map` (not `map`) because `map` is a Mojo prelude builtin
    (`std.iter.map`) that shadows a `from vault import *` name; the serialized block
    is still `{"kind":"map",…}` — the client renderer keys on that."""
    var p = _bufptr()
    var b = Block()
    b.kind = String("map")
    b.title = title
    b.map_level = level
    p[].blocks.append(b^)
    _emit()
    return MapRef(len(p[].blocks) - 1)


def hint(name: String) raises:
    """OPTIONAL — nudge the presenter's mark for the most recent series
    (`"line"`/`"bar"`/…). Honored when set, ignored when absent; the Phase-1
    presenter ignores it entirely (charts are Phase 2)."""
    var p = _bufptr()
    var i = len(p[].blocks) - 1
    while i >= 0:
        if p[].blocks[i].kind == "series":
            p[].blocks[i].hint = name
            break
        i -= 1
    _emit()


@fieldwise_init
struct TableRef(Copyable, Movable):
    """A handle to a table block; `.row([...])` appends a row (of typed cells / bare
    strings) and re-emits. Chainable."""

    var idx: Int

    def row(self, cells: List[Cell]) raises -> Self:
        var p = _bufptr()
        p[].blocks[self.idx].rows.append(cells.copy())
        _emit()
        return self.copy()


@fieldwise_init
struct SeriesRef(Copyable, Movable):
    """A handle to a series block; `.point(x, y)` appends an (x, money y) point and
    re-emits. Chainable."""

    var idx: Int

    def point(self, x: String, y: Cell) raises -> Self:
        var p = _bufptr()
        p[].blocks[self.idx].xs.append(x)
        p[].blocks[self.idx].ys.append(y.copy())
        _emit()
        return self.copy()


@fieldwise_init
struct MapRef(Copyable, Movable):
    """A handle to a map block; `.place(code, money_val(y))` appends one region's
    typed-money total and re-emits. Chainable."""

    var idx: Int

    def place(self, code: String, value: Cell) raises -> Self:
        var p = _bufptr()
        p[].blocks[self.idx].codes.append(code)
        p[].blocks[self.idx].mvals.append(value.copy())
        _emit()
        return self.copy()

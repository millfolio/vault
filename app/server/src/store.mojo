"""Store — pure, dependency-free builders for the on-device JSON stores.

Separated from server.mojo (which wraps these with the actual file I/O + HTTP
Response) so they unit-test as a plain Mojo program with no flare/privacy_box —
mirrors events.mojo. Covered by test/store_test.mojo.

Two stores + one info blob:
  • the per-ask HISTORY (`asks.jsonl`) — `ask_record_line` builds one JSONL record
    {ts, q, code, answer, source, model, ok}; `history_records_array` reads the file
    back into a newest-first JSON array.
  • the `/api/system` info — `system_json` assembles the data + log locations.
"""

from events import json_escape


def ask_record_line(
    epoch: Int64,
    question: String,
    code: String,
    answer: String,
    source: String,
    model: String,
    ok: Bool,
) -> String:
    """ONE self-contained JSON record (no trailing newline) for the ask-history
    store: the question, the GENERATED program, and the answer, plus the source
    file, model, and success flag. Arbitrary program/answer text (newlines, quotes,
    tabs) is escaped via `json_escape`, so the result is always one valid JSON
    object. The writer appends the `\\n` that makes the file JSONL."""
    var line = String("{")
    line += '"ts":' + String(epoch)
    line += ',"q":' + json_escape(question)
    line += ',"code":' + json_escape(code)
    line += ',"answer":' + json_escape(answer)
    line += ',"source":' + json_escape(source)
    line += ',"model":' + json_escape(model)
    line += ',"ok":' + ("true" if ok else "false")
    line += "}"
    return line


def parse_progress_counter(detail: String) -> Tuple[Int, Int]:
    """Pull a leading `[<current>/<total>]` counter out of an index-progress line.

    The indexer prefixes each per-file embedding line with `  [n/M] …`; this reads
    those two integers back so the UI can render an "n of M files" bar. Returns
    `(current, total)`, or `(0, 0)` when the line has no such prefix (the scanning
    phase, non-file log lines, or a done/idle state). Pure string scanning — no deps.
    """
    var s = detail
    var n = s.byte_length()
    var zero = ord("0")
    var nine = ord("9")
    var i = 0
    # skip leading whitespace
    while i < n and (ord(s[byte=i]) == ord(" ") or ord(s[byte=i]) == ord("\t")):
        i += 1
    if i >= n or ord(s[byte=i]) != ord("["):
        return (0, 0)
    i += 1
    var cur = 0
    var cur_digits = 0
    while i < n and ord(s[byte=i]) >= zero and ord(s[byte=i]) <= nine:
        cur = cur * 10 + (ord(s[byte=i]) - zero)
        cur_digits += 1
        i += 1
    if cur_digits == 0 or i >= n or ord(s[byte=i]) != ord("/"):
        return (0, 0)
    i += 1
    var tot = 0
    var tot_digits = 0
    while i < n and ord(s[byte=i]) >= zero and ord(s[byte=i]) <= nine:
        tot = tot * 10 + (ord(s[byte=i]) - zero)
        tot_digits += 1
        i += 1
    if tot_digits == 0 or i >= n or ord(s[byte=i]) != ord("]"):
        return (0, 0)
    return (cur, tot)


def history_records_array(raw: String) -> String:
    """Turn the JSONL history file contents into a JSON array body `[<obj>,…]`,
    NEWEST FIRST (the file is appended oldest→newest, so we walk it in reverse).
    Each non-blank line is already a valid object → comma-join verbatim, no
    server-side parse. Empty / blank-only input → `[]`."""
    var recs = String("")
    var first = True
    var lines = raw.split("\n")
    for i in range(len(lines) - 1, -1, -1):
        var ln = String(lines[i]).strip()
        if ln.byte_length() == 0:
            continue
        if not first:
            recs += ","
        recs += ln
        first = False
    return "[" + recs + "]"


def operation_record_line(
    kind: String,
    started: Int64,
    finished: Int64,
    status: String,
    detail: String,
    files: Int,
    txns: Int,
    tagged: Int,
) -> String:
    """ONE self-contained JSON record (no trailing newline) for the operations-
    history store (`operations.jsonl`): a completed index / reindex / backfill run,
    with its start/finish epochs, outcome, and a human detail line. The optional
    counts (files, txns, tagged) are emitted only when `>= 0` — a negative means
    "not applicable to this kind of operation". The writer appends the `\\n` that
    makes the file JSONL."""
    var line = String("{")
    line += '"type":' + json_escape(kind)
    line += ',"started":' + String(started)
    line += ',"finished":' + String(finished)
    line += ',"status":' + json_escape(status)
    line += ',"detail":' + json_escape(detail)
    if files >= 0:
        line += ',"files":' + String(files)
    if txns >= 0:
        line += ',"txns":' + String(txns)
    if tagged >= 0:
        line += ',"tagged":' + String(tagged)
    line += "}"
    return line


def operations_records_array(raw: String, cap: Int) -> String:
    """The operations JSONL → a NEWEST-FIRST JSON array body `[<obj>,…]`, capped at
    the `cap` most-recent records (mirrors `history_records_array`, but bounded so a
    long-lived install doesn't return an unbounded list). Each non-blank line is
    already a valid object → comma-join verbatim. Empty input → `[]`."""
    var recs = String("")
    var first = True
    var kept = 0
    var lines = raw.split("\n")
    for i in range(len(lines) - 1, -1, -1):
        if kept >= cap:
            break
        var ln = String(lines[i]).strip()
        if ln.byte_length() == 0:
            continue
        if not first:
            recs += ","
        recs += ln
        first = False
        kept += 1
    return "[" + recs + "]"


def delete_ask_records(raw: String, q: String) raises -> String:
    """Return the JSONL history with every record for question `q` removed — backs
    POST /api/history/delete (the recent-questions panel dedups by question, so a
    delete removes all of that question's asks). Matches the exact `"q":<escaped>`
    field; json_escape includes the closing quote, so a different question that
    merely starts with the same text is never touched. Preserves line order + the
    trailing newline."""
    var needle = String('"q":') + json_escape(q)
    var out = String("")
    var lines = raw.split("\n")
    for i in range(len(lines)):
        var ln = String(lines[i])
        if String(ln.strip()).byte_length() == 0:
            continue
        if ln.find(needle) != -1:
            continue  # a record for this question — drop it
        out += ln + "\n"
    return out^


def system_json(
    home: String,
    version: String,
    data_dir: String,
    stats_file: String,
    asks_file: String,
) -> String:
    """The `/api/system` payload: WHERE the data + logs live, plus the version.
    Data paths are passed in (the server computes them from its own config — honors
    env overrides); the log paths are derived here from `home` and mirror the ones
    the `mill` CLI's launch agents write to. (The served model is NOT reported here —
    the bottom status bar shows the live model from /api/models; a second source drifted.)
    """
    var app_log = home + "/Library/Application Support/Millfolio/Millfolio.log"
    var server_log = home + "/Library/Logs/Millfolio/server.log"
    var transcripts = String("/tmp/millfolio/sessions/")
    var out = String("{")
    out += '"version":' + json_escape(version)
    out += ',"dataDir":' + json_escape(data_dir)
    out += ',"statsFile":' + json_escape(stats_file)
    out += ',"asksFile":' + json_escape(asks_file)
    # The user-editable category rules (vault.derive): edit + re-index to retag.
    out += ',"categoriesFile":' + json_escape(data_dir + "/categories.txt")
    out += ',"logs":{'
    out += '"transcripts":' + json_escape(transcripts)
    out += ',"app":' + json_escape(app_log)
    out += ',"server":' + json_escape(server_log)
    out += "}}"
    return out

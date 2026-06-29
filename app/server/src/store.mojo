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


def system_json(
    home: String,
    version: String,
    model: String,
    data_dir: String,
    stats_file: String,
    asks_file: String,
) -> String:
    """The `/api/system` payload: WHERE the data + logs live, plus version/model.
    Data paths are passed in (the server computes them from its own config — honors
    env overrides); the log paths are derived here from `home` and mirror the ones
    the `mill` CLI's launch agents write to."""
    var app_log = home + "/Library/Application Support/Millfolio/Millfolio.log"
    var server_log = home + "/Library/Logs/Millfolio/server.log"
    var transcripts = String("/tmp/millfolio/sessions/")
    var out = String("{")
    out += '"version":' + json_escape(version)
    out += ',"model":' + json_escape(model)
    out += ',"dataDir":' + json_escape(data_dir)
    out += ',"statsFile":' + json_escape(stats_file)
    out += ',"asksFile":' + json_escape(asks_file)
    out += ',"logs":{'
    out += '"transcripts":' + json_escape(transcripts)
    out += ',"app":' + json_escape(app_log)
    out += ',"server":' + json_escape(server_log)
    out += "}}"
    return out

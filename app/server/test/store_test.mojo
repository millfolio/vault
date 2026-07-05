"""Store_test — unit tests for the on-device JSON store builders (store.mojo).

Builds + runs as a plain Mojo program (no flare/privacy_box): `pixi run test-store`.
Asserts that the ask-history record is valid, escaped JSON; that the history array
comes back newest-first and skips blank lines; and that the /api/system blob carries
the expected data + log paths. Pure functions → fully deterministic, no fixtures.
"""

from store import (
    ask_record_line,
    history_records_array,
    delete_ask_records,
    system_json,
)
from json import loads


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def expect_eq(got: String, want: String, what: String) raises:
    if got != want:
        raise Error("FAIL: " + what + "\n  got:  " + got + "\n  want: " + want)


def main() raises:
    # ── ask_record_line: valid JSON, all fields, arbitrary text escaped ──────────
    var line = ask_record_line(
        1234,
        'pho"ne bill',  # a quote in the question
        'print("hi")\n',  # a newline in the generated code
        "paid\t$5",  # a tab in the answer
        "file_3",
        "qwen",
        True,
    )
    _ = loads(line)  # raises if the record isn't valid JSON
    expect(line.find('"ts":1234') != -1, "ts present")
    expect(line.find('"q":"pho\\"ne bill"') != -1, "question quote escaped")
    expect(
        line.find('"code":"print(\\"hi\\")\\n"') != -1,
        "code newline+quotes escaped",
    )
    expect(line.find('"answer":"paid\\t$5"') != -1, "answer tab escaped")
    expect(line.find('"source":"file_3"') != -1, "source present")
    expect(line.find('"model":"qwen"') != -1, "model present")
    expect(line.find('"ok":true') != -1, "ok true")
    expect(
        line.find("\n") == -1,
        "record line has no embedded newline (writer adds it)",
    )

    var line2 = ask_record_line(1, "q", "c", "a", "file_0", "m", False)
    expect(line2.find('"ok":false') != -1, "ok false")

    # ── history_records_array: newest-first, skips blanks, valid array ───────────
    var raw = '{"ts":1,"q":"a"}\n\n{"ts":2,"q":"b"}\n{"ts":3,"q":"c"}\n'
    var arr = history_records_array(raw)
    _ = loads('{"records":' + arr + "}")  # must embed as a valid JSON array
    var p1 = arr.find('"ts":1')
    var p2 = arr.find('"ts":2')
    var p3 = arr.find('"ts":3')
    expect(p1 != -1 and p2 != -1 and p3 != -1, "all three records kept")
    expect(p3 < p2 and p2 < p1, "newest-first ordering (3,2,1)")
    expect_eq(history_records_array(""), "[]", "empty file → []")
    expect_eq(history_records_array("\n  \n\n"), "[]", "blank-only → []")

    # ── delete_ask_records: drop a question's records, exact match (no prefix bleak) ─
    var hraw = (
        '{"ts":1,"q":"gym"}\n'
        + '{"ts":2,"q":"gym membership"}\n'  # must SURVIVE (not a prefix false-match)
        + '{"ts":3,"q":"phone"}\n'
        + '{"ts":4,"q":"gym"}\n'  # a second "gym" ask — also removed
    )
    var dres = delete_ask_records(hraw, "gym")
    expect(dres.find('"q":"gym"') == -1, "both exact 'gym' records removed")
    expect(
        dres.find('"q":"gym membership"') != -1,
        "'gym membership' survives (exact match, no prefix bleed)",
    )
    expect(dres.find('"q":"phone"') != -1, "unrelated 'phone' record kept")
    expect_eq(
        delete_ask_records('{"ts":1,"q":"a"}\n', "zzz"),
        '{"ts":1,"q":"a"}\n',
        "deleting a missing question is a no-op",
    )

    # ── system_json: keys + $HOME-derived log paths + passed-in data paths ───────
    var sj = system_json(
        "/Users/x",
        "v9",
        "/Users/x/.config/millfolio",
        "/Users/x/.config/millfolio/stats.jsonl",
        "/Users/x/.config/millfolio/asks.jsonl",
    )
    _ = loads(sj)  # valid JSON object
    expect(sj.find('"version":"v9"') != -1, "version")
    expect(sj.find('"dataDir":"/Users/x/.config/millfolio"') != -1, "dataDir")
    expect(
        sj.find('"asksFile":"/Users/x/.config/millfolio/asks.jsonl"') != -1,
        "asksFile",
    )
    expect(
        sj.find('"categoriesFile":"/Users/x/.config/millfolio/categories.txt"')
        != -1,
        "categoriesFile derived from dataDir",
    )
    expect(
        sj.find(
            '"app":"/Users/x/Library/Application'
            ' Support/Millfolio/Millfolio.log"'
        )
        != -1,
        "app log path derived from home",
    )
    expect(
        sj.find('"server":"/Users/x/Library/Logs/Millfolio/server.log"') != -1,
        "server log path derived from home",
    )
    expect(
        sj.find('"transcripts":"/tmp/millfolio/sessions/"') != -1,
        "transcripts path",
    )

    print("ok: all store tests passed")

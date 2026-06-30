"""Events_test — unit tests for the protocol wire helpers (events.mojo).

Builds + runs as a plain Mojo program (no flare/headgate): `pixi run test`.
Asserts the exact ServerEvent JSON encodings and the field parser, so a change
to the wire format that drifts from ../../protocol/events.ts fails CI.
"""

from events import (
    json_escape,
    field,
    status,
    tags_event,
    debug_event,
    approval,
    message,
    error_event,
)


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def expect_eq(got: String, want: String, what: String) raises:
    if got != want:
        raise Error("FAIL: " + what + "\n  got:  " + got + "\n  want: " + want)


def main() raises:
    # status / message / error: exact encodings (no tricky escaping)
    expect_eq(
        status("run", "Go", "running"),
        '{"type":"status","stepId":"run","label":"Go","state":"running"}',
        "status encoding",
    )
    expect_eq(
        message("hi"),
        '{"type":"message","id":"msg","role":"assistant","text":"hi"}',
        "message encoding",
    )
    expect_eq(
        error_event("boom"),
        '{"type":"error","message":"boom"}',
        "error encoding",
    )

    # debug / approval: check structure + payload shape
    expect_eq(
        tags_event("phone,travel"),
        '{"type":"tags","tags":"phone,travel"}',
        "tags_event encoding",
    )

    var d = debug_event("codegen", "Generated program", "x", "mojo")
    expect(d.find('"type":"debug"') != -1, "debug type")
    expect(d.find('"language":"mojo"') != -1, "debug language")
    var a = approval("run", "Run it?", "code")
    expect(a.find('"type":"approval-request"') != -1, "approval type")
    expect(a.find('"payload":{') != -1, "approval payload object")
    expect(a.find('"body":"code"') != -1, "approval payload body")

    # json_escape: quotes, backslashes, control chars
    expect(json_escape('a"b').find('\\"') != -1, "escape double-quote")
    expect(json_escape("a\nb").find("\\n") != -1, "escape newline")
    expect(json_escape("a\tb").find("\\t") != -1, "escape tab")

    # field: parses a top-level string field; empty on bad/missing input
    expect_eq(field('{"type":"ask","text":"q"}', "text"), "q", "field text")
    expect_eq(field('{"type":"approve"}', "type"), "approve", "field type")
    expect_eq(field("not json", "text"), "", "field on bad json")
    expect_eq(field('{"text":"q"}', "missing"), "", "field on missing key")

    print("ok: all event tests passed")

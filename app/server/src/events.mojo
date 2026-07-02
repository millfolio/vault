"""events — millfolio protocol wire helpers (server side).

Pure String/JSON functions: serialize ServerEvents (status/debug/approval-request/
message/error) and parse a field out of a ClientMessage. Split out of ws_server so
they're unit-testable with no headgate/flare deps (only json) — see events_test.mojo.

Keep the encodings in lockstep with ../../protocol/events.ts.
"""

from json import loads


def json_escape(s: String) -> String:
    """Quote + escape `s` as a JSON string (control chars dropped to spaces)."""
    var out = String('"')
    for cp in s.codepoints():
        var c = Int(cp)
        if c == 34:
            out += '\\"'
        elif c == 92:
            out += "\\\\"
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif c == 9:
            out += "\\t"
        elif c < 32:
            out += " "
        else:
            out += chr(c)
    out += '"'
    return out


def field(body: String, key: String) -> String:
    """Pull a top-level string field out of a JSON message (empty on any failure).
    """
    try:
        var j = loads(body)
        return j[key].string_value()
    except:
        return String("")


def status(step: String, label: String, state: String) -> String:
    return (
        '{"type":"status","stepId":'
        + json_escape(step)
        + ',"label":'
        + json_escape(label)
        + ',"state":'
        + json_escape(state)
        + "}"
    )


def tags_event(names: String) -> String:
    """The category tags the generated program filtered on (comma-joined) — the UI
    shows a chip so the user knows the answer came from a tag, not a guess."""
    return '{"type":"tags","tags":' + json_escape(names) + "}"


def tag_proposal_event(name: String, value: String, kind: String) -> String:
    """A reusable-tag suggestion the model emitted for a durable category that isn't a
    tag yet. `kind` is `"ml"` (AI rule — `value` is the yes/no question) or `"kw"`
    (keyword rule — `value` is the comma-joined keywords). The UI offers to save it to
    `categories.txt` (and, for an AI rule, backfill it) so the next such question is
    a fast, exact `.tags` filter instead of an inline per-transaction classify.
    """
    var is_ml = "true" if kind == "ml" else "false"
    var field = '"prompt":' if kind == "ml" else '"keywords":'
    return (
        '{"type":"tag-proposal","name":'
        + json_escape(name)
        + ',"ml":'
        + is_ml
        + ","
        + field
        + json_escape(value)
        + "}"
    )


def debug_event(
    step: String, title: String, body: String, language: String
) -> String:
    return (
        '{"type":"debug","stepId":'
        + json_escape(step)
        + ',"title":'
        + json_escape(title)
        + ',"body":'
        + json_escape(body)
        + ',"language":'
        + json_escape(language)
        + "}"
    )


def approval(step: String, label: String, body: String) -> String:
    return (
        '{"type":"approval-request","stepId":'
        + json_escape(step)
        + ',"label":'
        + json_escape(label)
        + ',"payload":{"title":'
        + json_escape(
            "Sandboxed run — reads your real data locally, no network"
        )
        + ',"body":'
        + json_escape(body)
        + ',"language":"mojo"}}'
    )


def message(
    text: String, source: String = String(""), source_alias: String = String("")
) -> String:
    # `source`/`source_alias` (optional) — the filename + alias of the first document
    # used to answer. The UI renders the filename as a link to /api/doc?alias=<alias>
    # (alias-gated; no real path leaves). Omitted when empty.
    var src = String("")
    if source.byte_length() > 0 and source_alias.byte_length() > 0:
        src = (
            ',"source":'
            + json_escape(source)
            + ',"sourceAlias":'
            + json_escape(source_alias)
        )
    return (
        '{"type":"message","id":"msg","role":"assistant","text":'
        + json_escape(text)
        + src
        + "}"
    )


def error_event(text: String) -> String:
    return '{"type":"error","message":' + json_escape(text) + "}"

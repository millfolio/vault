"""handlers_millwright — the Millwright dashboard: a codegen-able, versioned,
user-owned view spec (designs/MILLWRIGHT.md).

Two-plane model: the DATA plane is a pinned copy of a generated vault program +
its latest result-spec (per widget, under `<data>/millwright/`); the VIEW plane
is one declarative dashboard spec — named widgets + layout — stored as an
append-only chain of immutable, content-addressed versions (`millwright.jsonl`)
with the ACTIVE version a KV pointer (`.millwright.active`), so revert moves the
pointer and never rewrites history.

  • GET  /api/millwright          — active spec + each widget's cached result.
  • GET  /api/millwright/versions — the version chain, newest first.
  • GET  /api/millwright/program  — ?id=w-… → the pinned program (for refresh).
  • POST /api/millwright/spec     — accept an edited spec {spec, message?}
                                    (validate-before-accept → new version).
  • POST /api/millwright/revert   — {hash} → move the active pointer.
  • POST /api/millwright/pin      — {q, title?, result} → snapshot the newest
                                    ask for `q` (program + result) as a widget,
                                    append it to the spec (new version).
  • POST /api/millwright/result   — {id, result} → refresh a widget's cached
                                    result (written after a client-driven re-run).

Invariants enforced HERE (the trusted side of the seam):
  - a spec is shape-linted BEFORE it becomes a version (`validate_spec`);
  - no remote URLs anywhere in a spec or result (exfil channel);
  - widget ids are path-safe (`w-` + [a-z0-9-]) — they name snapshot files;
  - a widget must have a pinned program doc before a spec may reference it;
  - all writes are rejected in the public demo.

Follows the handlers convention: leaf imports only (state-free — every handler
here is pure request→storage→Response), `_cors(...)` on every reply.
"""

from std.os import makedirs
from std.os.path import exists

from flare.prelude import *

from json import loads, Value

from osutil import _is_demo, _epoch_s
from httputil import unauthorized, _cors
from events import json_escape
from record_builders import history_records_array, millwright_version_line
from vault.storage import (
    default_millwright_versions_store,
    default_millwright_docs_store,
    default_kv_store,
    default_asks_store,
    millwright_dir,
    KV_MILLWRIGHT_ACTIVE,
)

comptime SPEC_VERSION = 1
"""The dashboard-spec contract version (mirrors the result-spec's `v`)."""

comptime EMPTY_SPEC = (
    '{"v":1,"kind":"dashboard","widgets":[],"layout":{"cols":2,"order":[]}}'
)
"""The bootstrap spec an empty dashboard starts from (first pin's parent)."""


# ── content addressing ────────────────────────────────────────────────────────


def _fnv1a64_hex(s: String, nchars: Int) -> String:
    """FNV-1a 64-bit of `s` as the first `nchars` (≤16) lowercase hex chars.
    Identity, not security: the chain is a local, owner-only file; collisions at
    dashboard-spec scale are not a realistic concern (same choice as the codegen
    cache)."""
    var h = UInt64(0xCBF29CE484222325)
    var b = s.as_bytes()
    for i in range(len(b)):
        h ^= UInt64(Int(b[i]))
        h *= UInt64(0x100000001B3)
    var hex = String("")
    var digits = "0123456789abcdef"
    for i in range(nchars):
        var nib = Int((h >> UInt64((15 - i) * 4)) & 0xF)
        hex += digits[byte=nib]
    return hex


def _fnv1a64(s: String) -> String:
    """The full 16-hex-char FNV-1a 64 of `s` — the version id."""
    return _fnv1a64_hex(s, 16)


# ── spec validation (the view-plane lint) ────────────────────────────────────


def _has(v: Value, key: String) -> Bool:
    """Non-raising object-membership check (`key in v`)."""
    if not v.is_object():
        return False
    var keys = v.object_keys()
    for i in range(len(keys)):
        if keys[i] == key:
            return True
    return False


def _path_safe_id(id: String) -> Bool:
    """True iff `id` is `w-` + [a-z0-9-]+ — ids become snapshot FILENAMES, so
    this is the traversal guard as well as a style rule."""
    if not id.startswith("w-") or id.byte_length() < 3:
        return False
    var b = id.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        var ok = (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("-")
        )
        if not ok:
            return False
    return True


def _program_doc(id: String) -> String:
    return id + ".program.mojo"


def _result_doc(id: String) -> String:
    return id + ".result.json"


def validate_spec(text: String) raises -> String:
    """Shape-lint a dashboard spec. Returns "" when acceptable, else a human
    reason. This runs BEFORE a spec becomes a version — invariant 4 of the
    design (a broken spec never bricks the app) starts here."""
    if text.find("http://") != -1 or text.find("https://") != -1:
        return "remote URLs are not allowed in a spec"
    var v: Value
    try:
        v = loads(text)
    except:
        return "spec is not valid JSON"
    if not v.is_object():
        return "spec must be a JSON object"
    if not _has(v, "v") or not v["v"].is_int() or v["v"].int_value() != 1:
        return 'spec must declare "v": 1'
    if (
        not _has(v, "kind")
        or not v["kind"].is_string()
        or v["kind"].string_value() != "dashboard"
    ):
        return 'spec must declare "kind": "dashboard"'
    if not _has(v, "widgets") or not v["widgets"].is_array():
        return 'spec must have a "widgets" array'
    var seen = List[String]()
    var widgets = v["widgets"].array_items()
    for i in range(len(widgets)):
        ref w = widgets[i]
        if not w.is_object():
            return "each widget must be an object"
        if not _has(w, "id") or not w["id"].is_string():
            return "each widget needs a string id"
        var id = w["id"].string_value()
        if not _path_safe_id(id):
            return "widget id must be w- followed by [a-z0-9-]: " + id
        for j in range(len(seen)):
            if seen[j] == id:
                return "duplicate widget id: " + id
        if (
            not _has(w, "title")
            or not w["title"].is_string()
            or w["title"].string_value().byte_length() == 0
        ):
            return "widget " + id + " needs a non-empty title"
        if _has(w, "w") and (
            not w["w"].is_int()
            or w["w"].int_value() < 1
            or w["w"].int_value() > 6
        ):
            return "widget " + id + ": w must be an int 1..6"
        if _has(w, "h") and (
            not w["h"].is_int()
            or w["h"].int_value() < 1
            or w["h"].int_value() > 6
        ):
            return "widget " + id + ": h must be an int 1..6"
        # The view plane may only reference widgets whose DATA-plane snapshot
        # (the pinned program) exists — binding to results, never to raw reads.
        if not exists(millwright_dir() + "/" + _program_doc(id)):
            return "widget " + id + " has no pinned program"
        seen.append(id^)
    if _has(v, "layout"):
        var lo = v["layout"]
        if not lo.is_object():
            return '"layout" must be an object'
        if _has(lo, "cols") and (
            not lo["cols"].is_int()
            or lo["cols"].int_value() < 1
            or lo["cols"].int_value() > 6
        ):
            return "layout.cols must be an int 1..6"
        if _has(lo, "order"):
            if not lo["order"].is_array():
                return "layout.order must be an array of widget ids"
            var order = lo["order"].array_items()
            for i in range(len(order)):
                ref e = order[i]
                if not e.is_string():
                    return "layout.order entries must be widget ids"
                var oid = e.string_value()
                var found = False
                for j in range(len(seen)):
                    if seen[j] == oid:
                        found = True
                        break
                if not found:
                    return "layout.order references unknown widget: " + oid
    return String("")


# ── the version chain ────────────────────────────────────────────────────────


def _versions_raw() -> String:
    try:
        return default_millwright_versions_store().read_all()
    except:
        return String("")  # no dashboard yet


def _active_hash() -> String:
    try:
        return String(default_kv_store().get(KV_MILLWRIGHT_ACTIVE).strip())
    except:
        return String("")


def _record_for(hash: String) raises -> String:
    """The full version record line for `hash`, or "" when unknown. Newest match
    wins (there is at most one — `_accept_spec` dedupes on hash)."""
    var needle = String('"hash":') + json_escape(hash)
    var lines = _versions_raw().split("\n")
    for i in range(len(lines) - 1, -1, -1):
        var ln = String(String(lines[i]).strip())
        if ln.byte_length() == 0:
            continue
        if ln.find(needle) != -1:
            return ln
    return String("")


def _spec_text_for(hash: String) raises -> String:
    """The spec JSON of version `hash`, re-serialized standalone; "" if unknown.
    """
    var rec = _record_for(hash)
    if rec.byte_length() == 0:
        return String("")
    try:
        return loads(rec)["spec"].raw_json()
    except:
        return String("")  # torn record — treated as unknown


def _active_spec_text() raises -> String:
    """The ACTIVE spec, or the bootstrap EMPTY_SPEC when none exists yet."""
    var h = _active_hash()
    if h.byte_length() > 0:
        var s = _spec_text_for(h)
        if s.byte_length() > 0:
            return s^
    return String(EMPTY_SPEC)


def _accept_spec(
    spec_text: String, message: String, author: String
) raises -> String:
    """Validate → content-address → append (unless the hash already exists) →
    move the active pointer. Returns the version hash. Raises with the lint
    reason on an invalid spec — callers turn that into a 400."""
    var why = validate_spec(spec_text)
    if why.byte_length() > 0:
        raise Error(why)
    var hash = _fnv1a64(spec_text)
    if _record_for(hash).byte_length() == 0:
        var parent = _active_hash()
        default_millwright_versions_store().append(
            millwright_version_line(
                hash, parent, _epoch_s(), author, message, spec_text
            )
        )
    default_kv_store().set(KV_MILLWRIGHT_ACTIVE, hash)
    return hash^


# ── data-plane snapshots (pin) ───────────────────────────────────────────────


def _ask_code_for_question(q: String) raises -> String:
    """The generated program of the NEWEST ask-history record for question `q`
    ("" when none). Matches the exact `"q":<escaped>` field — the same needle
    discipline as `delete_ask_records` — then parses that one line."""
    var raw: String
    try:
        raw = default_asks_store().read_all()
    except:
        return String("")
    var needle = String('"q":') + json_escape(q)
    var lines = raw.split("\n")
    for i in range(len(lines) - 1, -1, -1):
        var ln = String(String(lines[i]).strip())
        if ln.byte_length() == 0 or ln.find(needle) == -1:
            continue
        try:
            var rec = loads(ln)
            if _has(rec, "code") and rec["code"].is_string():
                return rec["code"].string_value()
        except:
            continue  # torn line — keep scanning older records
    return String("")


def _slug_title(q: String) -> String:
    """Default widget title: the question, trimmed to something tile-sized."""
    var s = String(q.strip())
    if s.byte_length() <= 60:
        return s^
    var out = String("")
    var n = 0
    for cp in s.codepoint_slices():
        if n >= 57:
            break
        out += String(cp)
        n += 1
    return out + "…"


# ── HTTP handlers ────────────────────────────────────────────────────────────


def handle_millwright() raises -> Response:
    """GET /api/millwright → {"active","spec","results":{id:{ts,result}}} —
    everything the dashboard tab needs in one call. Widgets whose cached result
    is missing/torn simply have no entry (the tile renders as pending)."""
    var spec_text = _active_spec_text()
    var out = String("{")
    out += '"active":' + json_escape(_active_hash())
    out += ',"spec":' + spec_text
    out += ',"results":{'
    var docs = default_millwright_docs_store()
    var first = True
    try:
        var spec = loads(spec_text)
        var widgets = spec["widgets"].array_items()
        for i in range(len(widgets)):
            ref w = widgets[i]
            if not _has(w, "id") or not w["id"].is_string():
                continue
            var id = w["id"].string_value()
            var doc: String
            try:
                doc = docs.load(_result_doc(id))
            except:
                continue  # never ran / cleared — pending tile
            if not first:
                out += ","
            out += json_escape(id) + ":" + doc
            first = False
    except:
        pass  # an unreadable active spec renders as empty — chrome stays up
    out += "}}"
    return _cors(ok_json(out))


def handle_millwright_versions() raises -> Response:
    """GET /api/millwright/versions → the chain newest-first (full records —
    hash, parent, ts, author, message, spec) + the active pointer."""
    var out = String("{")
    out += '"active":' + json_escape(_active_hash())
    out += ',"versions":' + history_records_array(_versions_raw())
    out += "}"
    return _cors(ok_json(out))


def handle_millwright_spec(req: Request) raises -> Response:
    """POST /api/millwright/spec {"spec": <object|string>, "message"?} → accept a
    (hand- or model-)edited spec as a new version. The spec may arrive as a JSON
    object or a pre-serialized string; it is validated either way."""
    if _is_demo():
        return _cors(
            unauthorized('{"error":"the demo dashboard is read-only"}')
        )
    var spec_text: String
    var message = String("edited spec")
    try:
        var body = loads(req.text())
        var so = body["spec"]
        if so.is_string():
            spec_text = so.string_value()
        else:
            spec_text = so.raw_json()
        if _has(body, "message") and body["message"].is_string():
            var m = body["message"].string_value()
            if m.byte_length() > 0:
                message = m^
    except:
        return _cors(bad_request('{"error":"expected {spec, message?}"}'))
    var hash: String
    try:
        hash = _accept_spec(spec_text, message, "user")
    except e:
        return _cors(bad_request('{"error":' + json_escape(String(e)) + "}"))
    return _cors(ok_json('{"ok":true,"hash":' + json_escape(hash) + "}"))


def handle_millwright_revert(req: Request) raises -> Response:
    """POST /api/millwright/revert {"hash"} → move the active pointer to an
    existing version. History is immutable — nothing is rewritten."""
    if _is_demo():
        return _cors(
            unauthorized('{"error":"the demo dashboard is read-only"}')
        )
    var hash: String
    try:
        hash = String(loads(req.text())["hash"].string_value())
    except:
        return _cors(bad_request('{"error":"expected {hash}"}'))
    if _record_for(hash).byte_length() == 0:
        return _cors(bad_request('{"error":"unknown version"}'))
    default_kv_store().set(KV_MILLWRIGHT_ACTIVE, hash)
    return _cors(ok_json('{"ok":true,"hash":' + json_escape(hash) + "}"))


def handle_millwright_pin(req: Request) raises -> Response:
    """POST /api/millwright/pin {"q", "title"?, "result"?} → the v1 on-ramp.
    Snapshots the newest ask for `q` (its generated program, from the history
    log) plus the CLIENT-SUPPLIED result spec it just rendered, then appends a
    widget to the active spec as a new version. Every widget is therefore born
    from a program the user already saw run, with a result that already renders.
    """
    if _is_demo():
        return _cors(
            unauthorized('{"error":"pinning is disabled in the demo"}')
        )
    var q: String
    var title: String
    var result_text = String("")
    try:
        var body = loads(req.text())
        q = String(body["q"].string_value())
        title = _slug_title(q)
        if _has(body, "title") and body["title"].is_string():
            var t = body["title"].string_value()
            if t.byte_length() > 0:
                title = t^
        if _has(body, "result") and body["result"].is_object():
            result_text = body["result"].raw_json()
    except:
        return _cors(bad_request('{"error":"expected {q, title?, result?}"}'))
    if q.byte_length() == 0:
        return _cors(bad_request('{"error":"empty question"}'))
    if result_text.find("http://") != -1 or result_text.find("https://") != -1:
        return _cors(
            bad_request('{"error":"remote URLs are not allowed in a result"}')
        )
    var code = _ask_code_for_question(q)
    if code.byte_length() == 0:
        return _cors(
            bad_request('{"error":"no saved program found for that question"}')
        )
    # Data-plane snapshot first (the spec lint requires the program doc).
    var ts = _epoch_s()
    var id = String("w-") + _fnv1a64_hex(
        q + "\x1f" + code + "\x1f" + String(ts), 8
    )
    try:
        makedirs(millwright_dir())
    except:
        pass  # already exists
    var docs = default_millwright_docs_store()
    docs.save(_program_doc(id), code)
    if result_text.byte_length() > 0:
        docs.save(
            _result_doc(id),
            '{"ts":' + String(ts) + ',"result":' + result_text + "}",
        )
    # View-plane: append the widget + a layout slot, accept as a new version.
    # (json Values are copy-on-write views — mutate the child, then set() it
    # back on the parent so the parent's tape sees the change.)
    var widget_json = String("{")
    widget_json += '"id":' + json_escape(id)
    widget_json += ',"title":' + json_escape(title)
    widget_json += ',"q":' + json_escape(q)
    widget_json += ',"w":1,"h":1}'
    var spec = loads(_active_spec_text())
    var widgets = spec["widgets"]
    widgets.append(loads(widget_json))
    spec.set("widgets", widgets)
    if _has(spec, "layout") and spec["layout"].is_object():
        var layout = spec["layout"]
        if _has(layout, "order") and layout["order"].is_array():
            var order = layout["order"]
            order.append(Value(id))
            layout.set("order", order)
            spec.set("layout", layout)
    var hash: String
    try:
        hash = _accept_spec(
            spec.raw_json(), String('pinned "') + title + '"', "user"
        )
    except e:
        return _cors(bad_request('{"error":' + json_escape(String(e)) + "}"))
    return _cors(
        ok_json(
            '{"ok":true,"id":'
            + json_escape(id)
            + ',"hash":'
            + json_escape(hash)
            + "}"
        )
    )


def handle_millwright_result(req: Request) raises -> Response:
    """POST /api/millwright/result {"id", "result"} → refresh a widget's cached
    result (the client posts this after re-running the widget's program through
    the existing deterministic `run` path). The id must be in the ACTIVE spec —
    a stale client can't write snapshots for widgets that no longer exist."""
    if _is_demo():
        return _cors(
            unauthorized('{"error":"the demo dashboard is read-only"}')
        )
    var id: String
    var result_text: String
    try:
        var body = loads(req.text())
        id = String(body["id"].string_value())
        if not body["result"].is_object():
            raise Error("missing result")
        result_text = body["result"].raw_json()
    except:
        return _cors(bad_request('{"error":"expected {id, result}"}'))
    if not _path_safe_id(id):
        return _cors(bad_request('{"error":"bad widget id"}'))
    if result_text.find("http://") != -1 or result_text.find("https://") != -1:
        return _cors(
            bad_request('{"error":"remote URLs are not allowed in a result"}')
        )
    if _active_spec_text().find(json_escape(id)) == -1:
        return _cors(bad_request('{"error":"widget not in the active spec"}'))
    default_millwright_docs_store().save(
        _result_doc(id),
        '{"ts":' + String(_epoch_s()) + ',"result":' + result_text + "}",
    )
    return _cors(ok_json('{"ok":true}'))


def handle_millwright_program(req: Request) raises -> Response:
    """GET /api/millwright/program?id=w-… → {"id","program"} — the client feeds
    this to the existing `run` WS frame for a manual widget refresh (the same
    deterministic re-execution as history's Run again)."""
    var id = String(req.query_param("id"))
    if not _path_safe_id(id):
        return _cors(bad_request('{"error":"bad widget id"}'))
    var program: String
    try:
        program = default_millwright_docs_store().load(_program_doc(id))
    except:
        return _cors(bad_request('{"error":"unknown widget"}'))
    return _cors(
        ok_json(
            '{"id":'
            + json_escape(id)
            + ',"program":'
            + json_escape(program)
            + "}"
        )
    )

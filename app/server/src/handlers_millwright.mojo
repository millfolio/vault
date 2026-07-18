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
from settings import load_config
from wiring import build_vault_harness
from vaultcfg import vault_dir as resolve_vault_dir
from auth import _apply_persisted_apikey
from events import json_escape
from record_builders import history_records_array, millwright_version_line
from millwright_seed import (
    SEED_AUTHOR,
    SEED_MESSAGE,
    SEED_SPEC,
    seed_widget_ids,
    seed_programs,
    seed_results,
)
from vault.storage import (
    default_millwright_versions_store,
    default_millwright_docs_store,
    default_kv_store,
    default_asks_store,
    millwright_dir,
    millwright_log_path,
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
    """LEGACY per-widget program doc (pre-content-addressing pins)."""
    return id + ".program.mojo"


def _program_hash_doc(hash: String) -> String:
    """Content-addressed program snapshot (v2 §3): immutable, keyed by the
    FNV-1a of the code; a widget binds to it via its spec `program` field, so
    program changes ride the SPEC version chain and revert coherently."""
    return "p-" + hash + ".mojo"


def _is_hex16(s: String) -> Bool:
    if s.byte_length() != 16:
        return False
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        var ok = (c >= ord("0") and c <= ord("9")) or (
            c >= ord("a") and c <= ord("f")
        )
        if not ok:
            return False
    return True


def _all_widgets(spec: Value) raises -> List[Value]:
    """Every widget across the root board AND the pages (v2 §2) — the walk the
    results map, program resolution, and staleness stamping all share."""
    var out = List[Value]()
    if _has(spec, "widgets") and spec["widgets"].is_array():
        var ws = spec["widgets"].array_items()
        for i in range(len(ws)):
            out.append(ws[i].copy())
    if _has(spec, "pages") and spec["pages"].is_array():
        var pages = spec["pages"].array_items()
        for i in range(len(pages)):
            ref pg = pages[i]
            if _has(pg, "widgets") and pg["widgets"].is_array():
                var pws = pg["widgets"].array_items()
                for j in range(len(pws)):
                    out.append(pws[j].copy())
    return out^


def _widget_program_hash(spec_text: String, id: String) raises -> String:
    """The `program` hash of widget `id` in `spec_text` ("" when unbound —
    a legacy widget still on its per-id doc)."""
    try:
        var spec = loads(spec_text)
        var widgets = _all_widgets(spec)
        for i in range(len(widgets)):
            ref w = widgets[i]
            if (
                _has(w, "id")
                and w["id"].is_string()
                and w["id"].string_value() == id
                and _has(w, "program")
                and w["program"].is_string()
            ):
                return w["program"].string_value()
    except:
        pass
    return String("")


def _program_text(spec_text: String, id: String) raises -> String:
    """Resolve widget `id`'s program: the content-addressed snapshot its spec
    binding names, falling back to the legacy per-widget doc ("" when neither
    exists)."""
    var docs = default_millwright_docs_store()
    var h = _widget_program_hash(spec_text, id)
    if h.byte_length() > 0:
        try:
            return docs.load(_program_hash_doc(h))
        except:
            pass  # dangling binding — fall through to legacy
    try:
        return docs.load(_program_doc(id))
    except:
        return String("")


def _result_doc(id: String) -> String:
    return id + ".result.json"


def _validate_widgets(
    widgets: Value, mut seen: List[String], ctx: String
) raises -> String:
    """Validate one container's widget array (the root board or a page),
    accumulating ids into `seen` — ids are GLOBALLY unique (they name snapshot
    files). Returns "" when acceptable."""
    var items = widgets.array_items()
    for i in range(len(items)):
        ref w = items[i]
        if not w.is_object():
            return ctx + ": each widget must be an object"
        if not _has(w, "id") or not w["id"].is_string():
            return ctx + ": each widget needs a string id"
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
        # Optional program binding: the content-addressed snapshot's hash.
        var prog_hash = String("")
        if _has(w, "program"):
            if not w["program"].is_string() or not _is_hex16(
                w["program"].string_value()
            ):
                return "widget " + id + ": program must be a 16-hex-char hash"
            prog_hash = w["program"].string_value()
        # The view plane may only reference widgets whose DATA-plane snapshot
        # (the pinned program) exists — binding to results, never to raw reads.
        var bound = prog_hash.byte_length() > 0 and exists(
            millwright_dir() + "/" + _program_hash_doc(prog_hash)
        )
        if not bound and not exists(millwright_dir() + "/" + _program_doc(id)):
            return "widget " + id + " has no pinned program"
        seen.append(id^)
    return String("")


def _validate_layout(container: Value, seen: List[String]) raises -> String:
    """Validate one container's optional layout against ITS widget ids
    (`seen` holds all ids seen so far; order refs must be among them)."""
    if not _has(container, "layout"):
        return String("")
    var lo = container["layout"]
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


def _page_id_ok(id: String) -> Bool:
    """Page ids are `p-` + [a-z0-9-] — the nav URL segment."""
    if not id.startswith("p-") or id.byte_length() < 3:
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


def validate_spec(text: String) raises -> String:
    """Shape-lint a dashboard spec. Returns "" when acceptable, else a human
    reason. This runs BEFORE a spec becomes a version — invariant 4 of the
    design (a broken spec never bricks the app) starts here. v2 §2: an optional
    `pages[]` (named boards → top-level nav buttons AFTER the built-ins,
    additive-only, capped at 5); widget ids are unique across ALL containers."""
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
    var why = _validate_widgets(v["widgets"], seen, "board")
    if why.byte_length() > 0:
        return why^
    var root_count = len(seen)
    _ = root_count  # root layout may only reference root widgets — but ids are
    # globally unique and pages are validated AFTER, so `seen` here is exactly
    # the root set when the root layout is checked.
    why = _validate_layout(v, seen)
    if why.byte_length() > 0:
        return why^
    if _has(v, "pages"):
        if not v["pages"].is_array():
            return '"pages" must be an array'
        var pages = v["pages"].array_items()
        if len(pages) > 5:
            return "at most 5 pages (the nav is a shared, capped surface)"
        var page_ids = List[String]()
        for i in range(len(pages)):
            ref pg = pages[i]
            if not pg.is_object():
                return "each page must be an object"
            if not _has(pg, "id") or not pg["id"].is_string():
                return "each page needs a string id"
            var pid = pg["id"].string_value()
            if not _page_id_ok(pid):
                return "page id must be p- followed by [a-z0-9-]: " + pid
            for j in range(len(page_ids)):
                if page_ids[j] == pid:
                    return "duplicate page id: " + pid
            if (
                not _has(pg, "title")
                or not pg["title"].is_string()
                or pg["title"].string_value().byte_length() == 0
            ):
                return "page " + pid + " needs a non-empty title"
            if not _has(pg, "widgets") or not pg["widgets"].is_array():
                return "page " + pid + ' needs a "widgets" array'
            var before = len(seen)
            why = _validate_widgets(pg["widgets"], seen, "page " + pid)
            if why.byte_length() > 0:
                return why^
            # The page layout may only reference the PAGE's widgets.
            var page_seen = List[String]()
            for k in range(before, len(seen)):
                page_seen.append(seen[k].copy())
            why = _validate_layout(pg, page_seen)
            if why.byte_length() > 0:
                return why^
            page_ids.append(pid^)
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


def _seed_if_empty():
    """First run only: materialize the CURATED STARTER BOARD (millwright_seed) as
    version 1 — programs + preview-flagged results first (the lint requires the
    program docs), then the seed spec through the ordinary _accept_spec path.
    Idempotent and deliberately conservative: it runs ONLY when NO version chain
    exists at all — an emptied board stays empty (deletions are respected). Any
    failure is swallowed: a seeding hiccup must never take down GET /api/millwright
    (the board just starts blank, as v1 did)."""
    try:
        if exists(millwright_log_path()):
            return
        if default_kv_store().exists(KV_MILLWRIGHT_ACTIVE):
            return
        try:
            makedirs(millwright_dir())
        except:
            pass  # already exists
        var docs = default_millwright_docs_store()
        var ids = seed_widget_ids()
        var programs = seed_programs()
        var previews = seed_results()
        for i in range(len(ids)):
            docs.save(_program_doc(ids[i]), programs[i])
            docs.save(
                _result_doc(ids[i]),
                '{"ts":0,"preview":true,"result":' + previews[i] + "}",
            )
        _ = _accept_spec(
            String(SEED_SPEC), String(SEED_MESSAGE), String(SEED_AUTHOR)
        )
    except:
        pass  # never let seeding break the board


def handle_millwright() raises -> Response:
    """GET /api/millwright → {"active","spec","results":{id:{ts,result}}} —
    everything the dashboard tab needs in one call. Widgets whose cached result
    is missing/torn simply have no entry (the tile renders as pending)."""
    _seed_if_empty()  # first run → the curated starter board (v2 §1)
    var spec_text = _active_spec_text()
    var out = String("{")
    out += '"active":' + json_escape(_active_hash())
    out += ',"spec":' + spec_text
    out += ',"results":{'
    var docs = default_millwright_docs_store()
    var first = True
    try:
        var spec = loads(spec_text)
        var all_widgets = _all_widgets(spec)
        for i in range(len(all_widgets)):
            ref w = all_widgets[i]
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
    var prog_hash = _fnv1a64(code)
    docs.save(_program_hash_doc(prog_hash), code)
    if result_text.byte_length() > 0:
        docs.save(
            _result_doc(id),
            '{"ts":'
            + String(ts)
            + ',"program":'
            + json_escape(prog_hash)
            + ',"result":'
            + result_text
            + "}",
        )
    # View-plane: append the widget + a layout slot, accept as a new version.
    # (json Values are copy-on-write views — mutate the child, then set() it
    # back on the parent so the parent's tape sees the change.)
    var widget_json = String("{")
    widget_json += '"id":' + json_escape(id)
    widget_json += ',"title":' + json_escape(title)
    widget_json += ',"q":' + json_escape(q)
    widget_json += ',"program":' + json_escape(prog_hash)
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
    var spec_text = _active_spec_text()
    if spec_text.find(json_escape(id)) == -1:
        return _cors(bad_request('{"error":"widget not in the active spec"}'))
    # Stamp the widget's CURRENT program hash so the tile can tell a fresh
    # result from one computed by an older program (the staleness signal).
    var prog_hash = _widget_program_hash(spec_text, id)
    var stamp = String("")
    if prog_hash.byte_length() > 0:
        stamp = ',"program":' + json_escape(prog_hash)
    default_millwright_docs_store().save(
        _result_doc(id),
        '{"ts":'
        + String(_epoch_s())
        + stamp
        + ',"result":'
        + result_text
        + "}",
    )
    return _cors(ok_json('{"ok":true}'))


def handle_millwright_program(req: Request) raises -> Response:
    """GET /api/millwright/program?id=w-… → {"id","program"} — the client feeds
    this to the existing `run` WS frame for a manual widget refresh (the same
    deterministic re-execution as history's Run again)."""
    var id = String(req.query_param("id"))
    if not _path_safe_id(id):
        return _cors(bad_request('{"error":"bad widget id"}'))
    var spec_text = _active_spec_text()
    var program = _program_text(spec_text, id)
    if program.byte_length() == 0:
        return _cors(bad_request('{"error":"unknown widget"}'))
    return _cors(
        ok_json(
            '{"id":'
            + json_escape(id)
            + ',"hash":'
            + json_escape(_widget_program_hash(spec_text, id))
            + ',"program":'
            + json_escape(program)
            + "}"
        )
    )


# ── model-assisted spec edit (v1 slice 3) ────────────────────────────────────


def _widget_catalog() raises -> String:
    """The catalog the view-editing model sees: per widget its id, title, the
    original question, and the SHAPES of its cached result (block kinds only —
    "kpi"/"table"/"series"/"map"/"pie"). Names and shapes, never values — the
    same alias boundary the manifest keeps for programs."""
    var docs = default_millwright_docs_store()
    var out = String("[")
    var first = True
    var spec = loads(_active_spec_text())
    var widgets = spec["widgets"].array_items()
    for i in range(len(widgets)):
        ref w = widgets[i]
        if not _has(w, "id") or not w["id"].is_string():
            continue
        var id = w["id"].string_value()
        var entry = String("{")
        entry += '"id":' + json_escape(id)
        if _has(w, "title") and w["title"].is_string():
            entry += ',"title":' + json_escape(w["title"].string_value())
        if _has(w, "q") and w["q"].is_string():
            entry += ',"q":' + json_escape(w["q"].string_value())
        entry += ',"shapes":['
        try:
            var snap = loads(docs.load(_result_doc(id)))
            if _has(snap, "result") and _has(snap["result"], "data"):
                var blocks = snap["result"]["data"].array_items()
                for b in range(len(blocks)):
                    if (
                        _has(blocks[b], "kind")
                        and blocks[b]["kind"].is_string()
                    ):
                        if b > 0:
                            entry += ","
                        entry += json_escape(blocks[b]["kind"].string_value())
        except:
            pass  # no snapshot yet — an empty shape list is honest
        entry += "]}"
        if not first:
            out += ","
        out += entry
        first = False
    out += "]"
    return out^


def handle_millwright_assist(req: Request) raises -> Response:
    """POST /api/millwright/assist {"instruction"} → the model edits the spec.
    The call rides enclave's transport (the app's ONLY Anthropic egress:
    EgressGuard, budget, codegen disk cache, prompt caching) with the viewgen
    system prompt. The reply is validated by the SAME lint as a hand edit before
    it becomes a version — the model can propose, only `_accept_spec` disposes.
    """
    if _is_demo():
        return _cors(
            unauthorized('{"error":"the demo dashboard is read-only"}')
        )
    var instruction: String
    try:
        instruction = String(loads(req.text())["instruction"].string_value())
    except:
        return _cors(bad_request('{"error":"expected {instruction}"}'))
    if instruction.strip().byte_length() == 0:
        return _cors(bad_request('{"error":"empty instruction"}'))
    var spec_text = _active_spec_text()
    var reply: String
    try:
        var cfg = load_config()
        _apply_persisted_apikey(cfg)
        var harness = build_vault_harness(cfg, resolve_vault_dir())
        reply = harness.viewgen_edit(instruction, spec_text, _widget_catalog())
    except e:
        return _cors(bad_request('{"error":' + json_escape(String(e)) + "}"))
    var new_spec: String
    var message = String("model edit")
    try:
        var v = loads(reply)
        new_spec = v["spec"].raw_json()
        if _has(v, "message") and v["message"].is_string():
            var m = v["message"].string_value()
            if m.byte_length() > 0:
                message = m^
    except:
        return _cors(
            bad_request(
                '{"error":"the model did not return a valid spec edit — try'
                ' rephrasing"}'
            )
        )
    var hash: String
    try:
        hash = _accept_spec(new_spec, message, "model")
    except e2:
        # The lint rejected the model's spec — surface WHY (the UI shows it and
        # the user can rephrase); nothing was committed.
        return _cors(bad_request('{"error":' + json_escape(String(e2)) + "}"))
    return _cors(
        ok_json(
            '{"ok":true,"hash":'
            + json_escape(hash)
            + ',"message":'
            + json_escape(message)
            + "}"
        )
    )


def handle_millwright_program_save(req: Request) raises -> Response:
    """POST /api/millwright/program {"id", "code"} → edit a widget's program
    (v2 §3). The code becomes a NEW content-addressed snapshot and the widget's
    spec `program` binding moves to it — so the edit is a spec version (message
    names the widget, author "user") and reverting the spec reverts the program
    binding too. The previous snapshot stays on disk (immutable), which is what
    makes that revert work. Compile feedback is deliberately NOT here: the tile's
    ↻ runs the program through the existing deterministic run path, which streams
    compile errors back — same honesty as Run-again. The user's own edit needs no
    approval card (self-approving; the sandbox is the safety boundary either way).
    """
    if _is_demo():
        return _cors(
            unauthorized('{"error":"the demo dashboard is read-only"}')
        )
    var id: String
    var code: String
    try:
        var body = loads(req.text())
        id = String(body["id"].string_value())
        code = String(body["code"].string_value())
    except:
        return _cors(bad_request('{"error":"expected {id, code}"}'))
    if not _path_safe_id(id):
        return _cors(bad_request('{"error":"bad widget id"}'))
    if code.strip().byte_length() == 0:
        return _cors(bad_request('{"error":"empty program"}'))
    if code.byte_length() > 65536:
        return _cors(bad_request('{"error":"program too large (64 KB cap)"}'))
    var spec = loads(_active_spec_text())
    var prog_hash = _fnv1a64(code)
    # Find the widget in the ROOT board or on a PAGE, rebind its `program`, and
    # write the mutated container back up the copy-on-write chain.
    var title = String("")
    var widgets = spec["widgets"]
    var items = widgets.array_items()
    for i in range(len(items)):
        ref w = items[i]
        if (
            _has(w, "id")
            and w["id"].is_string()
            and w["id"].string_value() == id
        ):
            title = (
                w["title"].string_value() if _has(w, "title")
                and w["title"].is_string() else id
            )
            var w2 = items[i].copy()
            w2.set("program", Value(prog_hash))
            widgets.set(i, w2)
            spec.set("widgets", widgets)
            break
    if (
        title.byte_length() == 0
        and _has(spec, "pages")
        and spec["pages"].is_array()
    ):
        var pages = spec["pages"]
        var pitems = pages.array_items()
        for k in range(len(pitems)):
            var pg = pitems[k].copy()
            if not _has(pg, "widgets") or not pg["widgets"].is_array():
                continue
            var pws = pg["widgets"]
            var pw_items = pws.array_items()
            for i in range(len(pw_items)):
                ref w = pw_items[i]
                if (
                    _has(w, "id")
                    and w["id"].is_string()
                    and w["id"].string_value() == id
                ):
                    title = (
                        w["title"].string_value() if _has(w, "title")
                        and w["title"].is_string() else id
                    )
                    var w2 = pw_items[i].copy()
                    w2.set("program", Value(prog_hash))
                    pws.set(i, w2)
                    pg.set("widgets", pws)
                    pages.set(k, pg)
                    spec.set("pages", pages)
                    break
            if title.byte_length() > 0:
                break
    if title.byte_length() == 0:
        return _cors(bad_request('{"error":"widget not in the active spec"}'))
    default_millwright_docs_store().save(_program_hash_doc(prog_hash), code)
    var hash: String
    try:
        hash = _accept_spec(
            spec.raw_json(),
            String('edited the program for "') + title + '"',
            "user",
        )
    except e:
        return _cors(bad_request('{"error":' + json_escape(String(e)) + "}"))
    return _cors(
        ok_json(
            '{"ok":true,"program":'
            + json_escape(prog_hash)
            + ',"hash":'
            + json_escape(hash)
            + "}"
        )
    )

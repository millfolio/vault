"""handlers_tags — the category-tags panel + editor + AI-tag backfill handlers.

Everything the Tags view drives, all in-process via `vault.derive.*` (the SAME
registry/tags/retag store the `millfolio` CLI uses — no engine spawn for the
deterministic parts):
  • GET  /api/tags                 — the panel's list (names + keywords + counts).
  • GET/POST /api/categories       — the editable registry file (read / save+retag).
  • POST /api/categories/preview   — dry-run edited rules (validation loop).
  • GET  /api/backfill/status      — per-AI-tag backfill progress.
  • POST /api/backfill/run         — run ONE bounded backfill slice via the engine.
  • POST /api/{orchestrator,backfill}/{pause,resume,priority} — the global throttle.
  • POST /api/tags/preview-ai      — time-boxed preview of an AI rule.
  • POST /api/tags/add             — append a keyword|AI rule + retag.
  • GET  /api/tags/missing-defaults, POST /api/tags/add-defaults — built-in defaults.

Phase-1B slice 2: pure moves of the `Api.handle_*` methods to free functions.
None deref `self.st`; the `self`-qualified helper calls resolve to the
already-extracted leaf modules (`osutil`, `httputil`, `events`,
`vault.derive.tags`, `vault.derive.store`). The one use of the server-local
`_json_escape` is replaced with the byte-identical `events.json_escape` (zero
behaviour change). `server._route` now delegates here.
"""

from flare.prelude import *

from json import loads

from vault.derive.tags import read_categories
from vault.derive.store import (
    tags_report_json,
    save_categories,
    preview_categories,
    backfill_status_json,
    ml_backfill_slice,
    set_pause,
    set_priority,
    preview_ml_json,
    add_category,
    missing_default_tags_json,
    add_default_tags,
)

from osutil import _is_demo, _engine_url, _epoch_s
from httputil import _cors, _forbidden
from events import json_escape
from work_orchestrator import _append_operation


def _record_retag_op(detail: String, changed: Int):
    """Append a completed `retag` record to operations.jsonl so a rules change is
    VISIBLE in the Operations tab (and the status-bar ops chip). The deterministic
    re-tag runs synchronously inside the request — no queued work item ever
    appears — which used to read as "I saved the tag and the refresh never ran".
    """
    var now = _epoch_s()
    _append_operation(
        String("retag"), now, now, String("done"), detail, -1, -1, changed
    )


def handle_tags() raises -> Response:
    """GET /api/tags → {"tags":[{name,keywords,count}]} for the Tags panel —
    in-process (vault.derive.store), the SAME payload `millfolio tags --json`
    prints. No engine spawn."""
    return _cors(ok_json(tags_report_json()))


def handle_categories_get() raises -> Response:
    """GET /api/categories → {"text": <raw categories.txt>} for the editor
    (the file is seeded with the built-in defaults if absent)."""
    return _cors(ok_json('{"text":' + json_escape(read_categories()) + "}"))


def handle_categories_save(req: Request) raises -> Response:
    """POST /api/categories {"text": …} → overwrite categories.txt (it becomes
    the user's authoritative registry) and re-tag the stored transactions
    in-process. Returns {"ok":true,"retagged":N}."""
    var text: String
    try:
        var j = loads(req.text())
        text = j["text"].string_value()
    except:
        return _cors(bad_request('{"error":"expected {text}"}'))
    var changed = save_categories(text)
    _record_retag_op(String("category rules saved"), changed)
    return _cors(ok_json('{"ok":true,"retagged":' + String(changed) + "}"))


def handle_categories_preview(req: Request) raises -> Response:
    """POST /api/categories/preview {"text": …} → dry-run the edited rules over
    the stored transactions WITHOUT saving (the validation loop): per-tag match
    counts + a few example descriptions to spot false positives before saving.
    Returns {"tags":[{name,ml,count,examples}]} from preview_categories."""
    var text: String
    try:
        var j = loads(req.text())
        text = j["text"].string_value()
    except:
        return _cors(bad_request('{"error":"expected {text}"}'))
    return _cors(ok_json(preview_categories(text)))


def handle_backfill_status() raises -> Response:
    """GET /api/backfill/status → per-AI-tag backfill progress
    (`{status,paused_until,perTag:[…],pendingTotal}`) for the Tags-tab
    Backfill panel. Lock-free read; no engine call."""
    return _cors(ok_json(backfill_status_json()))


def handle_backfill_run() raises -> Response:
    """POST /api/backfill/run → run ONE bounded backfill slice (a
    generation-batch) via the on-device engine, then return the fresh status.
    The UI loops this until `pendingTotal` hits 0, so each call stays short and
    shows progress. Non-blocking try-lock inside → returns changed:0 when
    another writer holds it or backfill is paused."""
    var changed = 0
    try:
        changed = ml_backfill_slice(_engine_url())
    except e:
        # Engine down / chat model not serving → best-effort, report 0 + status.
        print("  backfill slice skipped: ", String(e), sep="")
    return _cors(
        ok_json(
            '{"ok":true,"changed":'
            + String(changed)
            + ',"status":'
            + backfill_status_json()
            + "}"
        )
    )


def handle_backfill_pause(req: Request) raises -> Response:
    """POST /api/backfill/pause {"seconds":N} → pause the between-questions
    worker for N seconds (auto-resumes when it elapses). Returns the status.
    """
    var seconds: Int
    try:
        var j = loads(req.text())
        seconds = Int(j["seconds"].int_value())
    except:
        return _cors(bad_request('{"error":"expected {seconds}"}'))
    set_pause(seconds)
    return _cors(ok_json('{"ok":true,"status":' + backfill_status_json() + "}"))


def handle_backfill_resume() raises -> Response:
    """POST /api/backfill/resume → clear any pause (resume now)."""
    set_pause(0)
    return _cors(ok_json('{"ok":true,"status":' + backfill_status_json() + "}"))


def handle_backfill_priority(req: Request) raises -> Response:
    """POST /api/backfill/priority {"priority":"high"|"medium"|"low"} → set the
    background backfiller's throttle. Low naps ~5s between classify slices (GPU
    mostly free), high ~0.1s (fastest). Returns the fresh status (with priority).
    """
    var p: String
    try:
        var j = loads(req.text())
        p = j["priority"].string_value()
    except:
        return _cors(bad_request('{"error":"expected {priority}"}'))
    set_priority(p)
    return _cors(ok_json('{"ok":true,"status":' + backfill_status_json() + "}"))


def handle_tags_preview_ai(req: Request) raises -> Response:
    """POST /api/tags/preview-ai {"prompt":…} → time-boxed (~5s) preview of an
    AI rule over the stored transactions, WITHOUT persisting anything. Returns
    {matched, evaluated, total} so the UI can show "≈N records would match"
    before the user creates the tag."""
    var prompt: String
    try:
        var j = loads(req.text())
        prompt = j["prompt"].string_value()
    except:
        return _cors(bad_request('{"error":"expected {prompt}"}'))
    if String(prompt.strip()) == "":
        return _cors(bad_request('{"error":"empty prompt"}'))
    try:
        return _cors(ok_json(preview_ml_json(_engine_url(), prompt)))
    except e:
        return _cors(
            bad_request(
                '{"error":"preview failed — is the engine up? '
                + json_escape(String(e))
                + '"}'
            )
        )


def handle_tags_add(req: Request) raises -> Response:
    """POST /api/tags/add {"name":…, "prompt"?:…, "keywords"?:…} → append a new
    category rule (AI rule when `prompt` is set, else a keyword rule) to
    categories.txt and re-tag. Returns {"ok":true,"retagged":N}. An AI rule
    backfills afterwards via the worker / Backfill now."""
    var name: String
    var prompt: String
    var keywords: String
    try:
        var j = loads(req.text())
        name = j["name"].string_value()
        try:
            prompt = j["prompt"].string_value()
        except:
            prompt = String("")
        try:
            keywords = j["keywords"].string_value()
        except:
            keywords = String("")
    except:
        return _cors(
            bad_request('{"error":"expected {name, prompt|keywords}"}')
        )
    if String(name.strip()) == "":
        return _cors(bad_request('{"error":"empty name"}'))
    var changed = add_category(name, keywords, prompt)
    _record_retag_op(String("tag '") + name + "' added", changed)
    return _cors(ok_json('{"ok":true,"retagged":' + String(changed) + "}"))


def handle_tags_missing_defaults() raises -> Response:
    """GET /api/tags/missing-defaults → {"tags":[{name,description},…]}: the
    built-in default tags NOT present in the user's category set. Non-empty only
    after an upgrade added a default the user's edited categories.txt never got
    (e.g. `transfers`, `rewards`) — the Tags view offers to add them. Read-only.
    """
    return _cors(ok_json('{"tags":' + missing_default_tags_json() + "}"))


def handle_tags_add_defaults(req: Request) raises -> Response:
    """POST /api/tags/add-defaults {"names":[…]} → APPEND those built-in default
    rules that are missing from categories.txt (preserving the user's edits) and
    re-tag. Returns {"ok":true,"added":N}. A name that isn't a missing default is
    ignored. Not available in the demo (its registry is fixed)."""
    if _is_demo():
        return _cors(_forbidden('{"error":"not available in demo"}'))
    var names = List[String]()
    try:
        var j = loads(req.text())
        var arr = j["names"]
        for i in range(arr.array_count()):
            names.append(String(arr[i].string_value()))
    except:
        return _cors(bad_request('{"error":"expected {names:[…]}"}'))
    var added = add_default_tags(names)
    if added > 0:
        _record_retag_op(
            String("default tags added (") + String(added) + ")", -1
        )
    return _cors(ok_json('{"ok":true,"added":' + String(added) + "}"))

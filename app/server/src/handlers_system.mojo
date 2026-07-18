"""handlers_system — the read-only system / stats / history / gpu handlers.

The endpoints that surface WHERE data + logs live and the accumulated
per-question usage, plus the tiny liveness/telemetry probes:
  • GET  /health          — liveness.
  • GET  /api/gpu         — instantaneous GPU / memory / disk utilization.
  • GET  /api/stats       — the usage log (JSONL, returned verbatim) + backfill dedup.
  • GET  /api/history     — the full ask history (asks.jsonl).
  • POST /api/history/delete — drop one question's records from the history.
  • GET  /api/system      — where the data + logs live, plus version/model.

Phase-1B slice 2: pure moves of the `Api.handle_*` methods (and the inline
`/health` + `/api/gpu` route bodies) to free functions. None deref `self.st`, so
each takes just `req` (or nothing); the `self`-qualified helper calls resolve to
the already-extracted leaf modules (`osutil`, `sysmetrics`, `httputil`, `events`,
`store`, `vault.storage`, `vault.derive.store`). `server._route` now delegates
here. Behaviour is identical.

`_stats_path` / `_asks_path` (thin wrappers over the storage seam) move with
`handle_system`, their only caller.
"""

from std.os import getenv

from flare.prelude import *
from flare.http import HttpClient

from json import loads

from vault.storage import (
    default_stats_store,
    default_asks_store,
    stats_log_path,
    asks_log_path,
    FileLogStore,
)
from vault.derive.store import backfill_dedup_json

from osutil import (
    _config_dir,
    _model_label,
    _app_version,
    _engine_url,
    _is_demo,
    _epoch_s,
)
from sysmetrics import _gpu_util_pct, _memory_used_pct, _disk_used_pct
from httputil import _cors
from events import json_escape
from record_builders import (
    history_records_array,
    system_json,
    delete_ask_records,
)


def handle_health() raises -> Response:
    """GET /health → a plain-text liveness probe."""
    return _cors(ok("millfolio ok"))


# High-frequency polls the UI fires every ~2s — logging them would drown the
# access log in noise, so they're skipped (a page load / chat / model query is the
# meaningful "access").
comptime _ACCESS_SKIP = String(
    " /api/gpu /api/backfill/status /api/scheduler/queue"
    " /api/index/status /health /api/model /favicon.svg /favicon.png "
)


def log_demo_access(req: Request, path: String):
    """Append one demo access record — timestamp, Cloudflare client IP, user
    agent, method, path — to `demo-access.jsonl`. DEMO ONLY (the real product is
    a local single-user install with no remote visitors, so logging IPs there
    would be a privacy regression). Best-effort: a write failure never affects the
    response. The remote IP comes from Cloudflare's `cf-connecting-ip` header
    (cloudflared forwards it); `x-forwarded-for` is the fallback. Skips the
    high-frequency telemetry polls so the log stays a readable record of real
    visits. Enable/disable with MILLFOLIO_ACCESS_LOG (default: on in demo)."""
    try:
        if not _is_demo():
            return
        if getenv("MILLFOLIO_ACCESS_LOG", "1") == "0":
            return
        if _ACCESS_SKIP.find(" " + path + " ") != -1:
            return
        var ip = String(req.headers.get("cf-connecting-ip"))
        if ip == "":
            ip = String(req.headers.get("x-forwarded-for"))
        if ip == "":
            ip = String("-")
        var ua = String(req.headers.get("user-agent"))
        if ua == "":
            ua = String("-")
        var line = (
            '{"ts":'
            + String(_epoch_s())
            + ',"ip":'
            + json_escape(ip)
            + ',"ua":'
            + json_escape(ua)
            + ',"path":'
            + json_escape(path)
            + "}"
        )
        FileLogStore(_config_dir() + "/demo-access.jsonl").append(line)
    except:
        pass  # access logging is best-effort; never break a request over it


def _engine_decode_health() -> String:
    """The engine's decode-health fragment for /api/gpu, from its GET /v1/status
    (engine ≥ the decode-wedge tripwire build). A wedged Metal command queue keeps
    the engine "responding" while DECODE collapses to ~0.3 tok/s — GPU util / mem
    all look fine, so this is the field the bottom-bar indicator keys on. Emits
    `,"decodeHealthy":<bool>,"decodeTps":<n>` ONLY when the engine reports it (older
    engine, engine down, or no generation yet → nothing, so the UI shows no chip).
    Best-effort + short timeout: the 2s telemetry poll must never block on it.
    """
    var base = _engine_url()  # e.g. http://127.0.0.1:8000/v1
    var url = base + "/status"
    try:
        var client = HttpClient()
        client.set_recv_timeout(1500)  # never stall the telemetry poll
        var resp = client.send(Request(method="GET", url=url))
        var v = resp.json()
        # decode_tok_per_s is null until the first real generation → skip then.
        if not v["decode_tok_per_s"].is_number():
            return String("")
        var healthy = v["decode_healthy"].bool_value()
        var tps = v["decode_tok_per_s"].float_value()
        return (
            ',"decodeHealthy":'
            + ("true" if healthy else "false")
            + ',"decodeTps":'
            + String(tps)
        )
    except:
        return String("")  # older engine / down / no field — silent


def handle_gpu() raises -> Response:
    """GET /api/gpu → instantaneous GPU utilization (%) plus memory-used and
    disk-used percentages; the bottom bar keeps a 30s average. Also relays the
    engine's decode-health signal (when available) so the app can flag a wedged
    Metal decode queue that GPU/mem metrics don't reveal."""
    return _cors(
        ok_json(
            '{"util":'
            + String(_gpu_util_pct())
            + ',"mem":'
            + String(_memory_used_pct())
            + ',"disk":'
            + String(_disk_used_pct())
            + _engine_decode_health()
            + "}"
        )
    )


def handle_stats() raises -> Response:
    """Return the usage log as {"model": <label>, "records": [<obj>, …]}. The file
    is JSONL (each line is already a valid object), so we comma-join the non-empty
    lines into an array — no server-side JSON parsing. Missing file → empty list.
    """
    var recs = String("")
    var first = True
    try:
        var raw = default_stats_store().read_all()
        var lines = raw.split("\n")
        for i in range(len(lines)):
            var ln = String(lines[i]).strip()
            if ln.byte_length() == 0:
                continue
            if not first:
                recs += ","
            recs += ln
            first = False
    except:
        pass
    return _cors(
        ok_json(
            '{"model":'
            + json_escape(_model_label())
            + ',"records":['
            + recs
            + '],"backfill":'
            + backfill_dedup_json()
            + "}"
        )
    )


def handle_history() raises -> Response:
    """Return the full ask history as {"records": [<obj>, …]} — the durable
    backend store (`asks.jsonl`) of every question with its generated program
    and answer. JSONL, so we comma-join the non-empty lines into an array — no
    server-side JSON parsing. Missing file → empty list. Newest first so the UI
    panel shows the most recent ask at the top."""
    var raw = String("")
    try:
        raw = default_asks_store().read_all()
    except:
        pass  # missing file → empty history
    return _cors(ok_json('{"records":' + history_records_array(raw) + "}"))


def handle_history_delete(req: Request) raises -> Response:
    """POST /api/history/delete {"q": …} → remove that question's records from
    the durable `asks.jsonl` (the recent-questions panel dedups by question, so
    this deletes the entry for good). Missing file / empty q is a no-op success.
    Returns {"ok":true}."""
    var q: String
    try:
        var j = loads(req.text())
        q = j["q"].string_value()
    except:
        return _cors(bad_request('{"error":"expected {q}"}'))
    if q == "":
        return _cors(ok_json('{"ok":true}'))
    var raw: String
    try:
        raw = default_asks_store().read_all()
    except:
        return _cors(ok_json('{"ok":true}'))  # nothing to delete
    var filtered = delete_ask_records(raw, q)
    try:
        default_asks_store().rewrite(filtered)
    except:
        return _cors(bad_request('{"error":"could not update history"}'))
    return _cors(ok_json('{"ok":true}'))


def _stats_path() -> String:
    """Where per-question usage records accumulate (JSONL). MILLFOLIO_STATS_FILE
    overrides; defaults under the config dir (which `cp -R` deploys never delete).
    Resolved by the storage seam (`stats_log_path`) — the System page reads it here;
    the read/append go through `default_stats_store()`."""
    return stats_log_path()


def _asks_path() -> String:
    """Where the FULL per-ask history accumulates (JSONL): the question, the
    GENERATED program, and the answer. Durable + on-device under the config dir
    (which `cp -R` deploys never delete) — survives a browser-data clear, unlike
    the UI's localStorage. MILLFOLIO_ASKS_FILE overrides. Resolved by the storage
    seam (`asks_log_path`); the System page reads it here, read/append/delete go
    through `default_asks_store()`."""
    return asks_log_path()


def handle_system() raises -> Response:
    """System info for the System tab: WHERE the data + logs live, so a user can
    find a per-ask transcript (the generated program + its run output) when an
    answer looks wrong, plus the running version/model. Paths are computed from
    $HOME so they stay correct across machines; the log locations mirror the ones
    the `mill` CLI's launch agents write to."""
    return _cors(
        ok_json(
            system_json(
                getenv("HOME", ""),
                _app_version(),
                _config_dir(),
                _stats_path(),
                _asks_path(),
            )
        )
    )

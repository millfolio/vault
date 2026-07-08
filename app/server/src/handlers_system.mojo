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

from json import loads

from vault.storage import (
    default_stats_store,
    default_asks_store,
    stats_log_path,
    asks_log_path,
)
from vault.derive.store import backfill_dedup_json

from osutil import _config_dir, _model_label, _app_version
from sysmetrics import _gpu_util_pct, _memory_used_pct, _disk_used_pct
from httputil import _cors
from events import json_escape
from store import history_records_array, system_json, delete_ask_records


def handle_health() raises -> Response:
    """GET /health → a plain-text liveness probe."""
    return _cors(ok("millfolio ok"))


def handle_gpu() raises -> Response:
    """GET /api/gpu → instantaneous GPU utilization (%) plus memory-used and
    disk-used percentages; the bottom bar keeps a 30s average."""
    return _cors(
        ok_json(
            '{"util":'
            + String(_gpu_util_pct())
            + ',"mem":'
            + String(_memory_used_pct())
            + ',"disk":'
            + String(_disk_used_pct())
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

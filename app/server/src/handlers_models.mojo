"""handlers_models — the on-device model catalog / selection / download handlers.

The engine serves ONE model per process (chosen at launch). This module owns the
whole model surface the UI drives:
  • GET  /api/model                   — the running model name + version (+ turnstile).
  • GET  /api/models                  — the switchable-model list + current selection.
  • POST /api/models/select           — switch the model (rewrite config + restart engine).
  • POST /api/models/download         — start a background weights download.
  • GET  /api/models/download/status  — poll download progress.

plus the model-catalog / HF-cache / native-downloader helpers those handlers build
on, and `_provision_worker` — the detached startup thread `server.main` spawns to
ensure the required embedding model + a default chat model are present.

Phase-1B slice 2: pure moves of the `Api.handle_model_*` methods (and the inline
`/api/model` + `/api/models` + `/api/models/download/status` route bodies, now free
`handle_*` functions) plus the model helper cluster. None deref `self.st`; the
`self`-qualified helper calls resolve to the already-extracted leaf modules
(`osutil`, `sysmetrics`, `auth`, `httputil`, `events`, `vault.storage`,
`scheduler_loop`). `scheduler_loop` never imports this module, so it stays
acyclic. `server._route`/`server.main` now delegate here. Behaviour is identical.
"""

from std.os import getenv, listdir, makedirs
from std.os.path import exists
from std.ffi import external_call

from flare.prelude import *
from flare.http import HttpClient
from flare.runtime._thread import _OpaquePtr

from json import loads

from vault.storage import default_kv_store, KV_DL_STATE, KV_DL_MODEL

from osutil import (
    _config_dir,
    _cstr,
    _is_demo,
    _model_label,
    _app_version,
    _installed_version,
    _engine_url,
)
from sysmetrics import _memory_gb
from auth import _turnstile_sitekey, _turnstile_enabled
from httputil import unauthorized, _cors
from events import json_escape
from scheduler_loop import _kv_set, _write_small

# Weight provisioning (downloads moved OUT of the installer, INTO this server).
comptime DEFAULT_CHAT_MODEL = "Qwen/Qwen2.5-3B-Instruct"
comptime EMBED_MODEL = "Qwen/Qwen3-Embedding-0.6B"


# ── HTTP handlers ────────────────────────────────────────────────────────────


def handle_model_info() raises -> Response:
    """GET /api/model → the on-device model name + running version (the UI's bottom
    bar), plus the Turnstile sitekey (non-empty only when the demo gate is active —
    the client renders the widget iff it's present). `installed` (the on-disk
    bundle version, read per request) is included only when a bundle exists AND
    it differs from the running version — its presence IS the "restart to apply"
    signal, so the client needs no version comparison of its own."""
    var sitekey = _turnstile_sitekey() if _turnstile_enabled() else String("")
    var body = String('{"model":') + json_escape(_model_label())
    body += ',"version":' + json_escape(_app_version())
    var installed = _installed_version()
    if installed.byte_length() > 0 and installed != _app_version():
        body += ',"installed":' + json_escape(installed)
    body += ',"turnstile_sitekey":' + json_escape(sitekey) + "}"
    return _cors(ok_json(body))


def handle_models_list() raises -> Response:
    """GET /api/models → the on-device model selector: the list of switchable
    (cached) models + the current selection + host memory. POST /api/models/select
    switches it (restarts the engine)."""
    return _cors(
        ok_json(
            '{"current":'
            + json_escape(_current_model_id())
            + ',"loaded":'
            + json_escape(_engine_loaded_model())
            + ',"memoryGb":'
            + String(_memory_gb())
            + ',"available":'
            + _available_models_json()
            + "}"
        )
    )


def handle_models_download_status() raises -> Response:
    """GET /api/models/download/status → the in-flight (or last) download's progress."""
    return _cors(ok_json(_download_status_json()))


def handle_model_select(req: Request) raises -> Response:
    """POST /api/models/select {"model": "<hf-id>"} → switch the on-device model.
    Rewrites the engine config's `model` and restarts the engine LaunchAgent (a
    few seconds of reload). Only cached models are accepted, and never in the
    public demo (it would restart the shared engine). Returns {"ok":true,"model"}.
    """
    if _is_demo():
        return _cors(
            unauthorized('{"error":"model switching is disabled in the demo"}')
        )
    var id: String
    try:
        id = String(loads(req.text())["model"].string_value())
    except:
        return _cors(bad_request('{"error":"expected {model}"}'))
    if id == "":
        return _cors(bad_request('{"error":"empty model"}'))
    # Only allow a model that (a) appears in the catalog/available list AND (b) is
    # actually DOWNLOADED, so we never restart the engine into a checkpoint that's
    # missing (the available list now includes not-yet-downloaded catalog models).
    if _available_models_json().find(json_escape(id)) == -1:
        return _cors(bad_request('{"error":"unknown model"}'))
    if not _model_downloaded(id):
        return _cors(bad_request('{"error":"that model isn\'t downloaded yet"}'))
    if not _config_set_model(id):
        return _cors(bad_request('{"error":"could not update engine config"}'))
    _restart_engine()
    return _cors(ok_json('{"ok":true,"model":' + json_escape(id) + "}"))


def handle_model_download(req: Request) raises -> Response:
    """POST /api/models/download {"model": "<hf-id>"} → start a background download
    of a SUPPORTED chat model's weights via the native downloader. Rejects unknown
    ids, a second concurrent download, and the public demo (no downloads there).
    Returns {"ok":true,"model"}; the client polls /api/models/download/status.
    """
    if _is_demo():
        return _cors(
            unauthorized('{"error":"downloads are disabled in the demo"}')
        )
    var id: String
    try:
        id = String(loads(req.text())["model"].string_value())
    except:
        return _cors(bad_request('{"error":"expected {model}"}'))
    if id == "":
        return _cors(bad_request('{"error":"empty model"}'))
    if not _is_supported(id):
        return _cors(bad_request('{"error":"unknown or unsupported model"}'))
    if _model_downloaded(id):
        return _cors(
            ok_json(
                '{"ok":true,"downloaded":true,"model":' + json_escape(id) + "}"
            )
        )
    if _download_running():
        return _cors(
            bad_request('{"error":"a download is already in progress"}')
        )
    if not _start_download_detached(id):
        return _cors(
            bad_request(
                '{"error":"downloads unavailable (downloader not'
                ' configured)"}'
            )
        )
    return _cors(ok_json('{"ok":true,"model":' + json_escape(id) + "}"))


# ── model catalog / HF cache ─────────────────────────────────────────────────
# The engine serves ONE model per process (chosen at launch); the selector below
# switches it by rewriting the engine config's `model` and restarting the engine
# LaunchAgent. The config is the single source of truth (the launch agent no longer
# hard-codes the model arg — see cli/Bootstrapper writeLaunchAgent).


def _hf_hub_dir() -> String:
    """The HuggingFace cache `hub/` dir (holds `models--<slug>` snapshots)."""
    var h = String(getenv("HF_HOME", "").strip())
    if h == "":
        h = getenv("HOME", ".") + "/Library/Application Support/Millfolio/hf"
    return h + "/hub"


def _engine_config_path() -> String:
    """The engine's config.json — the single source of truth for the served model.
    """
    var o = String(getenv("MILLFOLIO_CONFIG", "").strip())
    if o != "":
        return o^
    return getenv("HOME", ".") + "/.config/millfolio/config.json"


def _slug_to_id(slug: String) -> String:
    """`models--Qwen--Qwen2.5-3B-Instruct` -> `Qwen/Qwen2.5-3B-Instruct`
    (HF uses `--` between org and name; the name itself has no `--`)."""
    var s = slug
    if s.startswith("models--"):
        s = String(s[byte=8:])
    var i = s.find("--")
    if i == -1:
        return s^
    return String(s[byte=:i]) + "/" + String(s[byte = i + 2 :])


def _model_short(id: String) -> String:
    """The label after the last `/` (`Qwen/Qwen2.5-3B-Instruct` -> `Qwen2.5-3B-Instruct`).
    """
    var sl = id.find("/")
    if sl == -1:
        return id
    return String(id[byte = sl + 1 :])


def _id_to_slug(id: String) -> String:
    """`Qwen/Qwen2.5-3B-Instruct` -> `Qwen--Qwen2.5-3B-Instruct` (the HF cache dir
    name; inverse of `_slug_to_id`). Mirrors engine/src/download.mojo `slug()`.
    """
    var out = String("")
    var b = id.as_bytes()
    for i in range(len(b)):
        if b[i] == 47:  # '/'
            out += "--"
        else:
            out += chr(Int(b[i]))
    return out^


def _model_downloaded(id: String) -> Bool:
    """A checkpoint is fully materialized when its `refs/main` ref (the downloader's
    last write) is present under the HF hub cache."""
    return exists(_hf_hub_dir() + "/models--" + _id_to_slug(id) + "/refs/main")


def _catalog() -> List[List[String]]:
    """The supported chat models offered in the UI catalog: each `[id, label, GB]`.
    The FIRST entry is the default. Ids are PUBLIC HF repos the native downloader can
    fetch with no auth token (the gated google/* repos would 401); the engine loads
    every one (Qwen2.5 / Qwen3 / gemma-4 families). The demo is filtered to Qwen.
    """
    var out = List[List[String]]()
    out.append(
        [String("Qwen/Qwen2.5-3B-Instruct"), String("Qwen2.5-3B"), String("6")]
    )
    out.append(
        [
            String("mlx-community/gemma-4-e2b-it-bf16"),
            String("Gemma-4 E2B"),
            String("5"),
        ]
    )
    out.append(
        [
            String("mlx-community/gemma-4-e4b-it-bf16"),
            String("Gemma-4 E4B"),
            String("10"),
        ]
    )
    out.append(
        [
            String("mlx-community/gemma-4-12b-it-bf16"),
            String("Gemma-4 12B"),
            String("24"),
        ]
    )
    return out^


def _is_supported(id: String) -> Bool:
    """Is `id` one of the catalog's downloadable chat models?"""
    var cat = _catalog()
    for i in range(len(cat)):
        if cat[i][0] == id:
            return True
    return False


def _available_models_json() raises -> String:
    """JSON array [{"id","label","gb","downloaded"}] — the CATALOG of supported chat
    models each flagged downloaded/not (a `refs/main` ref present), PLUS any other
    fully-cached chat checkpoint the user fetched manually (offered as Use). The
    embedding model is excluded (it's a required dependency, not a chat choice). The
    public demo is Qwen-only."""
    var demo = _is_demo()
    var out = String("[")
    var n = 0
    var emitted = List[String]()
    var cat = _catalog()
    for i in range(len(cat)):
        var id = cat[i][0].copy()
        if demo and id.find("Qwen") == -1:
            continue
        var dl = _model_downloaded(id)
        if n > 0:
            out += ","
        out += (
            '{"id":'
            + json_escape(id)
            + ',"label":'
            + json_escape(cat[i][1])
            + ',"gb":'
            + cat[i][2]
            + ',"downloaded":'
            + ("true" if dl else "false")
            + "}"
        )
        emitted.append(id^)
        n += 1
    # Any OTHER fully-cached chat model not in the catalog → offer it as Use.
    var hub = _hf_hub_dir()
    if exists(hub):
        var entries = listdir(hub)
        for i in range(len(entries)):
            var name = String(entries[i])
            if not name.startswith("models--"):
                continue
            if not exists(hub + "/" + name + "/refs/main"):
                continue
            var id = _slug_to_id(name)
            if id.find("Embedding") != -1 or id.find("embedding") != -1:
                continue
            if not (
                id.find("Qwen2.5") != -1
                or id.find("Qwen3") != -1
                or id.find("gemma-4") != -1
                or id.find("Gemma-4") != -1
            ):
                continue
            if demo and id.find("Qwen") == -1:
                continue
            var seen = False
            for j in range(len(emitted)):
                if emitted[j] == id:
                    seen = True
                    break
            if seen:
                continue
            if n > 0:
                out += ","
            out += (
                '{"id":'
                + json_escape(id)
                + ',"label":'
                + json_escape(_model_short(id))
                + ',"gb":0,"downloaded":true}'
            )
            emitted.append(id^)
            n += 1
    out += "]"
    return out^


# ── weight downloads (native-Mojo downloader, run as a detached subprocess) ────
# Downloads moved out of the `mill` installer into this server: it runs the built
# `build/download` binary (MILLFOLIO_DOWNLOAD_BIN) — the SAME native-Mojo HF fetcher
# the CLI used to run — as a DETACHED process, tracking one download at a time via
# small state files in the config dir so a status endpoint can report progress.


def _download_bin() -> String:
    """Absolute path to the native-Mojo weights downloader (`build/download`), set by
    the CLI in the app-server LaunchAgent. Empty in dev / unmanaged runs → downloads
    are unavailable (the endpoints say so; the provisioner no-ops)."""
    return String(getenv("MILLFOLIO_DOWNLOAD_BIN", "").strip())


def _dl_state_path() -> String:
    # one word: running|done|error. KV marker (`_kv_set(KV_DL_STATE, …)`); the full
    # path is still needed for the detached-download shell redirect + provision reads.
    return _config_dir() + "/" + KV_DL_STATE


def _dl_model_path() -> String:
    return _config_dir() + "/" + KV_DL_MODEL  # the in-flight model id (KV marker)


def _dl_log_path() -> String:
    return _config_dir() + "/.model_download.log"  # captured stdout+stderr


def _dl_progress() -> String:
    """The last non-empty line of the downloader's captured output — a human-readable
    progress detail (e.g. `wrote model-00001-of-00002.safetensors ( … bytes )`).
    """
    try:
        var s: String
        with open(_dl_log_path(), "r") as f:
            s = f.read()
        var lines = s.split("\n")
        var last = String("")
        for i in range(len(lines)):
            var ln = String(lines[i].strip())
            if ln != "":
                last = ln^
        return last^
    except:
        return String("")


def _dl_read_model() -> String:
    try:
        return String(default_kv_store().get(KV_DL_MODEL).strip())
    except:
        return String("")


def _catalog_gb(id: String) -> Int:
    """The catalog's approximate download size (whole GB) for `id`, or 0 if unknown
    (a manually-cached model not in the catalog). Used as the progress denominator."""
    var cat = _catalog()
    for i in range(len(cat)):
        if cat[i][0] == id:
            var out = 0
            var b = cat[i][2].as_bytes()
            for j in range(len(b)):
                var c = Int(b[j])
                if c >= 48 and c <= 57:
                    out = out * 10 + (c - 48)
            return out
    return 0


def _du_bytes(path: String) -> Int:
    """On-disk size of `path` in bytes via `du -sk` (KiB blocks → bytes) — the
    subprocess-to-temp-file pattern of `_gpu_util_pct`. Robust to the downloader's
    verbosity: we measure what has actually landed on disk. Returns -1 on miss."""
    if not exists(path):
        return 0
    var out_path = _config_dir() + "/.dl_du"
    var cmd = (
        String("cd / 2>/dev/null; du -sk '") + path + "' > '" + out_path + "'"
        " 2>/dev/null"
    )
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()
    try:
        var s: String
        with open(out_path, "r") as f:
            s = f.read()
        var kb = 0
        var indig = False
        var b = s.as_bytes()
        for i in range(len(b)):
            var c = Int(b[i])
            if c >= 48 and c <= 57:
                kb = kb * 10 + (c - 48)
                indig = True
            elif indig:
                break  # stop at the first non-digit (the tab before the path)
        return (kb * 1024) if indig else -1
    except:
        return -1


def _dl_progress_pct(id: String, done: Bool) raises -> Int:
    """Download progress 0–100 for `id`. `done` (refs/main present) short-circuits to
    100. Otherwise it's the on-disk size of the model's cache dir over the catalog's
    expected total. The catalog GB is the bf16 download size — a slight over-estimate
    of the final on-disk bytes — so the ratio can approach but should be clamped to
    <100 until genuinely done, avoiding a premature 100%. Returns -1 when unknown (no
    catalog size, or du failed) so the client falls back to the indeterminate spinner.
    """
    if done:
        return 100
    var gb = _catalog_gb(id)
    if gb <= 0:
        return -1
    var repo = _hf_hub_dir() + "/models--" + _id_to_slug(id)
    var on_disk = _du_bytes(repo)
    if on_disk < 0:
        return -1
    var total = gb * (1 << 30)  # GiB → bytes
    var pct = (on_disk * 100) // total
    if pct < 0:
        pct = 0
    if pct > 99:
        pct = 99  # never report 100 until refs/main lands (see docstring)
    return pct


def _download_status_json() raises -> String:
    """{"model","state","detail","progress","bytesDone","bytesTotal"} for the in-flight
    (or last) download. `state` is idle|running|done|error; `detail` is the latest
    downloader progress line. `progress` is 0–100 (integer; -1 when unknown → the
    client shows an indeterminate spinner). Self-heals to `done`/100 when `refs/main`
    appears (the fetch's final write)."""
    var model = _dl_read_model()
    var state = String("idle")
    var progress = -1
    var bytes_done = -1
    var bytes_total = -1
    if model != "":
        try:
            state = String(default_kv_store().get(KV_DL_STATE).strip())
        except:
            state = String("running")
        var done = _model_downloaded(model)
        if done:
            state = String("done")
        # Only surface a live percentage while the fetch is active (or done).
        if state == "running" or state == "done":
            progress = _dl_progress_pct(model, done)
            var gb = _catalog_gb(model)
            if gb > 0:
                bytes_total = gb * (1 << 30)
                bytes_done = bytes_total if done else _du_bytes(
                    _hf_hub_dir() + "/models--" + _id_to_slug(model)
                )
    return (
        '{"model":'
        + json_escape(model)
        + ',"state":'
        + json_escape(state)
        + ',"detail":'
        + json_escape(_dl_progress())
        + ',"progress":'
        + String(progress)
        + ',"bytesDone":'
        + String(bytes_done)
        + ',"bytesTotal":'
        + String(bytes_total)
        + "}"
    )


def _download_running() raises -> Bool:
    """True iff a download is genuinely in flight (state==running AND not yet on
    disk) — the guard against starting a second concurrent download."""
    var model = _dl_read_model()
    if model == "" or _model_downloaded(model):
        return False
    try:
        return String(default_kv_store().get(KV_DL_STATE).strip()) == "running"
    except:
        return False


def _dl_core_cmd(id: String) -> String:
    """The shell command that runs the downloader for `id`, appending output to the
    capture log. Runs from the runner dir (two levels up from build/download) with
    CONDA_PREFIX/MODULAR_HOME cleared — matching the CLI's runtimeEnv so flare loads
    its own libflare_tls.so next to the binary, not from the toolchain prefix. HF_HOME
    + SSL_CERT_FILE are inherited from this server's environment."""
    var bin = _download_bin()
    return (
        "d=\"$(dirname '"
        + bin
        + '\')/.."; cd "$d" && env -u CONDA_PREFIX -u MODULAR_HOME \''
        + bin
        + "' '"
        + id
        + "' >> '"
        + _dl_log_path()
        + "' 2>&1"
    )


def _begin_download_state(id: String):
    """Mark `id` as the in-flight download (running) and truncate the capture log.
    """
    _kv_set(KV_DL_MODEL, id)
    _kv_set(KV_DL_STATE, "running")
    _write_small(_dl_log_path(), "")  # capture log (not a KV marker) — truncate


def _start_download_detached(id: String) -> Bool:
    """Start a DETACHED download of `id` (returns immediately). Wraps the core command
    so the shell flips the state file to done/error on completion; backgrounded +
    </dev/null so it outlives the request and never becomes our zombie. False when the
    downloader isn't configured."""
    if _download_bin() == "":
        return False
    _begin_download_state(id)
    var state = _dl_state_path()
    var cmd = (
        "( "
        + _dl_core_cmd(id)
        + " && printf done > '"
        + state
        + "' || printf error > '"
        + state
        + "' ) </dev/null &"
    )
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()
    return True


def _provision_fetch(id: String) -> Bool:
    """BLOCKING fetch of `id` to completion (called on the provisioner thread, so it
    doesn't block the reactor). No-op True when already present; False when the
    downloader isn't available. Updates the SAME state files as the endpoint, so the
    catalog reflects provisioning progress + the concurrency guard holds."""
    if _model_downloaded(id):
        return True
    if _download_bin() == "":
        return False
    _begin_download_state(id)
    var cc = _cstr(_dl_core_cmd(id))
    _ = external_call["system", Int32](cc)  # waits (no trailing &)
    cc.free()
    var ok = _model_downloaded(id)  # refs/main appears only on full success
    _kv_set(KV_DL_STATE, "done" if ok else "error")
    return ok


# ── model selection + startup provisioning ───────────────────────────────────


def _autofetch_default() -> Bool:
    """Whether to auto-fetch the DEFAULT chat model on startup. On by default; set
    MILLFOLIO_AUTOFETCH_DEFAULT_MODEL=0 to "start empty" and let the user pick from
    the catalog. (The embedding model is always fetched — it's a hard dependency.)
    """
    return (
        String(getenv("MILLFOLIO_AUTOFETCH_DEFAULT_MODEL", "1").strip()) != "0"
    )


def _provision_worker(arg: _OpaquePtr) -> _OpaquePtr:
    """Detached startup thread: ensure the REQUIRED embedding model is present (the
    engine 503s /v1/embeddings without it → indexing + search break), then — unless
    disabled — a DEFAULT chat model so the app works out of the box after a weights-
    free install. Both are no-ops when already cached. Once a servable model is on
    disk but the engine isn't serving (it exited earlier when weights were missing),
    kickstart it. This routine is non-raising by signature (every helper it calls is),
    so a pthread start routine can never raise out of it."""
    if _download_bin() == "":
        return arg  # no downloader configured → nothing to provision
    # 1. Embedding model — a hard dependency, always fetched (not in the catalog).
    _ = _provision_fetch(String(EMBED_MODEL))
    # 2. Default chat model — toggleable (start-empty deploys flip it off).
    if _autofetch_default() and not _model_downloaded(String(DEFAULT_CHAT_MODEL)):
        _ = _provision_fetch(String(DEFAULT_CHAT_MODEL))
    # 3. Make the engine serve a downloaded model. If its configured model isn't on
    #    disk but the default now is, repoint config at the default; then, if a
    #    servable model is present but the engine isn't serving, kickstart it.
    var want = _current_model_id()
    if not _model_downloaded(want) and _model_downloaded(
        String(DEFAULT_CHAT_MODEL)
    ):
        _ = _config_set_model(String(DEFAULT_CHAT_MODEL))
        want = String(DEFAULT_CHAT_MODEL)
    if _model_downloaded(want) and _engine_loaded_model() == "":
        _restart_engine()
    return arg


def _current_model_id() -> String:
    """The engine's selected model id, read from its config.json (falls back to the
    label env / the Qwen default)."""
    try:
        var text: String
        with open(_engine_config_path(), "r") as f:
            text = f.read()
        var m = String(loads(text)["model"].string_value())
        if m != "":
            return m^
    except:
        pass
    return String(getenv("MILLFOLIO_MODEL_LABEL", "Qwen/Qwen2.5-3B-Instruct"))


def _config_set_model(id: String) -> Bool:
    """Rewrite the engine config's `model` field to `id`, preserving port/q4/
    kv_budget_mb. Returns True on success."""
    var path = _engine_config_path()
    var port = Int64(8000)
    var q4 = False
    var kv = Int64(8192)
    try:
        var text: String
        with open(path, "r") as f:
            text = f.read()
        var j = loads(text)
        try:
            port = j["port"].int_value()
        except:
            pass
        try:
            q4 = j["q4"].bool_value()
        except:
            pass
        try:
            kv = j["kv_budget_mb"].int_value()
        except:
            pass
    except:
        pass
    if String(getenv("MILLFOLIO_CONFIG", "").strip()) == "":
        try:
            makedirs(getenv("HOME", ".") + "/.config/millfolio", exist_ok=True)
        except:
            pass
    var body = (
        '{\n  "port": '
        + String(port)
        + ',\n  "model": '
        + json_escape(id)
        + ',\n  "q4": '
        + ("true" if q4 else "false")
        + ',\n  "kv_budget_mb": '
        + String(kv)
        + "\n}\n"
    )
    try:
        with open(path, "w") as f:
            f.write(body)
        return True
    except:
        return False


def _restart_engine():
    """Kick the engine LaunchAgent (me.millfolio.server) so it reloads with the
    newly-selected model. `-k` stops the running instance first."""
    var uid = Int(external_call["getuid", UInt32]())
    var cmd = (
        "launchctl kickstart -k gui/"
        + String(uid)
        + "/me.millfolio.server >/dev/null 2>&1"
    )
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()


def _engine_loaded_model() -> String:
    """The chat model the engine is ACTUALLY serving right now, from its
    /v1/models — the readiness signal the UI polls during a switch. Empty when the
    engine is down (e.g. mid-restart) or unreachable; best-effort, fails fast.
    """
    try:
        var req = Request(method="GET", url=_engine_url() + "/models")
        var client = HttpClient()
        var v = client.send(req).json()
        var arr = v["data"]
        for i in range(arr.array_count()):
            var mid = String(arr[i]["id"].string_value())
            if mid.find("Embedding") == -1 and mid.find("embedding") == -1:
                return mid^  # the chat model (skip the embeddings model)
    except:
        pass
    return String("")

"""Server — the millfolio app backend over HTTP (flare).

Migrated from headgate/src/server.mojo. The vault brains stay in headgate; this
server imports them as a library via `-I ../../headgate/src` (build wired in
pixi.toml + ../../.github/workflows/server.yml). Runs the SAME vault orchestrator
the CLI does, on localhost:10000, behind:

    POST /chat        { "message": <question> }  ->  { "reply": <answer> }
    POST /api/search  { "query": ..., "k": N }   ->  { "hits": [...] }
    GET  /api/vault   ->  { vaultDir, indexed, stats, files[] }  (the vault view)
    GET  /health
    WS   (Upgrade)    ->  streaming chat (status/approval/debug/message events)
    OPTIONS *         (CORS preflight, so a web app on another port can call us)

Single-threaded reactor — one task in flight at a time. The orchestrator lives
in a heap `MillfolioState` reached through a pointer so the borrowed-self handler
can still run `mut` codegen.

VAULT-ONLY: `/chat` always runs the private-vault codegen loop (`run_vault_task`)
over the resolved vault dir.

ONE PORT: the unary HTTP `Api` handler AND the streaming WebSocket chat
(`handlers_chat.on_connect`) share a single :10000 listener — flare's
`HttpServer.serve(handler, ws_handler)` upgrades requests carrying the WebSocket
headers and routes everything else to the HTTP handler. (Previously the WS stream
needed a second port; flare couldn't multiplex them.)

After the Phase-1 handler carve-up this file is ONLY the composition root: the
anti-rebinding `serve()` gate + the `_route` dispatcher over the per-domain
`handlers_*` modules, and `main()` (boot, state, worker threads, listener). All
handler bodies — including the chat surface (POST /chat + the WS ask loop) —
live in their `handlers_*` module.

    pixi run build   # -> build/millfolio-server, listens on 127.0.0.1:10000
"""

from std.memory import alloc, UnsafePointer
from std.os import getenv, makedirs


from flare.prelude import *
from flare.http import Handler
from flare.runtime._thread import ThreadHandle, _null_ptr

from std.sys import argv

from settings import load_config
from wiring import build_vault_orchestrator
from runqueue import runq_reset

# The work orchestrator's runtime (Phase 3 slice): the scheduler loop + its job
# runners live in their own module. server.mojo keeps the composition root and imports
# the spawn entry point (`_orchestrator_worker`) and the boot reconcile
# (`_reconcile_stale`). The per-domain handler modules import the rest of the
# orchestrator's state/op readers. work_orchestrator never imports server.mojo (acyclic).
from work_orchestrator import _orchestrator_worker, _reconcile_stale

from vaultcfg import vault_dir as resolve_vault_dir
from state import MillfolioState
import handlers_vault
import handlers_chat
import handlers_apikey
import handlers_system
import handlers_amounts
import handlers_tags
import handlers_models
import handlers_demo
import handlers_operations
import handlers_millwright

# The extracted free-helper modules (Phase-1 slice A). `osutil` is the BASE
# (stdlib-only) layer the others build on — no import cycle. See each module's
# docstring for what lives where.
from osutil import (
    _port,
    _workers,
    _web_root,
    _config_dir,
    _chmod,
    _is_demo,
)
from auth import _ensure_reveal_secret, _apply_persisted_apikey
from httputil import (
    _content_type,
    _serve_file,
    _cors,
    _forbidden,
    _extract_host,
    _host_allowed,
)


@fieldwise_init
struct Api(Copyable, Handler, Movable):
    var st: UnsafePointer[MillfolioState, MutUntrackedOrigin]

    def serve(self, req: Request) raises -> Response:
        """Anti-CSRF / anti-DNS-rebinding gate in front of `_route`.

        This server holds personal financial data on a loopback port that ANY
        browser tab or local process on the machine can reach. Two checks close
        that off before any handler runs:
          • `Host` must be a loopback name — defeats DNS rebinding (attacker.com
            rebound to 127.0.0.1 arrives with `Host: attacker.com`).
          • `Origin`, when present, must be loopback — defeats a malicious site
            issuing cross-origin `fetch`/WebSocket reads or CSRF POSTs.
        A rejected request gets a 403 with no CORS headers, so its body is
        unreadable cross-origin either way. Allowed origins are echoed back
        (not `*`) so the browser only shares responses with local callers.

        SKIPPED in demo mode: the public demo (port 10010, behind a Cloudflare
        Tunnel) is served under a real hostname, not loopback, and holds only
        SYNTHETIC data behind a Turnstile bot gate — the personal-vault threat
        this guard defends against doesn't exist there."""
        var origin_raw = String(req.headers.get("origin"))
        if not _is_demo():
            var host = _extract_host(String(req.headers.get("host")))
            if not _host_allowed(host):
                return _forbidden("host not allowed")
            if origin_raw != "" and not _host_allowed(
                _extract_host(origin_raw)
            ):
                return _forbidden("origin not allowed")
        var resp = self._route(req)
        if origin_raw != "":
            try:
                resp.headers.set("Access-Control-Allow-Origin", origin_raw)
                resp.headers.set("Vary", "Origin")
            except:
                pass
        return resp^

    def _route(self, req: Request) raises -> Response:
        var path = req.url
        # CORS preflight (compare the raw method string — no Method.OPTIONS dep).
        if req.method == "OPTIONS":
            return _cors(Response(status=204, reason="No Content"))
        if req.method == Method.POST and path == "/chat":
            return handlers_chat.handle_chat(self.st, req)
        if path == "/api/vault":
            return handlers_vault.handle_vault(self.st)
        # Document viewer: /api/doc?alias=file_N streams the raw indexed file
        # (alias-gated via the manifest — no caller-supplied path, so no traversal).
        if path == "/api/doc" or (path.find("/api/doc?") == 0):
            return handlers_vault.handle_doc(req)
        if req.method == Method.POST and path == "/api/search":
            return handlers_vault.handle_search(req)
        if path == "/health":
            return handlers_system.handle_health()
        # The on-device model name — the UI shows it in the bottom bar.
        if path == "/api/model":
            return handlers_models.handle_model_info()
        # On-device model selector: the list of switchable (cached) models + the
        # current selection; POST /api/models/select switches it (restarts engine).
        if path == "/api/models":
            return handlers_models.handle_models_list()
        if req.method == Method.POST and path == "/api/models/select":
            return handlers_models.handle_model_select(req)
        # Model catalog downloads: start a background fetch of a supported model's
        # weights, and poll its progress.
        if req.method == Method.POST and path == "/api/models/download":
            return handlers_models.handle_model_download(req)
        if path == "/api/models/download/status":
            return handlers_models.handle_models_download_status()
        # First-run onboarding: fetch + index the hosted sample vault so a new user
        # can try millfolio without pointing it at their own folder. Poll its progress.
        if req.method == Method.POST and path == "/api/demo/download":
            return handlers_demo.handle_demo_download()
        if path == "/api/demo/status":
            return handlers_demo.handle_demo_status()
        # Vault/Files: index an arbitrary local folder/file, track it, and re-index
        # tracked folders to pick up new files. One job at a time (shared with the
        # sample-vault import path). See handle_index for the append-not-clobber note.
        if req.method == Method.POST and path == "/api/index":
            return handlers_operations.handle_index(req)
        if path == "/api/index/status":
            return handlers_operations.handle_index_status()
        if path == "/api/operations":
            return handlers_operations.handle_operations()
        # The work-queue contents (running + pending) so Operations can show what's
        # queued behind the running job. Read-only; empty in the demo.
        if path == "/api/orchestrator/queue":
            return handlers_operations.handle_orchestrator_queue()
        if path == "/api/index/folders":
            return handlers_operations.handle_index_folders()
        if req.method == Method.POST and path == "/api/index/reindex":
            return handlers_operations.handle_index_reindex(req)
        if req.method == Method.POST and path == "/api/index/folders/remove":
            return handlers_operations.handle_index_folder_remove(req)
        # Demo bot gate: validate a Turnstile token → mint a demo-access token the
        # client echoes on WS chat frames. No-op (empty token) when Turnstile is off.
        if req.method == Method.POST and path == "/api/demo/verify":
            return handlers_demo.handle_demo_verify(req)
        # Instantaneous GPU utilization (%); the bottom bar keeps a 30s average.
        if path == "/api/gpu":
            return handlers_system.handle_gpu()
        # Accumulated per-question usage (JSONL file, returned verbatim) — the Stats page.
        if path == "/api/stats":
            return handlers_system.handle_stats()
        if path == "/api/history/delete":
            return handlers_system.handle_history_delete(req)
        if path == "/api/history":
            return handlers_system.handle_history()
        if path == "/api/system":
            return handlers_system.handle_system()
        # Millwright — the versioned, user-owned dashboard (spec + version chain
        # + widget snapshots). See handlers_millwright / designs/MILLWRIGHT.md.
        if path == "/api/millwright":
            return handlers_millwright.handle_millwright()
        if path == "/api/millwright/versions":
            return handlers_millwright.handle_millwright_versions()
        if req.method == Method.POST and path == "/api/millwright/program":
            return handlers_millwright.handle_millwright_program_save(req)
        if path.find("/api/millwright/program") == 0:
            return handlers_millwright.handle_millwright_program(req)
        if req.method == Method.POST and path == "/api/millwright/spec":
            return handlers_millwright.handle_millwright_spec(req)
        if req.method == Method.POST and path == "/api/millwright/revert":
            return handlers_millwright.handle_millwright_revert(req)
        if req.method == Method.POST and path == "/api/millwright/pin":
            return handlers_millwright.handle_millwright_pin(req)
        if req.method == Method.POST and path == "/api/millwright/result":
            return handlers_millwright.handle_millwright_result(req)
        if req.method == Method.POST and path == "/api/millwright/assist":
            return handlers_millwright.handle_millwright_assist(req)
        # Category tags: the panel's list (names + keywords + per-tag counts) and
        # the editable registry file. All in-process via vault.derive.store.
        if path == "/api/tags":
            return handlers_tags.handle_tags()
        if path == "/api/transactions" or path.find("/api/transactions?") == 0:
            return handlers_amounts.handle_transactions(req)
        # WebAuthn (Touch-ID) gate for revealing transaction amounts.
        if req.method == Method.POST and path == "/api/auth/unlock":
            return handlers_amounts.handle_auth_unlock(req)
        if req.method == Method.POST and path == "/api/amounts/unlock-local":
            return handlers_amounts.handle_amounts_unlock_local(req)
        if path == "/api/categories/preview":
            return handlers_tags.handle_categories_preview(req)
        if path == "/api/categories":
            if req.method == Method.POST:
                return handlers_tags.handle_categories_save(req)
            return handlers_tags.handle_categories_get()
        if path == "/api/backfill/status":
            return handlers_tags.handle_backfill_status()
        if path == "/api/backfill/run":
            return handlers_tags.handle_backfill_run()
        # Pause + priority are now ORCHESTRATOR-GLOBAL (govern index AND backfill).
        # `/api/orchestrator/*` are the canonical routes; the `/api/backfill/*` ones
        # remain as thin aliases (both hit the same global controller) for one release.
        if path == "/api/orchestrator/pause" or path == "/api/backfill/pause":
            return handlers_tags.handle_backfill_pause(req)
        if path == "/api/orchestrator/resume" or path == "/api/backfill/resume":
            return handlers_tags.handle_backfill_resume()
        if (
            path == "/api/orchestrator/priority"
            or path == "/api/backfill/priority"
        ):
            return handlers_tags.handle_backfill_priority(req)
        if path == "/api/tags/preview-ai":
            return handlers_tags.handle_tags_preview_ai(req)
        if path == "/api/tags/add":
            return handlers_tags.handle_tags_add(req)
        if path == "/api/tags/missing-defaults":
            return handlers_tags.handle_tags_missing_defaults()
        if path == "/api/tags/add-defaults":
            return handlers_tags.handle_tags_add_defaults(req)
        # In-app Anthropic API key (for native users who never set the env var):
        # GET → {set, hint}; POST {key} → store 0600 (empty key clears); DELETE → clear.
        if path == "/api/settings/apikey":
            if req.method == Method.POST:
                return handlers_apikey.handle_apikey_post(req)
            if req.method == Method.DELETE:
                return handlers_apikey.handle_apikey_delete()
            return handlers_apikey.handle_apikey_get()
        # Static web UI — same-origin in production (Vite serves it in dev).
        # Reject path traversal before mapping under web/dist.
        if path.find("..") == -1:
            var root = _web_root()
            if path == "/" or path == "/index.html":
                return _serve_file(
                    root + "/index.html", "text/html; charset=utf-8"
                )
            # A client-side route (no file extension, e.g. /stats) → serve the SPA
            # entry so SvelteKit's router can render it (adapter-static fallback).
            if path.find(".") == -1:
                return _serve_file(
                    root + "/index.html", "text/html; charset=utf-8"
                )
            # Any other path is a built asset — SvelteKit emits /_app/immutable/…
            # (JS/CSS), /_app/version.json, /favicon.svg, etc. Serve it from the web
            # root (404 only if it genuinely isn't there).
            return _serve_file(root + path, _content_type(path))
        return _cors(not_found(path))


def main() raises:
    # `--fetch-demo <url> <dest>`: NOT the server — a one-shot download helper we re-exec
    # as a SEPARATE PROCESS from the orchestrator loop (see `_demo_fetch_and_unpack`), so
    # the sample-vault zip's flare GET runs off the serving reactor. Do the fetch + exit
    # before any server/orchestrator setup (never binds the port). The parent reads
    # success from the written file, so the return value is advisory only.
    var cli = argv()
    if len(cli) >= 2 and String(cli[1]) == "--fetch-demo":
        var url = String(cli[2]) if len(cli) >= 3 else String("")
        var dest = String(cli[3]) if len(cli) >= 4 else String("")
        _ = handlers_demo._fetch_demo_run(url, dest)
        return

    var cfg = load_config()
    # The `/chat` orchestrator is built once here from this cfg, so seed it from
    # the in-app key store too (the WS ask path re-loads per connection). A key
    # pasted later still lands via the per-connection reload on the WS path.
    _apply_persisted_apikey(cfg)

    # Ensure the data dir exists (new macOS-native location; no migration) so the
    # first stats/asks/controller write doesn't race a missing directory.
    try:
        makedirs(_config_dir(), exist_ok=True)
        _chmod(
            _config_dir(), 0o700
        )  # owner-only: holds stats/asks/history + demo tokens
    except:
        pass

    # Crash recovery: reconcile any work items a prior (now-dead) process left marked
    # running — an orphaned index run settles to `error` and clears; the work queue
    # itself survives the restart and RESUMES its pending items (see the loop below).
    _reconcile_stale()

    # First run: materialize the curated starter board NOW (not on the first
    # Board visit) so a fresh install opens with a populated dashboard. No-op
    # whenever any version chain exists; failures are swallowed inside.
    handlers_millwright._seed_if_empty()

    # Ensure the local-capability secret exists (0600) so the native menu-bar app's
    # Touch-ID unlock can bridge to a reveal token. Skipped in the demo (no gate).
    try:
        if not _is_demo():
            _ = _ensure_reveal_secret()
    except:
        pass

    # VAULT-ONLY: build the vault orchestrator over the resolved vault dir
    # (HEADGATE_VAULT_DIR / $MILLFOLIO_VAULT / $HEADGATE_DATA / ~/millfolio) and route
    # /chat to run_vault_task.
    var vault_dir = resolve_vault_dir()
    print("millfolio server — VAULT mode — vault dir: " + vault_dir)
    var orch = build_vault_orchestrator(cfg, vault_dir)

    var st = MillfolioState(orch^, vault_dir^)
    var sp = alloc[MillfolioState](1)
    sp.init_pointee_move(st^)
    var api = Api(sp)

    var port = _port()
    print("millfolio server on http://127.0.0.1:", port, "  (flare)", sep="")
    print('  POST /chat   { "message": ... } -> { "reply": ... }')
    print("  GET  /api/vault  -> vault files + index stats")
    print("  POST /api/search { query, k } -> ranked hits")
    print(
        "  WS   (Upgrade)   -> streaming chat (status/approval/message events)"
    )
    # One listener serves both: the unary HTTP `Api` handler AND, for requests with
    # the WebSocket Upgrade headers, the streaming `on_connect` chat — no second port.
    # (The 2-arg serve overload is plain-function-only; we use a stateful Handler
    # struct, so set the WS handler on the config and use the Handler-typed serve.)
    runq_reset()  # clear any stale run-queue state from a prior process
    var srv = HttpServer.bind(SocketAddr.localhost(UInt16(port)))
    srv.config.ws_handler = handlers_chat.on_connect
    # Run each chat WebSocket on its OWN detached thread (off the reactor).
    # A chat query blocks for ~30s–2min inside `on_connect` (codegen's Anthropic
    # call, then compile + the run-poll loop). Inline, that parks the whole reactor
    # worker, so the read-only API GETs (/api/system, /api/vault, …) pinned to that
    # worker stall for the entire query — the UI's System tab shows "Loading…".
    # Offloading frees the reactor to keep answering those GETs while the chat runs.
    # The sandboxed RUN stays serial regardless (the flock run-queue in on_connect);
    # only manifest+codegen now overlap across visitors — desired for the demo.
    # MILLFOLIO_WS_INLINE=1 restores the old inline (reactor-blocking) behaviour.
    if getenv("MILLFOLIO_WS_INLINE", "") == "":
        srv.config.ws_offload = True
    var workers = _workers()
    if workers > 1:
        print(
            "  workers: ",
            workers,
            (
                " (concurrent connections; the sandboxed run stays serial via"
                " the run-queue)"
            ),
            sep="",
        )
    # The work orchestrator: ONE detached scheduler loop drains the disk-backed work
    # queue — ALL background engine work (indexing + AI-tag backfill) — a single job at
    # a time, honoring the global pause + priority and yielding to interactive queries.
    # This replaces both the free-poll backfill thread and the direct index-spawn, so
    # index and backfill can never contend for the engine (see ORCHESTRATOR.md §2.3).
    try:
        var mth = ThreadHandle.spawn[_orchestrator_worker](_null_ptr())
        mth.detach()
        print(
            "  work orchestrator: on (indexing + AI-tag backfill, one at a"
            " time)"
        )
    except:
        print(
            "  work orchestrator: could not start (index-time backfill still"
            " works)"
        )
    # Background weight provisioner: ensure the required embedding model + a default
    # chat model are present (both no-ops when cached), so indexing/search + chat work
    # out of the box after a weights-free install; then kickstart the engine to serve
    # the default model. Detached — never blocks startup. Skipped in the demo (shared
    # replay engine, synthetic data). No-op when the downloader isn't configured.
    if not _is_demo():
        try:
            var pth = ThreadHandle.spawn[handlers_models._provision_worker](
                _null_ptr()
            )
            pth.detach()
            print(
                "  weight provisioner: on (embedding + default chat model,"
                " background)"
            )
        except:
            print("  weight provisioner: could not start")
    # num_workers=1 (default) → single-threaded reactor (real product). >1 → N pthread
    # workers via the multicore Handler-serve; Api is Copyable (shares the state
    # pointer) and config.ws_handler propagates to each worker.
    srv.serve(api^, num_workers=workers)

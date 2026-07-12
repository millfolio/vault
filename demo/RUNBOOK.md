# millfolio demo — runbook

End-to-end operational guide: stand up the public demo at `demo.millfolio.app` and keep
it updated. See `README.md` for *how it works* (the replay seam) and `SETUP.md` for the
bgent launchd details.

## Topology

One **Mac mini**, two accounts:

| account | runs | why |
|---|---|---|
| **main** (admin, GUI login) | the demo **inference engine** on `:8001` | Metal needs a GUI session |
| **bgent** (demo) | the **app server** `:10010` + **replay proxy** `:8788` + **cloudflared** | the public-facing demo |

They share the machine's **loopback**, so bgent's app reaches the main account's engine on
`127.0.0.1:8001`. Weights are shared read-only at `/Users/Shared/millfolio/hf`.

```
visitor ─▶ cloudflared ─▶ bgent app server :10010
                              │  codegen → replay proxy :8788  (HIT → cached program; no paid API)
                              │  approve → FIFO run-queue (position shown)
                              ▼
                          compile + run the program over the synthetic vault
                              │  ask_local()/search() → 127.0.0.1:8001  (main account's engine)
                              ▼  answer
```

### Ports

| port | what |
|---|---|
| 10000 | production app (untouched by the demo) |
| 10010 | **demo app server** |
| 8788  | **demo replay proxy** |
| 8000  | production inference engine (untouched) |
| 8001  | **demo inference engine** (shared weights) |
| 18010 / 18788 | throwaway prime/verify stack (dedicated, coexists with the above) |

## One-time setup

### 1. Shared weights (main account, once)
```bash
sudo mkdir -p /Users/Shared/millfolio
sudo mv "$HOME/Library/Application Support/Millfolio/hf" /Users/Shared/millfolio/hf
sudo chmod -R a+rX /Users/Shared/millfolio
```

### 2. Demo engine on `:8001` (main account, GUI session)
```bash
bash scripts/build-demo-engine.sh        # builds a standalone engine from the dev tree
bash scripts/setup-demo-engine.sh        # installs the :8001 LaunchAgent (prints the pmset/login note)
sleep 20 && curl -s http://127.0.0.1:8001/v1/models   # expect Qwen chat + embedding models
sudo pmset -a sleep 0 disablesleep 1     # mini must stay awake; enable auto-login for this account
```
Refresh after editing engine code: `bash scripts/build-demo-engine.sh` (rebuilds **and** restarts the agent).

### 3. Runtime on bgent (from the dev Mac)
Pushes the bundle (app server + web + Mojo toolchain) and **relocates** it to bgent's home
(app-server rpath → `@loader_path`, `modular.cfg` paths → bgent's `$HOME`):
```bash
BGENT=bgent@bgent SYNC_RUNTIME=1 bash scripts/deploy.sh
```
Prefer a Homebrew rsync (`brew install rsync`) on the dev Mac — macOS openrsync gets
SIGKILL'd on the ~670 MB transfer. (Once a release ships the new code, `mill install` on
bgent is the robust alternative to `SYNC_RUNTIME`.)

### 4. bgent services (on bgent)
```bash
sudo TARGET_USER=bgent bash ~/demo/scripts/setup-bgent.sh --daemon   # app + tunnel launchd
```

### 5. Cloudflare tunnel (on bgent, once) — see the printout at the end of `setup-bgent.sh`
`brew install cloudflared`, `cloudflared tunnel login/create millfolio-demo`,
`cloudflared tunnel route dns millfolio-demo demo.millfolio.app`, then fill
`replay/cloudflared-config.yml`.

## Prime the cache (must run on bgent, with the engine up)

The cache key is `sha256(system prompt + question + manifest)`, and the manifest comes
from bgent's **on-device index** — so the cache must be primed **on bgent**, not the dev
Mac. `prime-cache.sh` runs on dedicated ports (`18788`/`18010`), captures + replays each
curated question, and **drops** any that fall back / error / time out; survivors are
written to `replay/cache/questions.json`.
```bash
# on bgent (engine on :8001 must be answering):
cd ~/demo && DEMO_CAPTURE_KEY='sk-ant-…' bash scripts/prime-cache.sh
# back on the dev Mac — pull the primed cache into the repo and commit:
rsync -a --delete "bgent@bgent:demo/replay/cache/" ./replay/cache/
git add replay/cache && git commit -m "prime replay cache"
```
> ⚠️ The repo cache must match bgent before any `deploy.sh` (it `--delete`-syncs the cache).
> Prime on bgent → pull → commit → *then* deploy.

## Updating

| changed | do |
|---|---|
| app server / web (`app/`) | rebuild (`moon run app-web:build`, `pixi run build` in `app/server`), stage into the bundle, `SYNC_RUNTIME=1 bash scripts/deploy.sh` |
| engine (`engine/`) | on main: `bash scripts/build-demo-engine.sh` (rebuilds + restarts `:8001`) |
| codegen prompt / vault / question set | **re-prime on bgent** → pull cache → commit → deploy |
| replay cache only | `bash scripts/deploy.sh` (no `SYNC_RUNTIME`) syncs the demo dir incl. `replay/cache/` |

## Troubleshooting

| symptom | cause / fix |
|---|---|
| `rsync: invalid option -- s` or `Killed: 9` | macOS openrsync — `brew install rsync` (deploy prefers it) |
| `Library not loaded: @rpath/libKGEN…` | app-server rpath not relocated — re-run `SYNC_RUNTIME` deploy (it swaps the rpath) |
| `unable to locate module 'std'` | `modular.cfg` still has the dev home — re-run `SYNC_RUNTIME` deploy (it rewrites it) |
| curated question → "try one of the suggested questions" (fallback) | cache key mismatch — re-prime **on bgent** (index is host-specific) |
| question hangs in "Running…" | engine `:8001` down (program calls `ask_local`/`search`) — check `curl :8001/v1/models`; a run also self-kills after ~120 s |
| `1033` at `demo.millfolio.app` | `cloudflared` not connected — restart the tunnel launchd job on bgent |
| no queue position shown | you're solo (shows `Position 1 of 1`) or the new server isn't deployed yet — `SYNC_RUNTIME` deploy; to see a real queue, fire 2 requests at once |

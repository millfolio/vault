# Deploying the demo on `bgent`

The demo runs in the dedicated `bgent` macOS account on the Mac mini, behind a
Cloudflare Tunnel at `demo.millfolio.app`. You drive deploys from your **dev Mac**
over SSH — `deploy.sh` syncs everything and restarts.

## What gets copied to bgent

**The millfolio runtime** (Mojo toolchain + bundle, ~670MB) goes on bgent via
`brew install millfolio/tap/mill && mill install` — it pulls from the release CDN,
which is far more robust than rsyncing it from your dev Mac (rsyncing 670MB from a
memory-pressured Mac can get OOM-killed). This needs a release with the new code, so
**cut v0.4.26 first**.

**`deploy.sh` then syncs only the small bits** (a few MB, one SSH auth):

| from your dev Mac | to bgent | what |
|---|---|---|
| `~/dev/demo/` | `~/demo/` | the replay proxy + scripts + the primed cache |
| `~/dev/demo-vault/` | `~/demo-vault/` | the synthetic statements **+ their pre-built index** |

It then stages the pre-built index into `~/.config/millfolio` (rewriting the vault
path), and restarts. **No GPU / inference engine is needed** — the curated questions
resolve via `transactions()` / `manifest()` (which read the staged index), so nothing
hits a model at runtime, and nothing public reaches a paid API.

**Pre-release (no v0.4.26 yet):** push the local dev build instead, with
`SYNC_RUNTIME=1 bash scripts/deploy.sh` — heavy, so free RAM on the dev Mac first
(`mill stop`). And `ssh-copy-id "$BGENT"` once to stop the password prompts.

## One-time
1. On your dev Mac: prime the replay cache once (real key, over the synthetic vault)
   and commit `demo/replay/cache/` — see `scripts/prime-cache.sh`. The cache is
   keyed on the synthetic manifest, so a cache primed on dev replays on bgent.
2. First deploy (syncs everything): `BGENT=<user>@<host> bash scripts/deploy.sh`.
3. On bgent (over your SSH): install the launchd jobs (demo + tunnel), then do the
   interactive **Cloudflare** steps it prints (`cloudflared login` / `tunnel create` /
   `route dns` + fill the config). Two modes:
   - **Headless (no login) — for this Mac mini:** `sudo bash ~/demo/scripts/setup-bgent.sh --daemon`
     installs **LaunchDaemons** that start at boot with NO ONE logged into bgent. The
     demo is transactions-only (no GPU/keychain/window-server), so it runs fine headless.
     Keep the mini awake — `sudo pmset -a sleep 0 disablesleep 1` — or the tunnel drops.
   - **Logged-in account:** `bash ~/demo/scripts/setup-bgent.sh` installs LaunchAgents,
     which only run while bgent is logged into the desktop (needs Automatic Login or a
     live Screen-Sharing session).

## Every update after that
Just, from your dev Mac:
```bash
BGENT=<user>@<host>  bash scripts/deploy.sh
```
That re-syncs (incrementally), re-stages the index if the synthetic vault changed,
and `launchctl kickstart`s the demo. To change the data: edit `demo-vault`,
regenerate + re-index (see `demo-vault/README.md`), re-prime the cache for any new
questions, then `deploy.sh`.

## Runtime note (pre-release)
Until **v0.4.26** ships, the runtime is the **dev build** synced above (it has the
new transactions/`money`/layout code). Once v0.4.26 is released, you can instead
`brew install millfolio/tap/mill && mill install` on bgent and drop the bundle/mojo
sync from `deploy.sh` — the demo wraps the released product unchanged.

## Do you need to give me SSH access?
No — `deploy.sh` is yours to run from your dev Mac (you have SSH to bgent). If you
*want* me to run deploys, an SSH key for bgent would let me, but that's a deliberate
access decision — the script doesn't require it. The one-time interactive bits
(`cloudflared login`, the first `brew install`) need a human on bgent regardless.

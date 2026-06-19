# Cutover plan (increment 5)

Move the local backend from headgate's `headgate-server` to this app's
`veilens-ws`, and the UI from `headgate/web` to `app/web`. Staged so the shipping
vault path is never broken.

## 5a — app release bundle  ✅ (this step)

`app-zip.yml` builds `veilens-server` + `veilens-ws` (compile gate) and the web
UI, then `scripts/package-app.sh` packages **`veilens-app.zip`** = `src/ws_server.mojo`
(+ `server.mojo`) + `web/dist/`. Attached to a Release on tags. CI-validated.

## 5b — CLI install + launch  (next; Swift, locally verifiable)

In `veilensapp/cli` `Bootstrapper.swift`:

- `installAppServer()` — download `veilens-app.zip` from `veilensapp/app`'s
  `releases/latest`, unzip under `~/Library/Application Support/Millrace/app/`,
  and `mojo build src/ws_server.mojo` with headgate's toolchain against the
  installed headgate engine tree:
  `-I <headgate-engine>/headgate/src -I <…>/flare -I <…>/json -I <…>/jinja2.mojo/src`
  → `app/build/veilens-ws`. (Reuses `headgate-mojo`'s prefix + flare shims, so no
  new toolchain/shims.)
- launch: replace `writeVeilensWebScript` (which execs headgate's `serve-web.sh`)
  with one that `cd`s to `app/` (so `./web/dist` resolves), sets `CONDA_PREFIX=
  headgate-mojo`, `HEADGATE_VEILENS` + `VEILENS_VAULT`/loopback URLs, and execs
  `./build/veilens-ws`.
- keep the headgate-server path as a fallback until 5b is validated on a real
  machine (the WS round-trip can't be CI-tested).

## 5c — retire + release

Once 5b works end-to-end: drop `headgate/src/server.mojo`, `headgate/web/`,
`headgate`'s `build-server`/`serve-web` tasks, and the CLI's headgate-web launch.
Release cli (and tag `app` to publish `veilens-app.zip`).

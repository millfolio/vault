# server (Mojo)

The local backend the apps connect to. A thin HTTP layer that speaks the
[Veilens protocol](../protocol) and delegates the real work to the **headgate**
orchestrator (the vault codegen loop + sandbox + egress guard), imported as a
Mojo library via `-I` includes — exactly how `headgate/src/server.mojo` does it
today.

Exposed to the user's phone/laptop over **Tailscale** (`tailscale serve`); the
tailnet is the auth boundary. Binds loopback otherwise.

## Status: scaffold

`src/server.mojo` is a placeholder. The first real task is to **migrate
`headgate/src/server.mojo` here** and grow its single `POST /chat` route into the
streaming protocol (status / approval-request / debug / message events), then
point the CLI's launcher at this binary instead of `headgate-server`.

Build (once wired) will follow the established cross-repo pattern: check out
`headgate` (+ `flare`/`json`) as siblings and
`mojo build src/server.mojo -I ../../headgate/src -I ../flare -I ../json …`.

## Why Mojo

Same language and toolchain as the engine it wraps (headgate/millrace), so it
reuses the orchestrator directly with no FFI/IPC boundary.

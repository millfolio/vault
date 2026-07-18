# server (Mojo)

The local backend the apps connect to. A thin HTTP layer that delegates the real
work to the **headgate** harness (the vault codegen loop + sandbox + egress
guard), imported as a Mojo library via `-I ../../headgate/src` — the vault brains
stay in headgate; this server is the protocol surface.

Exposed to the user's phone/laptop over **Tailscale** (`tailscale serve`); the
tailnet is the auth boundary. Binds loopback otherwise.

## Status

**Phase 1 — migrated, behavior-preserving.** `src/server.mojo` is the lifted
headgate web server: `POST /chat {message} -> {reply}`, `GET /health`, CORS, and
static file serving, running the same `run_vault_task` harness. CI
(`../.github/workflows/server.yml`) compiles it against headgate + flare/json/
jinja2 checked out as siblings.

Not yet cut over: headgate still builds its own `headgate-server` and the CLI
still launches that. Cutover (point the CLI at `build/millfolio-server`, drop
headgate's copy + `web/`) follows once the streaming phase lands.

**Phase 2 — the streaming millfolio protocol (next).** Grow `/chat` into the
streaming contract in [`../protocol`](../protocol): `status` / `approval-request`
/ `debug` / `message` events. This needs two things beyond this file:

1. an **event hook** in the headgate harness so `run_vault_task` can emit
   step status + debug payloads (and *pause* at an approval gate), and
2. a **streaming/duplex transport** (SSE + a side-channel approve/reject POST, or
   WebSocket) — flare's current `Request -> Response` handler is unary.

## Build

```sh
# repos laid out as siblings: app/ headgate/ flare/ json/ jinja2.mojo/
cd server
pixi run build        # -> build/millfolio-server (127.0.0.1:10000)
```

## Why Mojo

Same language/toolchain as the engine it wraps (headgate/millfolio), so it reuses
the harness directly with no FFI/IPC boundary.

# Streaming protocol — design (phase 2)

How `/chat` grows from one-shot `{message}->{reply}` into the streaming millfolio
protocol (status / approval-request / debug / message events). Grounded in what
flare and the headgate orchestrator actually support today.

## Transport: WebSocket

flare's capabilities (verified in `millfolio/flare`):

- **WebSocket** (`flare/ws/server.mojo`) is fully implemented — RFC 6455 handshake,
  full-duplex `send`/`recv`. Production-ready. ✅
- **SSE / chunked** primitives exist (`flare/http/sse.mojo`, `streaming_response.mojo`)
  but are **NOT wired to the reactor** — there's no `serve_streaming` entry point.
  Unusable for networked streaming today. ❌
- The HTTP handler is **unary** (`serve(req) -> Response`, fully-buffered body).

So the transport is **WebSocket**. It also gives us the client→server channel the
approval gate needs, which SSE alone would not.

Framing: one JSON object per text frame.
- client → server: a `ClientMessage` (`ask` / `approve` / `reject`)
- server → client: a `ServerEvent` (`status` / `approval-request` / `debug` /
  `message` / `error`)

(See `../protocol/events.ts`.) A session is one WS connection: the client sends
`ask`, the server streams events, the client answers any `approval-request` with
`approve`/`reject` on the same socket, and the server closes after `message`.

## Why the approval *pause* is simple here

flare runs a handler synchronously to completion, and WS is full-duplex. So the
orchestrator runs **inline in the WS handler**: it `ws.send`s each event as it
goes, and at the approval gate it **blocks on `ws.recv()`** until the client
sends `approve`/`reject`. The blocking recv *is* the pause — no need to turn
`run_vault_task` into a resumable state machine.

(Reactor note: flare's default reactor is single-threaded and a handler blocks it
for the duration. That's acceptable for the local, single-user vault server — one
task in flight at a time, same as today. If we later want concurrent sessions,
flare supports multi-worker `serve`.)

## The orchestrator event hook

`run_vault_task` (headgate `src/orchestrator.mojo`) is a linear pipeline; the
emit points map 1:1 to the workflow panel:

| stage | events |
|---|---|
| `millfolio manifest` capture | `status` running→done; `debug` the aliased manifest |
| `_codegen` | `status` running→done; `debug` the generated program |
| **before the sandbox run** | `approval-request` "run the generated program?" → **wait** |
| compile + run in sandbox | `status` running→done; `debug` sandbox stdout |
| return | `message` the answer |

The hook is an **event sink** the orchestrator emits through:

```
trait EventSink:
    fn status(self, step, label, state, detail)
    fn debug(self, step, title, body, language)
    fn approval(self, step, label, payload) -> Decision   # BLOCKS until answered
    fn message(self, text)
```

- The **WS handler** provides a sink backed by the connection: `status/debug/
  message` serialize a `ServerEvent` and `ws.send` it; `approval` sends an
  `approval-request` then `ws.recv`s the client's `approve`/`reject`.
- Existing callers (the `millfolio ask` CLI, today's `/chat`) provide a **no-op
  sink** that drops events and auto-approves — so current behavior is unchanged.

**Back-compat / call sites.** The sink should be attached to the `Harness`
(e.g. set after construction, default no-op) rather than added to
`run_vault_task`'s signature, so the CLI and the current server compile
untouched. Open question to confirm against the compiler: Mojo's ergonomics for
storing a trait object as a struct field vs. making `Harness` parametric on
the sink type — settle this first when implementing, as it drives the diff shape.

## Increments

1. ✅ **(done)** Phase-1 migration: `app/server` builds the unary server.
2. **Web WS client** — `web/src/lib/wsClient.ts` implements the protocol over
   WebSocket (mock kept as the no-server fallback). *(verifiable now)*
3. **Server WS endpoint** — a WS `/chat` in `app/server` (model on
   `flare/examples/basic/ws_server.mojo`) that runs the vault task and streams a
   `status` + final `message` (no orchestrator changes yet). *(CI-validated)*
4. **Harness event sink** — add the `EventSink` hook + the no-op default;
   wire the WS handler's sink so mid-run `status`/`debug`/`approval` flow.
5. **Cutover** — point the CLI at `millfolio-server`, retire headgate's server/web.

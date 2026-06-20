# millfolio protocol

The contract between the clients (web/iOS/android) and the `server/`. This is the
**source of truth**: the server implements its server half, the clients implement
its client half, and changes here drive both.

The interaction is a chat where the server streams back not just the answer but
the **workflow** behind it — so the user can watch status, approve gated steps,
and inspect (debug) the model interaction.

- `events.ts` — the canonical message types (TypeScript reference). The web app's
  `src/lib/protocol.ts` mirrors these today; once the contract settles we'll
  generate the TS / Swift / Kotlin clients from a language-neutral schema
  (JSON Schema or protobuf) kept here.

## Shape (v0, draft)

Client → server:

- `ask`       — pose a question (starts a session)
- `approve`   — approve a gated step (e.g. "run the generated program")
- `reject`    — reject a gated step, optionally with a reason

Server → client (streamed over the session):

- `status`           — a workflow step changed state (pending → running →
                       awaiting-approval → done / error)
- `approval-request` — a step needs the user's go-ahead, with a payload to review
- `debug`            — inspectable detail for a step (the aliased manifest, the
                       model prompt/response, the generated Mojo program, …)
- `message`          — an assistant chat message (the answer)
- `error`            — the session failed

## Transport: WebSocket

Decided (see [`../server/STREAMING.md`](../server/STREAMING.md)): a **WebSocket**
connection per session. flare's SSE/chunked primitives aren't reactor-wired yet,
but its WebSocket server is production-ready and full-duplex — which the approval
gate needs (client → server `approve`/`reject` on the same socket).

Framing: **one JSON object per text frame** — a `ClientMessage` from the client,
a `ServerEvent` from the server (the types in `events.ts`). The client opens the
socket, sends `ask`, receives the event stream, answers any `approval-request`,
and the server closes after the final `message`.

The web client implements this in `web/src/lib/wsClient.ts`
(`?server=ws://host:10000/chat`); the Mojo server half is the next increment.

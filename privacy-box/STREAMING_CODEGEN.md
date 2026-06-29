# Streaming codegen — design + implementation plan

Goal: stream the frontier model's codegen response so the program appears **live** in
the UI (and "Writing the program" shows real progress, not just an elapsed timer).

## Why it's not trivial (findings)

- `RemoteClient._anthropic` (`src/transport.mojo`) builds one POST to Anthropic
  `/v1/messages` and calls `HttpClient().send(req)` — a **blocking, whole-body** read
  (`resp.json()`). No intermediary data.
- flare's HTTP **client** has no streaming-response read: `send → _do_request →
  _read_http_response_tls → _read_all_tls` reads the entire body to EOF, then parses.
  (flare has *server-side* SSE — `SseChannel`, `StreamingResponse` — but not a client
  that consumes a streamed response.)
- The streaming primitive that DOES exist: `TlsStream.read(buf, size)` (incremental),
  plus `TlsStream.connect_timeout`, `write_all`, `close` (`flare/tls/stream.mojo`).

## Architecture decision

SSE is **Anthropic-specific**, so the streaming read belongs in `transport.mojo` (the
Anthropic client), NOT flare's generic client. Drive `TlsStream` directly there.

## Increment 1 — `RemoteClient._anthropic_stream(prompt) -> Generated`

Self-contained; opt-in via `$MILLFOLIO_STREAM_CODEGEN` (dispatch from `RemoteClient.codegen`
so default behaviour is unchanged until it's proven).

1. Body = same as `_anthropic` + `"stream":true`. Headers add `accept: text/event-stream`.
2. Parse host + target from `base_url` (`https://api.anthropic.com/v1` → host
   `api.anthropic.com`, target `/v1/messages`). `TlsStream.connect_timeout(host, 443,
   TlsConfig(), 120000)`; `write_all(wire_bytes)`.
3. Read loop over `TlsStream.read(buf, N)` accumulating into a `List[UInt8]`:
   - **Skip headers**: find `\r\n\r\n` once.
   - **De-chunk**: the streamed response is almost certainly `Transfer-Encoding:
     chunked`, so de-frame (`<hex-size>\r\n<bytes>\r\n` … `0\r\n\r\n`) BEFORE SSE
     parsing. (This is the part that makes it non-trivial — flare's framed reader does
     the equivalent server-side.)
   - **SSE parse** the de-chunked bytes line-by-line. For `data: <json>`, `_loads` it;
     on `type=="content_block_delta"` append `delta.text` to the program; on
     `message_delta` capture `stop_reason==max_tokens` (→ raise, as `_anthropic` does)
     and `usage.output_tokens`.
   - bytes→String per complete line via `String(unsafe_from_utf8=span[start:nl])` (a
     full line is valid UTF-8 — a codepoint can't span `\n`; only convert complete
     lines so a read that splits a multibyte char mid-stream is safe).
4. `close()`, `buf.free()`, `Generated(_strip_fences(code)^, toks)`.

Verify: env-gate it on, run a real query (needs `ANTHROPIC_API_KEY`), confirm the same
program is produced as the blocking path.

## Increment 2 — live progress to the UI

`_anthropic_stream` needs to deliver each delta upward. Threading a **capturing**
callback through `vault_codegen → _codegen → _anthropic_stream` is the open question
(check Mojo closure-capture ergonomics; flare's server handlers are a reference). The
app-server WS handler passes a callback that emits a `debug`/`status` event per delta
(or batched every ~N chars) so the program streams into the chat. The existing
elapsed-timer already shows the step is alive; this adds the content.

## Increment 3 — polish

Backpressure/limits (don't emit an event per token — coalesce), error handling on a
dropped stream (fall back to `_anthropic`), and a unit test for the de-chunk + SSE
parser against a captured fixture (deterministic, no network).

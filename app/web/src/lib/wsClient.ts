// Real millfolio client over WebSocket — the production transport (see
// ../../../server/STREAMING.md). One WS connection per session: send `ask`,
// receive a stream of ServerEvents, answer any `approval-request` with
// `approve`/`reject` on the same socket. Same MillfolioClient interface as the
// mock, so the UI is identical either way.

import type {
  ClientMessage,
  ServerEvent,
  Session,
  MillfolioClient,
} from "./protocol";

// crypto.randomUUID() throws in a non-secure context / older Safari; fall back so
// opening a session never throws.
function safeId(): string {
  try {
    if (typeof crypto !== "undefined" && crypto.randomUUID) return crypto.randomUUID();
  } catch {}
  return `ask-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
}

class WsSession implements Session {
  private ws: WebSocket;
  private ready = false;
  private pending: ClientMessage[] = [];
  private done = false; // a terminal event (final message or error) was delivered

  constructor(
    url: string,
    text: string,
    private onEvent: (e: ServerEvent) => void,
    demoToken?: string,
  ) {
    this.ws = new WebSocket(url);

    this.ws.onopen = () => {
      this.ready = true;
      // demo_token: the demo bot gate echoes the Turnstile-minted token on the ask
      // frame (server on_connect validates it). Omitted (harmless) outside the demo.
      this.put({ type: "ask", id: safeId(), text, ...(demoToken ? { demo_token: demoToken } : {}) });
      for (const m of this.pending) this.write(m);
      this.pending = [];
    };

    this.ws.onmessage = (ev) => {
      try {
        const e = JSON.parse(ev.data) as ServerEvent;
        // The server closes the socket right after the final message/error; mark
        // the session done so the close below isn't reported as a drop.
        if (e.type === "message" || e.type === "error") this.done = true;
        this.onEvent(e);
      } catch {
        this.onEvent({ type: "error", message: "malformed event from server" });
      }
    };

    this.ws.onerror = () => {
      if (this.done) return;
      this.done = true;
      this.onEvent({ type: "error", message: `Can't reach the server at ${url}.` });
    };

    // If the socket closes BEFORE a final answer (e.g. the server was restarted
    // mid-request, as during a release), surface it instead of hanging silently.
    this.ws.onclose = () => {
      if (this.done) return;
      this.done = true;
      this.onEvent({
        type: "error",
        message:
          "The server stopped responding (connection closed) — it may be restarting. Try again in a moment.",
      });
    };
  }

  approve(stepId: string) {
    this.put({ type: "approve", stepId });
  }
  reject(stepId: string, reason?: string) {
    this.put({ type: "reject", stepId, reason });
  }

  private write(m: ClientMessage) {
    this.ws.send(JSON.stringify(m));
  }
  // Buffer until the socket is open, then flush in order.
  private put(m: ClientMessage) {
    if (this.ready && this.ws.readyState === WebSocket.OPEN) this.write(m);
    else this.pending.push(m);
  }
}

export function createWsClient(
  url: string,
  getDemoToken?: () => string,
): MillfolioClient {
  return {
    ask(text, onEvent) {
      return new WsSession(url, text, onEvent, getDemoToken?.());
    },
  };
}

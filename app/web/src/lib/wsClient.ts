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

class WsSession implements Session {
  private ws: WebSocket;
  private ready = false;
  private pending: ClientMessage[] = [];

  constructor(
    url: string,
    text: string,
    private onEvent: (e: ServerEvent) => void,
  ) {
    this.ws = new WebSocket(url);

    this.ws.onopen = () => {
      this.ready = true;
      this.put({ type: "ask", id: crypto.randomUUID(), text });
      for (const m of this.pending) this.write(m);
      this.pending = [];
    };

    this.ws.onmessage = (ev) => {
      try {
        this.onEvent(JSON.parse(ev.data) as ServerEvent);
      } catch {
        this.onEvent({ type: "error", message: "malformed event from server" });
      }
    };

    this.ws.onerror = () =>
      this.onEvent({ type: "error", message: `cannot reach server at ${url}` });
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

export function createWsClient(url: string): MillfolioClient {
  return {
    ask(text, onEvent) {
      return new WsSession(url, text, onEvent);
    },
  };
}

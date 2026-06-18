// Veilens protocol — canonical message types (v0, draft).
//
// Source of truth for the chat + workflow/approval/debug contract between the
// clients and the server. The web app mirrors these in web/src/lib/protocol.ts;
// they'll be generated from a neutral schema once the contract settles.

/** Lifecycle of a workflow step shown in the panel. */
export type StepState =
  | "pending"
  | "running"
  | "awaiting-approval"
  | "done"
  | "error";

// ── client → server ──────────────────────────────────────────────────────────
export type ClientMessage =
  | { type: "ask"; id: string; text: string }
  | { type: "approve"; stepId: string }
  | { type: "reject"; stepId: string; reason?: string };

// ── server → client (streamed) ───────────────────────────────────────────────
export interface StatusEvent {
  type: "status";
  stepId: string;
  label: string;
  state: StepState;
  detail?: string;
}

export interface ApprovalRequestEvent {
  type: "approval-request";
  stepId: string;
  label: string;
  /** What the user is approving — e.g. the generated program to run. */
  payload: { title: string; body: string; language?: string };
}

export interface DebugEvent {
  type: "debug";
  stepId: string;
  title: string;
  body: string;
  language?: string; // for syntax highlighting (e.g. "mojo", "json")
}

export interface MessageEvent {
  type: "message";
  id: string;
  role: "assistant";
  text: string;
}

export interface ErrorEvent {
  type: "error";
  message: string;
}

export type ServerEvent =
  | StatusEvent
  | ApprovalRequestEvent
  | DebugEvent
  | MessageEvent
  | ErrorEvent;

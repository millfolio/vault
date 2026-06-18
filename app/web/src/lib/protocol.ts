// Veilens protocol types — mirrors ../../../protocol/events.ts (the source of
// truth). Kept as a local copy until we generate the client from a neutral
// schema. Keep in sync with protocol/events.ts.

export type StepState =
  | "pending"
  | "running"
  | "awaiting-approval"
  | "done"
  | "error";

export type ClientMessage =
  | { type: "ask"; id: string; text: string }
  | { type: "approve"; stepId: string }
  | { type: "reject"; stepId: string; reason?: string };

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
  payload: { title: string; body: string; language?: string };
}

export interface DebugEvent {
  type: "debug";
  stepId: string;
  title: string;
  body: string;
  language?: string;
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

/** A live session: receives server events, can answer approval gates. */
export interface Session {
  approve(stepId: string): void;
  reject(stepId: string, reason?: string): void;
}

export interface VeilensClient {
  ask(text: string, onEvent: (e: ServerEvent) => void): Session;
}

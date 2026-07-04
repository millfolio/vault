// millfolio protocol — canonical message types (v0, draft).
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
  // "run" — the "Run again" path: re-run a SAVED program (from the chat history)
  // directly, with NO model call. `program` is the stored generated program; `text`
  // is the original question (for the stats/history record). Streams the SAME events
  // an "ask" produces (minus manifest/codegen/approval).
  | { type: "run"; id: string; program: string; text: string }
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

// ── declarative result spec (COMPUTE_VS_RENDER.md, Phase 1) ──────────────────
// The generated program COMPUTES typed data and emits this versioned spec; a
// deterministic presenter in the client picks the view from the data's shape.
// Money crosses the seam as {raw, text} (the typed-money invariant): `raw` drives
// axes/aggregation, `text` is the exact money() display — never a bare float.

/** A typed value — a KPI value or a table cell. `type` tags it so the client never
 *  guesses a type from a formatted string. */
export type ResultValue =
  | { type: "money"; raw: number; text: string }
  | { type: "count"; raw: number; text: string }
  | { type: "date"; value: string }
  | { type: "text"; value: string };

/** One data block. Phase 1 renders kpi + table; series is rendered as a table
 *  (charts are Phase 2). */
export type ResultBlock =
  | { kind: "kpi"; label: string; value: ResultValue }
  | { kind: "table"; headers: string[]; rows: ResultValue[][] }
  | {
      kind: "series";
      seriesKind: "time" | "category";
      title: string;
      hint?: string; // optional presenter nudge ("line"/"bar"/…) — Phase 2
      x: { type: "date" | "category"; values: string[] };
      y: { type: "money"; raw: number[]; text: string[] };
    };

/** The versioned result spec. Clients ignore-with-fallback (render `text` only)
 *  on an unknown `v`. `data` absent → a plain text answer (unchanged from today). */
export interface ResultSpec {
  v: number;
  text: string;
  data?: ResultBlock[];
}

export interface MessageEvent {
  type: "message";
  id: string;
  role: "assistant";
  text: string;
  /** Optional rich result the client auto-visualizes below the text bubble. */
  result?: ResultSpec;
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

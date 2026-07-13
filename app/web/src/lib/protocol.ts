// millfolio protocol types — mirrors ../../../protocol/events.ts (the source of
// truth). Kept as a local copy until we generate the client from a neutral
// schema. Keep in sync with protocol/events.ts.

export type StepState =
  | "pending"
  | "running"
  | "awaiting-approval"
  | "done"
  | "error";

export type ClientMessage =
  | { type: "ask"; id: string; text: string; demo_token?: string }
  // "run" — the "Run again" path: re-run a SAVED program directly (no model call).
  // `program` is the stored generated program; `text` is the original question (for
  // the stats/history record). Streams the same events an "ask" produces.
  | { type: "run"; id: string; program: string; text: string }
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

/** A column's semantic entity — the trusted chrome renders cells in such a
 *  column as links into the filtered Vault view (/vault?merchant=… etc.).
 *  Optional + additive: specs without it stay valid, and the renderer also
 *  falls back to the column HEADER name ("merchant"/"tag"/"month") so widgets
 *  saved before this field existed become clickable without regeneration. */
export type EntityKind = "merchant" | "tag" | "month";

/** One data block. Phase 1 renders kpi + table; series is rendered as a table
 *  (charts are Phase 2). `map` is an offline bubble map (proportional-symbol) over
 *  a bundled outline — points are ISO-3166 alpha-3 country codes (level "country"),
 *  US 2-letter state codes (level "state"), or (level "city", US-only) a 5-digit US
 *  zip that PLACES the bubble by its gazetteer centroid + an optional `label` (the
 *  city name) that DISPLAYS it — each sized by its money value. */
export type ResultBlock =
  | { kind: "kpi"; label: string; value: ResultValue }
  | { kind: "table"; headers: string[]; rows: ResultValue[][]; entities?: (EntityKind | null)[] }
  | {
      kind: "series";
      seriesKind: "time" | "category";
      title: string;
      hint?: string; // optional presenter nudge ("line"/"bar"/…) — Phase 2
      x: { type: "date" | "category"; values: string[] };
      y: { type: "money"; raw: number[]; text: string[] };
    }
  | {
      kind: "map";
      level: "country" | "state" | "city";
      title: string;
      // `code`: ISO3 (country) / US 2-letter (state) / US zip (city). `label` is set
      // only for city points (the city name); country/state points carry none.
      points: { code: string; value: ResultValue; label?: string }[];
    }
  | {
      // A share-of-whole breakdown — a total split across a SMALL number of named
      // parts (≤ ~8). The client computes each slice's percentage from its money
      // `raw` and draws an offline SVG pie/donut.
      kind: "pie";
      title: string;
      slices: { label: string; value: ResultValue }[];
    };

/** The versioned result spec. Clients ignore-with-fallback (render `text` only)
 *  on an unknown `v`. `data` absent → a plain text answer (unchanged from today). */
export interface ResultSpec {
  v: number;
  text: string;
  data?: ResultBlock[];
  /** Seed-board example results are marked preview: true — the chrome renders
   *  them with the EXAMPLE badge and suppresses entity deep-links (their
   *  values are synthetic and don't exist in the user's vault). */
  preview?: boolean;
}

export interface MessageEvent {
  type: "message";
  id: string;
  role: "assistant";
  text: string;
  source?: string;       // filename of the first document used to answer
  sourceAlias?: string;  // its alias → link to /api/doc?alias=<sourceAlias>
  result?: ResultSpec;   // optional rich result → auto-visualized below the bubble
}

export interface ErrorEvent {
  type: "error";
  message: string;
}

/** Category tags the generated program filtered on (comma-joined) → a chip. */
export interface TagsEvent {
  type: "tags";
  tags: string;
}

/** A reusable tag the model suggested (`# SUGGEST_TAG`) for a category that isn't
 *  a tag yet → the UI offers to save it to the category rules. */
export interface TagProposalEvent {
  type: "tag-proposal";
  name: string;
  ml?: boolean;      // true = AI rule (prompt), false/absent = keyword rule
  keywords?: string; // keyword rule: comma-joined keywords
  prompt?: string;   // AI rule: the yes/no question to classify with
}

export type ServerEvent =
  | StatusEvent
  | ApprovalRequestEvent
  | DebugEvent
  | MessageEvent
  | TagsEvent
  | TagProposalEvent
  | ErrorEvent;

/** A live session: receives server events, can answer approval gates. */
export interface Session {
  approve(stepId: string): void;
  reject(stepId: string, reason?: string): void;
}

export interface MillfolioClient {
  ask(text: string, onEvent: (e: ServerEvent) => void): Session;
  /** Re-run a SAVED program directly (no model call). `program` is the stored
   *  generated program; `question` is the original question (for the record). */
  run(program: string, question: string, onEvent: (e: ServerEvent) => void): Session;
}

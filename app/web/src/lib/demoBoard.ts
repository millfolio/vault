// demoBoard — a localStorage-backed Millwright store for the PUBLIC DEMO.
//
// The demo server is read-only (every /api/millwright write is rejected), but
// the Board is millfolio's showcase — so in demo mode the browser keeps its OWN
// version chain, seeded once from the server's board (version 1), with the same
// semantics as the real store: immutable content-addressed versions, an active
// pointer (revert moves it, history never rewrites), and validate-before-accept.
// Everything lives in this browser's localStorage; "reset" clears it back to
// the server's board. No program docs exist client-side, so the data-plane rule
// ("a widget must have a pinned program") maps to "a widget must have a result
// snapshot" — a demo pin stores the answer's rendered result, and refresh stays
// server-only (hidden in demo).
//
// The validator is a light port of handlers_millwright.validate_spec — keep the
// RULES in sync (v/kind/widgets/ids/titles/spans/layout/no-remote-URLs).

export type DemoVersion = {
  hash: string;
  parent: string;
  ts: number;
  author: string;
  message: string;
  spec: unknown;
};
export type DemoSnapshot = { ts: number; result: unknown; preview?: boolean };
export type DemoStored = {
  versions: DemoVersion[]; // oldest → newest (append order, like the JSONL)
  active: string;
  results: Record<string, DemoSnapshot>;
};

const KEY = "millwright-demo-board.v1";

// FNV-1a 64 over UTF-8 bytes, 16 lowercase hex chars — the SAME function the
// server uses, so identical spec text gets the identical version id.
export function fnv1a64(text: string): string {
  let h = 0xcbf29ce484222325n;
  const bytes = new TextEncoder().encode(text);
  for (const b of bytes) {
    h ^= BigInt(b);
    h = (h * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return h.toString(16).padStart(16, "0");
}

function pathSafeId(id: unknown): boolean {
  return typeof id === "string" && /^w-[a-z0-9-]+$/.test(id);
}

/** "" when acceptable, else a human reason — mirrors the server lint, with the
 *  program-doc rule mapped to "has a result snapshot or already existed". */
export function validateSpec(
  text: string,
  knownIds: Set<string>,
): string {
  if (text.includes("http://") || text.includes("https://"))
    return "remote URLs are not allowed in a spec";
  let v: any;
  try {
    v = JSON.parse(text);
  } catch {
    return "spec is not valid JSON";
  }
  if (typeof v !== "object" || v === null || Array.isArray(v))
    return "spec must be a JSON object";
  if (v.v !== 1) return 'spec must declare "v": 1';
  if (v.kind !== "dashboard") return 'spec must declare "kind": "dashboard"';
  if (!Array.isArray(v.widgets)) return 'spec must have a "widgets" array';
  const seen = new Set<string>();
  for (const w of v.widgets) {
    if (typeof w !== "object" || w === null) return "each widget must be an object";
    if (!pathSafeId(w.id)) return `widget id must be w- followed by [a-z0-9-]: ${w.id}`;
    if (seen.has(w.id)) return `duplicate widget id: ${w.id}`;
    if (typeof w.title !== "string" || w.title.length === 0)
      return `widget ${w.id} needs a non-empty title`;
    for (const k of ["w", "h"] as const) {
      if (w[k] !== undefined && (!Number.isInteger(w[k]) || w[k] < 1 || w[k] > 6))
        return `widget ${w.id}: ${k} must be an int 1..6`;
    }
    if (!knownIds.has(w.id)) return `widget ${w.id} has no pinned result`;
    seen.add(w.id);
  }
  if (v.layout !== undefined) {
    const lo = v.layout;
    if (typeof lo !== "object" || lo === null || Array.isArray(lo))
      return '"layout" must be an object';
    if (lo.cols !== undefined && (!Number.isInteger(lo.cols) || lo.cols < 1 || lo.cols > 6))
      return "layout.cols must be an int 1..6";
    if (lo.order !== undefined) {
      if (!Array.isArray(lo.order)) return "layout.order must be an array of widget ids";
      for (const id of lo.order) {
        if (typeof id !== "string") return "layout.order entries must be widget ids";
        if (!seen.has(id)) return `layout.order references unknown widget: ${id}`;
      }
    }
  }
  return "";
}

function read(): DemoStored | null {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return null;
    const d = JSON.parse(raw);
    if (!Array.isArray(d?.versions) || typeof d?.active !== "string") return null;
    return d as DemoStored;
  } catch {
    return null; // torn/legacy → reseed
  }
}

function write(d: DemoStored) {
  try {
    localStorage.setItem(KEY, JSON.stringify(d));
  } catch {} // quota/private mode — edits just don't persist
}

/** Seed (once) from the server's read-only board; later calls return the local
 *  chain. `server` is the GET /api/millwright payload. */
export function loadDemoBoard(server: {
  spec: unknown;
  results: Record<string, DemoSnapshot>;
}): DemoStored {
  const have = read();
  if (have) return have;
  const specText = JSON.stringify(server.spec);
  const seeded: DemoStored = {
    versions: [
      {
        hash: fnv1a64(specText),
        parent: "",
        ts: Math.floor(Date.now() / 1000),
        author: "millfolio",
        message: "demo board",
        spec: server.spec,
      },
    ],
    active: fnv1a64(specText),
    results: server.results ?? {},
  };
  write(seeded);
  return seeded;
}

export function activeSpec(d: DemoStored): unknown {
  const v = d.versions.find((x) => x.hash === d.active) ?? d.versions[d.versions.length - 1];
  return v?.spec ?? null;
}

/** Validate → content-address → append (dedupe on hash) → move the pointer.
 *  Throws with the lint reason on an invalid spec. */
export function acceptSpec(
  d: DemoStored,
  specText: string,
  message: string,
  author: string,
): DemoStored {
  const why = validateSpec(specText, new Set(Object.keys(d.results)));
  if (why) throw new Error(why);
  const canonical = JSON.stringify(JSON.parse(specText));
  const hash = fnv1a64(canonical);
  const next: DemoStored = { ...d, active: hash };
  if (!d.versions.some((v) => v.hash === hash)) {
    next.versions = [
      ...d.versions,
      {
        hash,
        parent: d.active,
        ts: Math.floor(Date.now() / 1000),
        author,
        message,
        spec: JSON.parse(canonical),
      },
    ];
  }
  write(next);
  return next;
}

export function revertTo(d: DemoStored, hash: string): DemoStored {
  if (!d.versions.some((v) => v.hash === hash)) return d;
  const next = { ...d, active: hash };
  write(next);
  return next;
}

/** A demo pin: store the answer's rendered result as the widget's snapshot and
 *  append the widget to the active spec (a new local version). */
export function pinDemo(
  d: DemoStored,
  q: string,
  title: string,
  result: unknown,
): DemoStored {
  const blob = JSON.stringify(result ?? "");
  if (blob.includes("http://") || blob.includes("https://"))
    throw new Error("remote URLs are not allowed in a result");
  const id = "w-" + fnv1a64(q + "\x1f" + blob + "\x1f" + Date.now()).slice(0, 8);
  const spec: any = JSON.parse(JSON.stringify(activeSpec(d) ?? { v: 1, kind: "dashboard", widgets: [], layout: { cols: 2, order: [] } }));
  spec.widgets.push({ id, title, q, w: 1, h: 1 });
  if (Array.isArray(spec.layout?.order)) spec.layout.order.push(id);
  const withResult: DemoStored = {
    ...d,
    results: { ...d.results, [id]: { ts: Math.floor(Date.now() / 1000), result } },
  };
  return acceptSpec(withResult, JSON.stringify(spec), `pinned "${title}"`, "you");
}

/** Back to the server's board: drop every local version and result. */
export function resetDemoBoard() {
  try {
    localStorage.removeItem(KEY);
  } catch {}
}

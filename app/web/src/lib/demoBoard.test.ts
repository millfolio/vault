// demoBoard — the localStorage millwright store the DEMO Board edits against.
// Covers the version-chain semantics (seed / accept / dedupe / revert / pin /
// reset) and the validator port (keep its RULES in sync with the server's
// handlers_millwright.validate_spec).
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  acceptSpec,
  activeSpec,
  fnv1a64,
  loadDemoBoard,
  pinDemo,
  resetDemoBoard,
  revertTo,
  validateSpec,
} from "./demoBoard";

const seedSpec = {
  v: 1,
  kind: "dashboard",
  widgets: [{ id: "w-aaa", title: "A", q: "q?", w: 1, h: 1 }],
  layout: { cols: 2, order: ["w-aaa"] },
};
const seedServer = {
  spec: seedSpec,
  results: { "w-aaa": { ts: 1, result: { v: 1, text: "hi" } } },
};

// This jsdom setup ships NO localStorage (the module degrades to non-persistent
// in that case) — stub a Map-backed one so the persistence semantics are testable.
// The suite's afterEach unstubs globals, so re-stub per test.
beforeEach(() => {
  const m = new Map<string, string>();
  vi.stubGlobal("localStorage", {
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, String(v)),
    removeItem: (k: string) => void m.delete(k),
  });
  resetDemoBoard();
});

describe("fnv1a64", () => {
  it("matches the server's constant for the starter spec shape", () => {
    // Content addressing must be deterministic and 16 lowercase hex chars.
    const h = fnv1a64("hello");
    expect(h).toMatch(/^[0-9a-f]{16}$/);
    expect(fnv1a64("hello")).toBe(h);
    expect(fnv1a64("hello!")).not.toBe(h);
  });
});

describe("validateSpec", () => {
  const ids = new Set(["w-aaa"]);
  it("accepts the seed spec", () => {
    expect(validateSpec(JSON.stringify(seedSpec), ids)).toBe("");
  });
  it("rejects remote URLs, bad ids, unknown widgets, bad spans", () => {
    expect(validateSpec('{"v":1,"kind":"dashboard","widgets":[],"x":"https://e"}', ids)).toMatch(/remote URLs/);
    const bad = (w: object) =>
      validateSpec(JSON.stringify({ ...seedSpec, widgets: [w], layout: undefined }), ids);
    expect(bad({ id: "w-../x", title: "t" })).toMatch(/widget id/);
    expect(bad({ id: "w-zzz", title: "t" })).toMatch(/no pinned result/);
    expect(bad({ id: "w-aaa", title: "" })).toMatch(/non-empty title/);
    expect(bad({ id: "w-aaa", title: "t", w: 9 })).toMatch(/1\.\.6/);
    expect(
      validateSpec(
        JSON.stringify({ ...seedSpec, layout: { cols: 2, order: ["w-ghost"] } }),
        ids,
      ),
    ).toMatch(/unknown widget/);
  });
});

describe("the chain", () => {
  it("seeds once from the server board", () => {
    const d = loadDemoBoard(seedServer);
    expect(d.versions).toHaveLength(1);
    expect(d.versions[0].author).toBe("millfolio");
    expect(d.active).toBe(d.versions[0].hash);
    // second load returns the stored chain, not a re-seed
    const again = loadDemoBoard({ spec: { v: 1, kind: "dashboard", widgets: [] }, results: {} });
    expect(again.versions[0].hash).toBe(d.versions[0].hash);
  });

  it("accept appends + moves the pointer; identical content dedupes to the same hash", () => {
    let d = loadDemoBoard(seedServer);
    const v1 = d.active;
    const edited = { ...seedSpec, widgets: [{ ...seedSpec.widgets[0], w: 2 }] };
    d = acceptSpec(d, JSON.stringify(edited), "widened", "you");
    expect(d.versions).toHaveLength(2);
    expect(d.active).not.toBe(v1);
    // re-accepting the ORIGINAL content re-activates the original hash, no new version
    d = acceptSpec(d, JSON.stringify(seedSpec), "back", "you");
    expect(d.versions).toHaveLength(2);
    expect(d.active).toBe(v1);
  });

  it("rejects an invalid edit without touching the chain", () => {
    let d = loadDemoBoard(seedServer);
    expect(() => acceptSpec(d, '{"v":2}', "nope", "you")).toThrow(/"v": 1/);
    expect(d.versions).toHaveLength(1);
  });

  it("revert moves the pointer only", () => {
    let d = loadDemoBoard(seedServer);
    const v1 = d.active;
    d = acceptSpec(d, JSON.stringify({ ...seedSpec, layout: { cols: 3, order: ["w-aaa"] } }), "3 cols", "you");
    d = revertTo(d, v1);
    expect(d.active).toBe(v1);
    expect(d.versions).toHaveLength(2);
    expect(revertTo(d, "not-a-hash").active).toBe(v1);
  });

  it("pin adds a widget + its result as a new version", () => {
    let d = loadDemoBoard(seedServer);
    d = pinDemo(d, "how much on coffee?", "Coffee", { v: 1, text: "$12" });
    const spec: any = activeSpec(d);
    expect(spec.widgets).toHaveLength(2);
    const pinned = spec.widgets[1];
    expect(pinned.id).toMatch(/^w-[0-9a-f]{8}$/);
    expect(d.results[pinned.id].result).toEqual({ v: 1, text: "$12" });
    expect(spec.layout.order).toContain(pinned.id);
    expect(d.versions[d.versions.length - 1].message).toBe('pinned "Coffee"');
  });

  it("pin rejects results carrying URLs", () => {
    const d = loadDemoBoard(seedServer);
    expect(() => pinDemo(d, "q", "t", { v: 1, text: "see https://evil" })).toThrow(/remote URLs/);
  });
});

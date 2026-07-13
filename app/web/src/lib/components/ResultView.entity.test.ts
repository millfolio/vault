// Source-contract tripwires for the Board→Vault entity links (same style as
// VaultPanel.records.test.ts: jsdom can't click Svelte anchors through the
// result renderer cheaply, so we pin the load-bearing source contracts that a
// refactor could silently drop).
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const rv = readFileSync(join(here, "ResultView.svelte"), "utf-8");
const vp = readFileSync(join(here, "VaultPanel.svelte"), "utf-8");

describe("ResultView entity links", () => {
  it("prefers the spec's explicit entities and falls back to header names", () => {
    expect(rv).toMatch(/entities\?\.\[i\]/);
    for (const name of ['"merchant"', '"tag"', '"tags"', '"month"']) {
      expect(rv.includes(name)).toBe(true);
    }
  });
  it("links point at the Vault tab with the entity as a query param", () => {
    expect(rv).toMatch(/\/vault\?\$\{kind\}=/);
    expect(rv).toMatch(/encodeURIComponent/);
  });
  it("only text cells become links (money/count cells stay plain)", () => {
    expect(rv).toMatch(/cell\.type === "text"/);
  });
});

describe("VaultPanel entity filters", () => {
  it("reads merchant/tag/month from the URL and lands on Records", () => {
    expect(vp).toMatch(/\["merchant", "tag", "month"\] as const/);
    expect(vp).toMatch(/if \(out\.length\) showRecords\(\)/);
  });
  it("matches EXACTLY on the normalized value, never substring", () => {
    // The clicked aggregate and the shown rows must agree: exact compare on
    // Txn.merchant (the index-time cleaned brand programs group by).
    expect(vp).toMatch(/\.trim\(\)\.toLowerCase\(\) !== v/);
    expect(vp).not.toMatch(/merchant.*includes\(v\)/);
  });
  it("chips clear one filter and update the URL in place", () => {
    expect(vp).toMatch(/searchParams\.delete\(kind\)/);
    expect(vp).toMatch(/history\.replaceState/);
  });
  it("the Category-tags strip recounts over the filtered rows", () => {
    expect(vp).toMatch(/displayTags/);
    expect(vp).toMatch(/\{#each displayTags as t\}/);
  });
});

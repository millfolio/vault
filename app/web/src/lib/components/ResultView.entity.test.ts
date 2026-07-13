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
  it("preview/example results never deep-link", () => {
    expect(rv).toMatch(/result\.preview/);
    expect(rv).toMatch(/headers\.map\(\(\) => null\)/);
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
  it("merchant matching is tiered: exact first, then prefix, then contains", () => {
    // Exact keeps the clicked-aggregate == shown-rows honesty when the two
    // normalizations agree; the fallbacks prevent zero-result clicks when the
    // Board program's cleaning and the record cleaning disagree (rc.7 bug:
    // "WHOLE FOODS" vs "Whole Foods Mkt").
    expect(vp).toMatch(/name\(t\) === v/);
    expect(vp).toMatch(/startsWith\(v\)/);
    expect(vp).toMatch(/includes\(v\)/);
  });
  it("chips clear one filter and update the URL in place", () => {
    expect(vp).toMatch(/searchParams\.delete\(kind\)/);
    expect(vp).toMatch(/history\.replaceState/);
  });
  it("the empty state names the active entity filters", () => {
    expect(vp).toMatch(/No records match \{entityFilters\.length/);
  });
  it("tag-strip chips apply the tag filter in place (URL updated)", () => {
    expect(vp).toMatch(/function filterByTag/);
    expect(vp).toMatch(/searchParams\.set\("tag", name\)/);
    expect(vp).toMatch(/onclick=\{\(\) => filterByTag\(t\.name\)\}/);
  });
  it("the Category-tags strip recounts over the filtered rows", () => {
    expect(vp).toMatch(/displayTags/);
    expect(vp).toMatch(/\{#each displayTags as t\}/);
  });
});

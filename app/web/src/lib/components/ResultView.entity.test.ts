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
// Table rendering (cells, entity/desc links, filters, footer total) lives in the
// extracted ResultTable child; ResultView keeps the entity DERIVATION (colEntities)
// + the chart-label wiring.
const rt = readFileSync(join(here, "ResultTable.svelte"), "utf-8");
const vp = readFileSync(join(here, "VaultPanel.svelte"), "utf-8");
const bar = readFileSync(join(here, "charts/BarChart.svelte"), "utf-8");
const pie = readFileSync(join(here, "charts/PieChart.svelte"), "utf-8");

describe("ResultView entity links", () => {
  it("prefers the spec's explicit entities and falls back to header names", () => {
    expect(rv).toMatch(/entities\?\.\[i\]/);
    for (const name of ['"merchant"', '"tag"', '"tags"', '"month"']) {
      expect(rv.includes(name)).toBe(true);
    }
  });
  it("table cell links point at the Vault tab with the entity as a query param", () => {
    expect(rt).toMatch(/\/vault\?\$\{kind\}=/);
    expect(rt).toMatch(/encodeURIComponent/);
  });
  it("preview/example results never deep-link", () => {
    expect(rv).toMatch(/result\.preview/);
    expect(rv).toMatch(/headers\.map\(\(\) => null\)/);
  });
  it("only text cells become links (money/count cells stay plain)", () => {
    expect(rt).toMatch(/cell\.type === "text"/);
  });
});

describe("ResultTable interactive features", () => {
  it("description-header text columns deep-link to /vault?desc=", () => {
    expect(rt).toMatch(/DESC_HEADERS/);
    expect(rt).toMatch(/\/vault\?desc=/);
  });
  it("a footer total sums each numeric column over the FILTERED rows", () => {
    expect(rt).toMatch(/const totals = \$derived/);
    expect(rt).toMatch(/for \(const r of filteredRows\)/);
    expect(rt).toMatch(/<tfoot>/);
  });
  it("filters narrow the rows by amount range, date range, and text contains", () => {
    expect(rt).toMatch(/const filteredRows = \$derived/);
    expect(rt).toMatch(/function rowPasses/);
  });
});

describe("ResultView chart-label entity links", () => {
  it("infers a category chart's entity from its title (merchant/tag/month)", () => {
    expect(rv).toMatch(/function entityForCategory/);
    expect(rv).toMatch(/\\bmerchants\?\\b/);
    expect(rv).toMatch(/\\btags\?\\b/);
    expect(rv).toMatch(/\\bmonths\?\\b/);
  });
  it("only a CATEGORY axis links its labels (a time/line axis does not)", () => {
    expect(rv).toMatch(/seriesKind === "category"\s*\n?\s*\?\s*entityForCategory/);
  });
  it("preview results never deep-link chart labels", () => {
    // both the series and pie paths gate the entity on !result.preview
    expect(rv).toMatch(/!result\.preview && b\.seriesKind === "category"/);
    expect(rv).toMatch(/result\.preview \? null : entityForCategory\(undefined, b\.title\)/);
  });
  it("passes a Vault-filter href builder to the bar + pie charts", () => {
    expect(rv).toMatch(/function labelHrefFor/);
    expect(rv).toMatch(/\/vault\?\$\{entity\}=/);
    expect(rv).toMatch(/<BarChart[^>]*labelHref=\{labelHrefFor\(u\.entity\)\}/);
    expect(rv).toMatch(/<PieChart[^>]*labelHref=\{labelHrefFor\(u\.entity\)\}/);
  });
});

describe("chart components render labels as links only when given an href", () => {
  it("BarChart wraps the bar + x-label in an anchor when labelHref is set", () => {
    expect(bar).toMatch(/labelHref\?: \(label: string\) => string/);
    expect(bar).toMatch(/\{#if labelHref\}/);
    expect(bar).toMatch(/<a class="hit" href=\{labelHref\(xValues\[i\]\)\}/);
  });
  it("PieChart wraps the slice + legend label in an anchor when labelHref is set", () => {
    expect(pie).toMatch(/labelHref\?: \(label: string\) => string/);
    expect(pie).toMatch(/<a class="hit" href=\{labelHref\(slices\[i\]\.label\)\}/);
    expect(pie).toMatch(/<a class="lbl link" href=\{labelHref\(s\.label\)\}/);
  });
});

describe("VaultPanel entity filters", () => {
  it("reads merchant/tag/month/desc from the URL and lands on Records", () => {
    expect(vp).toMatch(/\["merchant", "tag", "month", "desc"\] as const/);
    expect(vp).toMatch(/if \(out\.length\) showRecords\(\)/);
  });
  it("a desc filter (from a result-table description link) matches by substring", () => {
    expect(vp).toMatch(/f\.kind === "desc"/);
    expect(vp).toMatch(/t\.desc\.toLowerCase\(\)\.includes\(v\)/);
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

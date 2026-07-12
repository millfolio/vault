import { readFileSync } from "node:fs";
import { describe, it, expect } from "vitest";

// Layout-contract tripwires for the Board tile header (same pattern as
// VaultPanel.records.test.ts, same reason: jsdom computes no layout, and the
// phone regression class here is "a rigid decoration crowds the affordances
// off-screen"). The ✎/↻/× buttons are the CONTENT of the tools strip — they
// must never flex-shrink; the stamp is decoration and must yield first.
const src = readFileSync("src/lib/components/MillwrightPanel.svelte", "utf-8");
const rule = (sel: string) => src.split(sel)[1]?.split("}")[0] ?? "";

describe("Board tile-tools layout contract", () => {
  it("the stamp is the shrinkable, ellipsized element", () => {
    const stamp = rule(".stamp {");
    expect(stamp).toMatch(/flex:\s*0 1 auto/);
    expect(stamp).toMatch(/min-width:\s*0/);
    expect(stamp).toMatch(/text-overflow:\s*ellipsis/);
  });

  it("the tool buttons never shrink", () => {
    const tool = rule(".tool {");
    expect(tool).toMatch(/flex:\s*none/);
  });

  it("the tools strip may shrink (so the stamp yields), the title truncates", () => {
    expect(rule(".tile-tools {")).toMatch(/min-width:\s*0/);
    const h3 = rule(".tile-head h3 {");
    expect(h3).toMatch(/min-width:\s*0/);
    expect(h3).toMatch(/text-overflow:\s*ellipsis/);
  });

  it("touch devices get enlarged tap targets", () => {
    expect(src).toMatch(/@media \(pointer: coarse\)/);
  });
});

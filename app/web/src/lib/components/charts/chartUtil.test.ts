import { describe, it, expect } from "vitest";
import { pieArcs, donutSector } from "./chartUtil";

const TAU = 2 * Math.PI;

describe("pieArcs", () => {
  it("splits into cumulative arcs whose fractions sum to 1", () => {
    const arcs = pieArcs([75, 25]);
    expect(arcs).toHaveLength(2);
    expect(arcs[0].frac).toBeCloseTo(0.75, 6);
    expect(arcs[1].frac).toBeCloseTo(0.25, 6);
    // contiguous, covering the full circle
    expect(arcs[0].a0).toBeCloseTo(0, 6);
    expect(arcs[0].a1).toBeCloseTo(arcs[1].a0, 6);
    expect(arcs[1].a1).toBeCloseTo(TAU, 6);
  });

  it("makes a single slice a full circle", () => {
    const arcs = pieArcs([500]);
    expect(arcs).toHaveLength(1);
    expect(arcs[0].frac).toBeCloseTo(1, 6);
    expect(arcs[0].a1 - arcs[0].a0).toBeCloseTo(TAU, 6);
  });

  it("keeps a tiny slice positive and visible in the legend share", () => {
    const arcs = pieArcs([999, 1]);
    expect(arcs[1].frac).toBeGreaterThan(0);
    expect(arcs[1].frac).toBeCloseTo(0.001, 6);
  });

  it("treats negatives / non-finite as 0 (share always in [0,1])", () => {
    const arcs = pieArcs([100, -40, NaN]);
    expect(arcs[0].frac).toBeCloseTo(1, 6);
    expect(arcs[1].frac).toBe(0);
    expect(arcs[2].frac).toBe(0);
  });

  it("returns all-zero fractions for a zero total (empty state)", () => {
    const arcs = pieArcs([0, 0]);
    expect(arcs.every((a) => a.frac === 0)).toBe(true);
  });
});

describe("donutSector", () => {
  it("draws a closed ring (two arcs) for a full sweep", () => {
    const d = donutSector(130, 130, 110, 62, 0, TAU);
    // two outer + two inner arcs
    expect((d.match(/A/g) ?? []).length).toBe(4);
    expect(d.trim().endsWith("Z")).toBe(true);
  });

  it("draws an annular wedge (one outer + one inner arc) for a partial sweep", () => {
    const d = donutSector(130, 130, 110, 62, 0, Math.PI / 2);
    expect((d.match(/A/g) ?? []).length).toBe(2);
  });

  it("sets the large-arc flag past a half turn", () => {
    const small = donutSector(130, 130, 110, 62, 0, Math.PI / 3);
    const big = donutSector(130, 130, 110, 62, 0, (5 * Math.PI) / 3);
    expect(small).toContain("0 1 "); // large-arc flag 0
    expect(big).toContain("1 1 "); // large-arc flag 1
  });
});

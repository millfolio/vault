import { describe, it, expect } from "vitest";
import { projectUS, loadZipCentroids, titleCaseCity } from "./mapData";

describe("projectUS (city bubble placement)", () => {
  it("projects a continental-US point into the [0,1] box", () => {
    // Kansas — near the center of the continental box → around the middle.
    const [x, y] = projectUS(38.5, -98.4);
    expect(x).toBeGreaterThan(0);
    expect(x).toBeLessThan(1);
    expect(y).toBeGreaterThan(0);
    expect(y).toBeLessThan(1);
    expect(x).toBeCloseTo(0.45, 1);
    expect(y).toBeCloseTo(0.44, 1);
  });

  it("puts a more-northern point higher on the map (smaller y)", () => {
    const [, yNorth] = projectUS(47.4, -120.4); // WA
    const [, ySouth] = projectUS(28.6, -81.7); // FL
    expect(yNorth).toBeLessThan(ySouth);
  });

  it("puts a more-western point further left (smaller x)", () => {
    const [xWest] = projectUS(37.2, -119.7); // CA
    const [xEast] = projectUS(42.9, -75.5); // NY
    expect(xWest).toBeLessThan(xEast);
  });
});

describe("zip → centroid lookup (lazy gazetteer)", () => {
  it("resolves a known zip to a plausible US [lat, lon] and drops an unknown one", async () => {
    const table = await loadZipCentroids();
    // 94015 = Daly City, CA — ~37.68 N, ~-122.48 W.
    const daly = table["94015"];
    expect(daly).toBeDefined();
    expect(daly[0]).toBeCloseTo(37.68, 1);
    expect(daly[1]).toBeCloseTo(-122.48, 1);
    // A non-existent zip is absent → the renderer counts it as an unmapped drop.
    expect(table["00000"]).toBeUndefined();
  });

  it("places a looked-up zip inside the map box", async () => {
    const table = await loadZipCentroids();
    const [lat, lon] = table["10001"]; // NYC
    const [x, y] = projectUS(lat, lon);
    expect(x).toBeGreaterThan(0.5); // east
    expect(x).toBeLessThan(1);
    expect(y).toBeGreaterThan(0);
    expect(y).toBeLessThan(1);
  });
});

describe("titleCaseCity (label from the uppercase .city field)", () => {
  it("title-cases a plain and a multi-word name", () => {
    expect(titleCaseCity("DALY CITY")).toBe("Daly City");
    expect(titleCaseCity("SAN FRANCISCO")).toBe("San Francisco");
    expect(titleCaseCity("WINSTON-SALEM")).toBe("Winston-Salem");
  });
});

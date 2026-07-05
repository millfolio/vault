import { describe, it, expect } from "vitest";
import {
  fmtLoc,
  fmtDate,
  fmtMoney,
  fmtDollars,
  fmtBytes,
  fileForAlias,
  nameForAlias,
  opLabel,
  fmtDur,
  fmtEta,
  shortId,
} from "./format";

describe("fmtLoc", () => {
  it("joins state and country with a middot", () => {
    expect(fmtLoc({ state: "GA", country: "USA" })).toBe("GA · USA");
  });
  it("returns the single present part alone", () => {
    expect(fmtLoc({ state: "WA" })).toBe("WA");
    expect(fmtLoc({ country: "USA" })).toBe("USA");
  });
  it("is blank when neither is set, and trims whitespace", () => {
    expect(fmtLoc({})).toBe("");
    expect(fmtLoc({ state: "  ", country: "" })).toBe("");
    expect(fmtLoc({ state: " CA " })).toBe("CA");
  });
  it("prepends the city, title-cased, before the state", () => {
    expect(fmtLoc({ city: "DALY CITY", state: "CA", country: "USA" })).toBe("Daly City, CA · USA");
    expect(fmtLoc({ city: "SEATTLE", state: "WA", country: "USA" })).toBe("Seattle, WA · USA");
    expect(fmtLoc({ city: "SO SAN FRAN", state: "CA", country: "USA" })).toBe("So San Fran, CA · USA");
  });
  it("handles a city without a state, and no city (unchanged)", () => {
    expect(fmtLoc({ city: "DALY CITY", country: "USA" })).toBe("Daly City · USA");
    expect(fmtLoc({ city: "", state: "CA", country: "USA" })).toBe("CA · USA");
  });
});

describe("fmtDate", () => {
  it("appends a known statement year", () => {
    expect(fmtDate({ date: "4/03", year: 2026 })).toBe("4/03/2026");
  });
  it("shows the bare M/D when the year is unknown (0)", () => {
    expect(fmtDate({ date: "4/03", year: 0 })).toBe("4/03");
  });
});

describe("fmtMoney", () => {
  it("signs debits negative and credits positive, two decimals", () => {
    expect(fmtMoney(85, "debit")).toBe("-$85.00");
    expect(fmtMoney(52.1, "credit")).toBe("+$52.10");
  });
  it("uses the magnitude regardless of the amount's own sign", () => {
    expect(fmtMoney(-85, "debit")).toBe("-$85.00");
  });
  it("groups thousands", () => {
    expect(fmtMoney(1234.5, "debit")).toBe("-$1,234.50");
  });
});

describe("fmtDollars", () => {
  it("formats an absolute magnitude with two decimals", () => {
    expect(fmtDollars(1234.5)).toBe("$1,234.50");
    expect(fmtDollars(-9.9)).toBe("$9.90");
  });
});

describe("fmtBytes", () => {
  it("keeps sub-KiB in bytes", () => {
    expect(fmtBytes(512)).toBe("512 B");
  });
  it("scales into KB/MB with one decimal under 10, none above", () => {
    expect(fmtBytes(2048)).toBe("2.0 KB");
    expect(fmtBytes(20 * 1024)).toBe("20 KB");
    expect(fmtBytes(5 * 1024 * 1024)).toBe("5.0 MB");
  });
});

describe("fileForAlias / nameForAlias", () => {
  const files = [
    { alias: "file_0", name: "statement.pdf" },
    { alias: "file_1", name: "notes.md" },
  ];
  it("finds a file by alias", () => {
    expect(fileForAlias(files, "file_1")?.name).toBe("notes.md");
  });
  it("returns undefined / falls back to the alias when unmatched", () => {
    expect(fileForAlias(files, "file_9")).toBeUndefined();
    expect(nameForAlias(files, "file_9")).toBe("file_9");
  });
  it("resolves the real name when matched", () => {
    expect(nameForAlias(files, "file_0")).toBe("statement.pdf");
  });
  it("tolerates an undefined file list", () => {
    expect(fileForAlias(undefined, "file_0")).toBeUndefined();
    expect(nameForAlias(undefined, "file_0")).toBe("file_0");
  });
});

describe("opLabel", () => {
  it("maps known types and passes others through", () => {
    expect(opLabel("index")).toBe("Index");
    expect(opLabel("reindex")).toBe("Re-index");
    expect(opLabel("backfill")).toBe("Backfill");
    expect(opLabel("weird")).toBe("weird");
  });
});

describe("fmtDur", () => {
  it("shows seconds under a minute", () => {
    expect(fmtDur(100, 103)).toBe("3s");
  });
  it("shows m + zero-padded s at or over a minute", () => {
    expect(fmtDur(0, 64)).toBe("1m 04s");
    expect(fmtDur(0, 125)).toBe("2m 05s");
  });
  it("guards clock skew (finished < started) with an em dash", () => {
    expect(fmtDur(200, 100)).toBe("—");
  });
});

describe("fmtEta", () => {
  it("shows seconds under 90s (never below 1s)", () => {
    expect(fmtEta(5)).toBe("5s");
    expect(fmtEta(0.2)).toBe("1s");
  });
  it("shows minutes at/over 90s", () => {
    expect(fmtEta(90)).toBe("2 min");
    expect(fmtEta(120)).toBe("2 min");
  });
});

describe("shortId", () => {
  it("drops the org prefix and the -int4 suffix, lowercased", () => {
    expect(shortId("Qwen/Qwen2.5-3B-Instruct-int4")).toBe("qwen2.5-3b-instruct");
    expect(shortId("Gemma-4-12B")).toBe("gemma-4-12b");
  });
});

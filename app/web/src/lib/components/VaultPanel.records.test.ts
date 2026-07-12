import { readFileSync } from "node:fs";
import { describe, it, expect, vi } from "vitest";
import { render, waitFor } from "@testing-library/svelte";
import VaultPanel from "./VaultPanel.svelte";

// Regression guard for P1: the Records table's file cell must render a CLICKABLE
// link (button.filelink) — not plain muted text — for a real record whose `file`
// alias is present. This broke when the cell gated the link on a strict
// fileFor()/info.files match: any alias-set mismatch dropped every row to text.

interface FetchStub {
  vault: unknown;
  transactions: unknown;
  tags?: unknown;
  folders?: unknown;
}

// Route the component's onMount fetches to fixtures; anything else 404s so an
// unexpected call is visible rather than hanging.
function stubFetch(f: FetchStub) {
  const json = (body: unknown) =>
    Promise.resolve({ ok: true, json: () => Promise.resolve(body) } as Response);
  vi.stubGlobal(
    "fetch",
    vi.fn((input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/api/vault")) return json(f.vault);
      if (url.includes("/api/transactions")) return json(f.transactions);
      if (url.includes("/api/tags")) return json(f.tags ?? { tags: [] });
      if (url.includes("/api/index/folders")) return json(f.folders ?? { folders: [] });
      return Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({}) } as Response);
    }),
  );
}

const VAULT = {
  vaultDir: "/v",
  sourceDir: "/v",
  dirMismatch: false,
  configDir: "/c",
  indexed: true,
  embeddingDim: 1024,
  fileCount: 1,
  indexedFileCount: 1,
  chunkCount: 10,
  dbSizeBytes: 1000,
  files: [{ alias: "file_0", name: "statement.pdf", kind: "pdf", sizeBytes: 2048, chunks: 10 }],
};

const TXNS = {
  transactions: [
    {
      file: "file_0",
      date: "4/03",
      year: 2026,
      amount: 85.0,
      direction: "debit",
      desc: "VERIZON WIRELESS PMT",
      merchant: "VERIZON WIRELESS",
      country: "USA",
      state: "GA",
      tags: ["phone"],
    },
  ],
};

describe("VaultPanel Records file cell (P1 regression)", () => {
  it("renders a clickable file link for a record whose alias matches info.files", async () => {
    stubFetch({ vault: VAULT, transactions: TXNS });
    const { container } = render(VaultPanel, { props: { initialSub: "records" } });

    // The link resolves to the real filename once info + txns have loaded.
    await waitFor(() => {
      const link = container.querySelector("button.filelink");
      expect(link).not.toBeNull();
    });
    const link = container.querySelector("button.filelink") as HTMLButtonElement;
    expect(link.textContent).toContain("statement.pdf");
    // It must be an actual control, not the muted plain-text fallback.
    expect(container.querySelector("td.rfile .srcname")).toBeNull();
  });

  it("still renders a link (not plain text) when the txn alias is NOT in info.files", async () => {
    // Alias mismatch (the real-world regression cause): info.files has no `file_9`.
    const mismatched = {
      transactions: [{ ...TXNS.transactions[0], file: "file_9" }],
    };
    stubFetch({ vault: VAULT, transactions: mismatched });
    const { container } = render(VaultPanel, { props: { initialSub: "records" } });

    await waitFor(() => {
      expect(container.querySelector("table.records")).not.toBeNull();
    });
    // Resilient: a plausible alias still gets a link rather than silently dropping
    // to muted text (openHit resolves it once/if the alias lines up).
    await waitFor(() => {
      expect(container.querySelector("button.filelink")).not.toBeNull();
    });
    expect(container.querySelector("td.rfile .srcname")).toBeNull();
  });

  it("renders merchant and State · Country in one desc cell (P2 compact line)", async () => {
    stubFetch({ vault: VAULT, transactions: TXNS });
    const { container } = render(VaultPanel, { props: { initialSub: "records" } });

    await waitFor(() => {
      expect(container.querySelector("td.desc .merchant")).not.toBeNull();
    });
    const desc = container.querySelector("td.desc") as HTMLElement;
    const merchant = desc.querySelector(".merchant") as HTMLElement;
    const loc = desc.querySelector(".loc") as HTMLElement;
    // Both live in the SAME cell (one line), not stacked in separate rows/cells.
    expect(merchant.textContent).toContain("VERIZON WIRELESS");
    expect(loc).not.toBeNull();
    expect(loc.textContent).toContain("GA · USA");
    // The full raw descriptor stays available on hover.
    expect(merchant.getAttribute("title")).toBe("VERIZON WIRELESS PMT");
  });

  it("truncates a long merchant-less descriptor without dropping amount/tags (P1 overflow)", async () => {
    // A transfer/PayPal-style row with NO parsed merchant → falls back to the full
    // raw desc. Under the fixed table layout the .merchant span (nowrap + ellipsis)
    // clips instead of widening the table and pushing amount/tags off-screen.
    const longDesc =
      "PAYPAL TRANSFER *ONLINE PAYMENT REF 998877665544 ACH DEBIT WEB INITIATED — VERY LONG DESCRIPTOR THAT WOULD OVERFLOW";
    const wide = {
      transactions: [
        {
          file: "file_0",
          date: "4/05",
          year: 2026,
          amount: 42.5,
          direction: "debit",
          desc: longDesc,
          merchant: "",
          country: "",
          state: "",
          tags: ["transfers"],
        },
      ],
    };
    stubFetch({ vault: VAULT, transactions: wide });
    const { container } = render(VaultPanel, { props: { initialSub: "records" } });

    await waitFor(() => {
      expect(container.querySelector("td.desc .merchant")).not.toBeNull();
    });
    const merchant = container.querySelector("td.desc .merchant") as HTMLElement;
    // Full descriptor lands in the truncating span (clipped by CSS, full text on hover).
    expect(merchant.textContent).toContain("PAYPAL TRANSFER");
    expect(merchant.getAttribute("title")).toBe(longDesc);
    // Amount + tags still render in the same row — not shoved off by the wide desc.
    expect(container.querySelector("td.amt")?.textContent).toContain("42.50");
    expect(container.querySelector("td.tags .tagchip")?.textContent).toContain("transfers");
    // The fixed-layout table constrains columns.
    const table = container.querySelector("table.records") as HTMLTableElement;
    expect(table.querySelector("colgroup col.c-desc")).not.toBeNull();
  });
});

describe("Records desc-cell layout contract (P1 mobile regression)", () => {
  // jsdom computes no layout, so the phone bug — .merchant flex-shrinking to
  // ZERO width while the fixed .loc ("City, ST · CCC") kept the whole cell —
  // was invisible to every DOM assertion above. Pin the CSS contract itself
  // (the repo's lint-the-shape pattern): the LOCATION must be the shrinkable,
  // truncatable element, and the MERCHANT must reserve a readable minimum.
  // If a restyle changes this on purpose, update the rationale comment in
  // VaultPanel.svelte alongside this test.
  // vitest cwd = app/web (the vite root), so resolve from there.
  const src = readFileSync("src/lib/components/VaultPanel.svelte", "utf-8");
  const rule = (sel: string) =>
    src.split(sel)[1]?.split("}")[0] ?? "";

  it("the merchant keeps a readable minimum and may grow", () => {
    const merchant = rule(".records .descrow .merchant {");
    expect(merchant).toMatch(/flex:\s*1 1 auto/);
    expect(merchant).toMatch(/min-width:\s*\d+ch/);
  });

  it("the location yields first: shrinkable + ellipsized, never flex:none", () => {
    const loc = rule(".records .descrow .loc {");
    expect(loc).toMatch(/flex:\s*0 1 auto/);
    expect(loc).toMatch(/text-overflow:\s*ellipsis/);
    expect(loc).not.toMatch(/flex:\s*none/);
  });
});

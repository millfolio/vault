import { describe, it, expect, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/svelte";
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
});

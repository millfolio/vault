import { describe, it, expect, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/svelte";
import OperationsPanel from "./OperationsPanel.svelte";

// Route the panel's onMount fetches (/api/operations history + /api/index/status
// poll) to fixtures. `indexStatus` drives the live running-index row.
function stubFetch(opts: { operations?: unknown; indexStatus?: unknown; hangHistory?: boolean }) {
  const json = (body: unknown) =>
    Promise.resolve({ ok: true, json: () => Promise.resolve(body) } as Response);
  vi.stubGlobal(
    "fetch",
    vi.fn((input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/api/index/status")) return json(opts.indexStatus ?? { state: "idle", detail: "" });
      if (url.includes("/api/operations")) {
        if (opts.hangHistory) return new Promise(() => {}); // never resolves → tests the timeout path
        return json({ operations: opts.operations ?? [] });
      }
      return Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({}) } as Response);
    }),
  );
}

describe("OperationsPanel", () => {
  it("shows the running index row with 'n of M files' (P5/P6)", async () => {
    stubFetch({ indexStatus: { state: "indexing", detail: "embedding", current: 3, total: 6 } });
    const { container } = render(OperationsPanel);

    await waitFor(() => {
      expect(container.querySelector(".op.live")).not.toBeNull();
    });
    expect(screen.getByText("3 of 6 files")).toBeInTheDocument();
  });

  it("renders history rows with a duration and label", async () => {
    stubFetch({
      operations: [
        { type: "reindex", started: 1783100000, finished: 1783100126, status: "done", detail: "done", files: 6, txns: 444 },
      ],
    });
    render(OperationsPanel);
    await waitFor(() => {
      expect(screen.getByText("Re-index")).toBeInTheDocument();
    });
    // 126s → "2m 06s" via fmtDur.
    expect(screen.getByText("2m 06s")).toBeInTheDocument();
    expect(screen.getByText("444 txns")).toBeInTheDocument();
  });

  it("shows the running row immediately even while the history fetch hangs (P5)", async () => {
    stubFetch({ hangHistory: true, indexStatus: { state: "indexing", detail: "", current: 1, total: 4 } });
    const { container } = render(OperationsPanel);

    // The live row must appear without waiting on the (hung) history request.
    await waitFor(() => {
      expect(container.querySelector(".op.live")).not.toBeNull();
    });
    expect(screen.getByText("1 of 4 files")).toBeInTheDocument();
    // The history area shows the small loading line, not a crash.
    expect(container.querySelector(".loadingrow")).not.toBeNull();
  });
});

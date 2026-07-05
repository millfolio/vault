import { describe, it, expect, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/svelte";
import OperationsPanel from "./OperationsPanel.svelte";

// Route the merged panel's fetches to fixtures. It polls several endpoints on mount —
// /api/operations (history), /api/index/status (running index), /api/orchestrator/queue
// (the queue behind it), /api/backfill/status (Controls + Backfill detail), /api/gpu
// (System stats) and /api/model. Anything not stubbed 404s and its section just hides.
function stubFetch(opts: {
  operations?: unknown;
  indexStatus?: unknown;
  queue?: unknown;
  backfill?: unknown;
  gpu?: unknown;
  hangHistory?: boolean;
}) {
  const json = (body: unknown) =>
    Promise.resolve({ ok: true, json: () => Promise.resolve(body) } as Response);
  vi.stubGlobal(
    "fetch",
    vi.fn((input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/api/index/status")) return json(opts.indexStatus ?? { state: "idle", detail: "" });
      if (url.includes("/api/orchestrator/queue")) return json(opts.queue ?? { items: [] });
      if (url.includes("/api/backfill/status")) {
        if (opts.backfill) return json(opts.backfill);
        return Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({}) } as Response);
      }
      if (url.includes("/api/gpu")) {
        if (opts.gpu) return json(opts.gpu);
        return Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({}) } as Response);
      }
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

  it("surfaces a failed job in History with its pid + reason", async () => {
    stubFetch({
      operations: [
        { type: "index", started: 1783000000, finished: 1783000040, status: "error", detail: "worker exited (no manifest)", pid: 41821 },
      ],
    });
    render(OperationsPanel);
    await waitFor(() => {
      expect(screen.getByText("✗ failed")).toBeInTheDocument();
    });
    expect(screen.getByText("pid 41821")).toBeInTheDocument();
    expect(screen.getByText("worker exited (no manifest)")).toBeInTheDocument();
  });

  it("shows the queue behind the running job (N files queued + next items)", async () => {
    stubFetch({
      indexStatus: { state: "indexing", detail: "embedding", current: 1, total: 3 },
      queue: {
        items: [
          { id: 1, kind: "index", payload: "a.csv", prio: 10, state: "running", startedTs: 1783000000 },
          { id: 2, kind: "index", payload: "b.pdf", prio: 10, state: "pending", startedTs: 0 },
          { id: 3, kind: "index", payload: "c.pdf", prio: 10, state: "pending", startedTs: 0 },
        ],
      },
    });
    render(OperationsPanel);
    await waitFor(() => {
      expect(screen.getByText("2 files queued")).toBeInTheDocument();
    });
    expect(screen.getByText("b.pdf")).toBeInTheDocument();
  });

  it("renders the global Controls (Pause + Priority) from backfill status", async () => {
    stubFetch({
      backfill: { status: "idle", paused_until: 0, priority: "high", perTag: [], pendingTotal: 0 },
    });
    render(OperationsPanel);
    // Pause control is present immediately; the active priority reflects the server's
    // "high" once /api/backfill/status resolves (hence waitFor, not a sync assert).
    expect(await screen.findByText("Pause for 1 hr")).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "high" })).toHaveClass("active");
    });
  });
});

import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import OperationsView from "./OperationsView.svelte";

// OperationsView is a thin wrapper: a SubTabs bar (Operations | Stats | Logs) over the
// three panels. Its children each poll the local server, so stub every endpoint they
// touch — the point of these tests is the sub-tab switching, not the panels' internals.
function stubFetch() {
  const json = (body: unknown) =>
    Promise.resolve({ ok: true, json: () => Promise.resolve(body) } as Response);
  vi.stubGlobal(
    "fetch",
    vi.fn((input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/api/index/status")) return json({ state: "idle", detail: "" });
      if (url.includes("/api/orchestrator/queue")) return json({ items: [] });
      if (url.includes("/api/backfill/status"))
        return json({ status: "idle", paused_until: 0, priority: "medium", perTag: [], pendingTotal: 0 });
      if (url.includes("/api/gpu")) return json({ util: 12, mem: 40, disk: 55 });
      if (url.includes("/api/operations")) return json({ operations: [] });
      if (url.includes("/api/model")) return json({ model: "Qwen2.5-3B" });
      if (url.includes("/api/stats")) return json({ N: 0, categories: [] });
      // LogsPanel — where the data + logs live on disk.
      if (url.includes("/api/system"))
        return json({
          dataDir: "/Users/x/Library/Application Support/Millfolio/data",
          asksFile: "/Users/x/Library/Application Support/Millfolio/data/asks.jsonl",
          statsFile: "/Users/x/Library/Application Support/Millfolio/data/stats.jsonl",
          categoriesFile: "/Users/x/Library/Application Support/Millfolio/data/categories.txt",
          logs: {
            transcripts: "/Users/x/Library/Application Support/Millfolio/transcripts",
            app: "/Users/x/Library/Application Support/Millfolio/Millfolio.log",
            server: "/Users/x/Library/Application Support/Millfolio/engine.log",
          },
        });
      return Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({}) } as Response);
    }),
  );
}

describe("OperationsView", () => {
  beforeEach(() => stubFetch());

  it("renders the three sub-tabs, Operations active by default", () => {
    render(OperationsView, { props: { demo: false } });
    expect(screen.getByRole("tab", { name: "Operations" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("tab", { name: "Stats" })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "Logs" })).toBeInTheDocument();
    // Operations panel content is showing (the "Now" section header).
    expect(screen.getByText("Now")).toBeInTheDocument();
  });

  it("restores the on-disk data + log locations under the Logs sub-tab", async () => {
    render(OperationsView, { props: { demo: false } });
    await fireEvent.click(screen.getByRole("tab", { name: "Logs" }));
    // The data + log location rows are back.
    await waitFor(() => {
      expect(screen.getByText("Data directory")).toBeInTheDocument();
    });
    expect(screen.getByText("Per-ask transcripts")).toBeInTheDocument();
    expect(screen.getByText("App / server log")).toBeInTheDocument();
    expect(
      screen.getByText("/Users/x/Library/Application Support/Millfolio/data"),
    ).toBeInTheDocument();
  });

  it("opens directly onto the Logs sub-tab when initialSub=logs", async () => {
    render(OperationsView, { props: { demo: false, initialSub: "logs" } });
    expect(screen.getByRole("tab", { name: "Logs" })).toHaveAttribute("aria-selected", "true");
    await waitFor(() => {
      expect(screen.getByText("Data directory")).toBeInTheDocument();
    });
  });

  it("opens directly onto the Stats sub-tab when initialSub=stats", () => {
    render(OperationsView, { props: { demo: false, initialSub: "stats" } });
    expect(screen.getByRole("tab", { name: "Stats" })).toHaveAttribute("aria-selected", "true");
  });
});

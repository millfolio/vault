import { describe, it, expect, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/svelte";
import OperationsPanel from "./OperationsPanel.svelte";

// The Operations → Frontier-model block: shows whether an Anthropic API key is set
// and, when one is stored in-app, a masked "…last4" hint (never the full key).

function stubFetch(apikey: unknown) {
  const json = (body: unknown) =>
    Promise.resolve({ ok: true, json: () => Promise.resolve(body) } as Response);
  vi.stubGlobal(
    "fetch",
    vi.fn((input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/api/settings/apikey")) return json(apikey);
      if (url.includes("/api/index/status")) return json({ state: "idle", detail: "" });
      if (url.includes("/api/scheduler/queue")) return json({ items: [] });
      if (url.includes("/api/backfill/status"))
        return json({ status: "idle", paused_until: 0, priority: "medium", perTag: [], pendingTotal: 0 });
      if (url.includes("/api/gpu")) return json({ util: 12, mem: 40, disk: 55 });
      if (url.includes("/api/operations")) return json({ operations: [] });
      if (url.includes("/api/model")) return json({ model: "Qwen2.5-3B" });
      return Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({}) } as Response);
    }),
  );
}

describe("OperationsPanel — Frontier-model key", () => {
  it("shows the masked hint when a key is set", async () => {
    stubFetch({ set: true, hint: "…XY99" });
    render(OperationsPanel, { demo: false });
    await waitFor(() =>
      expect(screen.getByText(/Key is set/i)).toBeInTheDocument(),
    );
    expect(screen.getByText("…XY99")).toBeInTheDocument();
    // The block never renders a full key — only the masked hint + a password input.
    const input = screen.getByPlaceholderText("sk-ant-…") as HTMLInputElement;
    expect(input.type).toBe("password");
    expect(input.value).toBe("");
  });

  it("shows the unset state when no key is stored", async () => {
    stubFetch({ set: false, hint: "" });
    render(OperationsPanel, { demo: false });
    await waitFor(() =>
      expect(screen.getByText(/No key set/i)).toBeInTheDocument(),
    );
  });
});

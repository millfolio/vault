import { describe, it, expect, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/svelte";
import LogsPanel from "./LogsPanel.svelte";

// Operations → Logs hosts the persistent, always-available Disclaimer (the
// "what/where/legal" info). It must be reachable even after the first-run notice
// is dismissed, and regardless of whether /api/system loaded.

function stubSystem(ok: boolean) {
  vi.stubGlobal(
    "fetch",
    vi.fn((input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/api/system")) {
        return ok
          ? Promise.resolve({
              ok: true,
              json: () => Promise.resolve({ dataDir: "/Users/x/data" }),
            } as Response)
          : Promise.resolve({ ok: false, status: 500 } as Response);
      }
      return Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({}) } as Response);
    }),
  );
}

describe("LogsPanel — persistent Disclaimer", () => {
  it("renders a Disclaimer link to the website page", async () => {
    stubSystem(true);
    render(LogsPanel, { demo: false });

    const link = await screen.findByRole("link", { name: /millfolio\.app\/disclaimer/i });
    expect(link).toHaveAttribute("href", "https://millfolio.app/disclaimer");
    // The inline full text is available too (behind a <summary>).
    expect(screen.getByText("Disclaimer")).toBeInTheDocument();
    expect(screen.getByText("Before you start")).toBeInTheDocument();
  });

  it("shows the Disclaimer even when system info fails to load", async () => {
    stubSystem(false);
    render(LogsPanel, { demo: false });
    await waitFor(() =>
      expect(
        screen.getByRole("link", { name: /millfolio\.app\/disclaimer/i }),
      ).toBeInTheDocument(),
    );
  });
});

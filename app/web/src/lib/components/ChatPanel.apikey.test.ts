import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import ChatPanel from "./ChatPanel.svelte";

// The missing-key affordance: when codegen errors with the no-key message
// (orchestrator _NO_REMOTE_MSG, "…set ANTHROPIC_API_KEY and retry"), the chat
// surfaces an inline API-key field so a stuck native-app user can fix it right
// there. Real product only — never in the demo (its own key handling).

const NO_KEY_ERROR =
  "Error: This question needs the frontier model to write its program, but no " +
  "remote budget is available — set ANTHROPIC_API_KEY and retry.";

function noop() {}

function stubFetch(post: (body: unknown) => Promise<Response>) {
  const json = (body: unknown) =>
    Promise.resolve({ ok: true, json: () => Promise.resolve(body) } as Response);
  vi.stubGlobal(
    "fetch",
    vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.includes("/api/history")) return json({ records: [] });
      if (url.includes("/api/settings/apikey") && init?.method === "POST")
        return post(init.body);
      return Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({}) } as Response);
    }),
  );
}

const errorItem = {
  kind: "assistant" as const,
  id: "e1",
  text: NO_KEY_ERROR,
};

describe("ChatPanel — missing-key affordance", () => {
  it("shows the key field on the no-key error and POSTs the pasted key", async () => {
    const posted: unknown[] = [];
    stubFetch((body) => {
      posted.push(body);
      return Promise.resolve({
        ok: true,
        json: () => Promise.resolve({ set: true, hint: "…XY99" }),
      } as Response);
    });

    render(ChatPanel, {
      items: [errorItem],
      busy: false,
      demo: false,
      onsend: noop,
      onrun: noop,
      onapprove: noop,
      onreject: noop,
    });

    // The affordance is offered.
    expect(
      screen.getByText(/Add your Anthropic API key/i),
    ).toBeInTheDocument();

    const input = screen.getByPlaceholderText("sk-ant-…") as HTMLInputElement;
    await fireEvent.input(input, { target: { value: "sk-ant-api03-testkey123" } });
    await fireEvent.click(screen.getByText("Save key"));

    await waitFor(() =>
      expect(screen.getByText(/Key saved/i)).toBeInTheDocument(),
    );
    expect(posted).toHaveLength(1);
    expect(JSON.parse(posted[0] as string).key).toBe("sk-ant-api03-testkey123");
  });

  it("does NOT show the affordance in the demo", async () => {
    stubFetch(() =>
      Promise.resolve({ ok: true, json: () => Promise.resolve({}) } as Response),
    );
    render(ChatPanel, {
      items: [errorItem],
      busy: false,
      demo: true,
      onsend: noop,
      onrun: noop,
      onapprove: noop,
      onreject: noop,
    });
    expect(screen.queryByText(/Add your Anthropic API key/i)).toBeNull();
  });
});

import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import DisclaimerNotice from "./DisclaimerNotice.svelte";

// The first-run liability/privacy notice: shown once (localStorage flag), an
// "I understand" button dismisses it and remembers the dismissal.
const ACK_KEY = "millfolio.disclaimerAck";

// This jsdom config doesn't ship a real localStorage — install a minimal
// in-memory stand-in so the component's read/write path is exercised for real.
function fakeStorage(): Storage {
  const m = new Map<string, string>();
  return {
    getItem: (k: string) => (m.has(k) ? m.get(k)! : null),
    setItem: (k: string, v: string) => void m.set(k, String(v)),
    removeItem: (k: string) => void m.delete(k),
    clear: () => m.clear(),
    key: (i: number) => Array.from(m.keys())[i] ?? null,
    get length() {
      return m.size;
    },
  } as Storage;
}

describe("DisclaimerNotice — first-run notice", () => {
  beforeEach(() => {
    vi.stubGlobal("localStorage", fakeStorage());
  });

  it("shows the full disclaimer on first load", async () => {
    render(DisclaimerNotice);
    await waitFor(() =>
      expect(screen.getByRole("dialog")).toBeInTheDocument(),
    );
    expect(screen.getByText("Before you start")).toBeInTheDocument();
    // The three load-bearing points are present.
    expect(
      screen.getByText(/Privacy is protected by design, but not guaranteed\./),
    ).toBeInTheDocument();
    expect(screen.getByText(/Answers can be wrong\./)).toBeInTheDocument();
    expect(screen.getByText(/You use it at your own risk\./)).toBeInTheDocument();
  });

  it("dismiss sets the flag and hides the notice", async () => {
    render(DisclaimerNotice);
    await waitFor(() => expect(screen.getByRole("dialog")).toBeInTheDocument());

    await fireEvent.click(screen.getByRole("button", { name: /I understand/i }));

    await waitFor(() =>
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument(),
    );
    expect(localStorage.getItem(ACK_KEY)).toBe("1");
  });

  it("stays hidden once acknowledged", async () => {
    localStorage.setItem(ACK_KEY, "1");
    render(DisclaimerNotice);
    // onMount runs synchronously enough that the dialog should never appear.
    await waitFor(() =>
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument(),
    );
  });
});

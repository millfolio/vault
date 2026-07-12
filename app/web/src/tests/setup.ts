import "@testing-library/jest-dom/vitest";
import { afterEach, vi } from "vitest";
import { cleanup } from "@testing-library/svelte";

// Every test runs offline: no test may touch the network. Default `fetch` to a
// reject so an unmocked call fails loudly instead of hanging; individual tests
// install their own `vi.stubGlobal("fetch", …)` where a response is needed.
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

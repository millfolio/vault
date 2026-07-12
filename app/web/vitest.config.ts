import { sveltekit } from "@sveltejs/kit/vite";
import { svelteTesting } from "@testing-library/svelte/vite";
import { defineConfig } from "vitest/config";

// Component + unit tests run headless in jsdom (no network, no live server). The
// SvelteKit plugin gives us `$lib`/`$app` resolution + Svelte 5 compilation; the
// build-version define is stubbed so modules that read __APP_VERSION__ compile.
export default defineConfig({
  plugins: [sveltekit(), svelteTesting()],
  define: {
    __APP_VERSION__: JSON.stringify("test"),
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/tests/setup.ts"],
    include: ["src/**/*.{test,spec}.{js,ts}"],
  },
});

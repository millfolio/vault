import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vite";
import { execSync } from "node:child_process";

// Build stamp shown in the UI corner — the app submodule's short SHA + build date,
// so you can tell which build is live. Falls back to "dev" when git isn't available.
function buildVersion(): string {
  let sha = "dev";
  try {
    sha = execSync("git rev-parse --short HEAD", { stdio: ["ignore", "pipe", "ignore"] })
      .toString()
      .trim();
  } catch {
    /* no git (e.g. built from a tarball) */
  }
  return `${sha} · ${new Date().toISOString().slice(0, 10)}`;
}

export default defineConfig({
  define: {
    __APP_VERSION__: JSON.stringify(buildVersion()),
  },
  plugins: [sveltekit()],
});

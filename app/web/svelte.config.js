import adapter from "@sveltejs/adapter-static";
import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    // The web app ships as a static SPA: served by the Mojo `server/` as static
    // assets, or deployed to a CDN. `fallback` makes client-side routing work.
    adapter: adapter({ fallback: "index.html", strict: false }),
  },
};

export default config;

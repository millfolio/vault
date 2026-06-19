import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// privacy_box-web. In production the privacy_box server (:10000) serves this built app
// AND the API from one origin. In dev, proxy the API routes to that server so the
// app can use same-origin relative paths (/chat, /health) in both modes.
const API = process.env.VITE_PRIVACY_BOX_API ?? "http://localhost:10000";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/chat": API,
      "/health": API,
    },
  },
});

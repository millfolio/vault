import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// enclave-web. In production the enclave server (:10000) serves this built app
// AND the API from one origin. In dev, proxy the API routes to that server so the
// app can use same-origin relative paths (/chat, /health) in both modes.
const API = process.env.VITE_ENCLAVE_API ?? "http://localhost:10000";

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

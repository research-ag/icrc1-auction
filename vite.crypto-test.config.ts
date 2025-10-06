/// <reference types="vitest" />
import { defineConfig } from "vite";
import environment from "vite-plugin-environment";
import tsconfigPaths from "vite-tsconfig-paths";
import react from "@vitejs/plugin-react";
import dotenv from "dotenv";

dotenv.config();

export default defineConfig({
  root: "frontend/crypto-test",
  build: {
    outDir: "../../dist/crypto-test",
    emptyOutDir: true,
  },
  optimizeDeps: {
    esbuildOptions: {
      define: {
        global: "globalThis",
      },
    },
  },
  define: {
    "process.env.DFX_NETWORK": "\"ic\"",
  },
  server: {
    fs: {
      // allow importing declarations from outside this root
      allow: ["..", "../..", "../../.."],
    },
    proxy: {
      "/api": {
        target: "http://127.0.0.1:4943",
        changeOrigin: true,
      },
    },
  },
  plugins: [
    react(),
    tsconfigPaths(),
    environment("all", { prefix: "CANISTER_" }),
    environment("all", { prefix: "DFX_" }),
  ],
});

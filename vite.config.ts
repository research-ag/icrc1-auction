/// <reference types="vitest" />
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';
import { icpBindgen } from '@icp-sdk/bindgen/plugins/vite';
import tsconfigPaths from 'vite-tsconfig-paths';
import dotenv from 'dotenv';

dotenv.config();

export default defineConfig({
  root: 'frontend',
  build: {
    outDir: '../dist',
    emptyOutDir: true,
  },
  optimizeDeps: {
    esbuildOptions: {
      define: {
        global: 'globalThis',
      },
    },
  },
  server: {
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:8000',
        changeOrigin: true,
      },
    },
  },
  plugins: [
    react(),
    tsconfigPaths(),
    icpBindgen({
      didFile: 'did/icrc1_auction.did',
      outDir: 'frontend/src/bindings',
    }),
    icpBindgen({
      didFile: '.mops/.build/icrc1_ledger_mock.did',
      outDir: 'frontend/src/bindings',
    }),
    icpBindgen({
      didFile: 'crypto_canister/crypto.did',
      outDir: 'frontend/src/bindings',
    }),
  ],
});

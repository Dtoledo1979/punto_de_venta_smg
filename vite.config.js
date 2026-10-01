import { defineConfig } from "vite";
import { resolve } from "node:path";

// Sitio multi-página: cada .html de la raíz es una pantalla del POS.
const pages = ["index", "login", "onboarding", "pos-productos", "pos-tickets", "despacho", "insumos", "dashboard", "locales", "equipo", "ajustes"];

export default defineConfig({
  build: {
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      input: Object.fromEntries(pages.map((p) => [p, resolve(import.meta.dirname, `${p}.html`)])),
    },
  },
  server: { port: 3000, strictPort: true },
  preview: { port: 3000, strictPort: true },
});

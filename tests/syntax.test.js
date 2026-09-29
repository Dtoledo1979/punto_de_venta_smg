// Cada <script> en línea de cada pantalla y cada script compartido tiene
// que compilar. (Un error de sintaxis en un script clásico deja la pantalla
// entera sin funcionar, sin que el build lo detecte.)
import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(import.meta.dirname, "..");
const pages = readdirSync(ROOT).filter((f) => f.endsWith(".html"));
const shared = readdirSync(join(ROOT, "public/js")).filter((f) => f.endsWith(".js"));

describe("sintaxis", () => {
  for (const page of pages) {
    it(page, () => {
      const html = readFileSync(join(ROOT, page), "utf8");
      const blocks = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
      expect(blocks.length).toBeGreaterThan(0);
      for (const code of blocks) expect(() => new Function(code)).not.toThrow();
    });
  }
  for (const file of shared) {
    it("public/js/" + file, () => {
      expect(() => new Function(readFileSync(join(ROOT, "public/js", file), "utf8"))).not.toThrow();
    });
  }
});

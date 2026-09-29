// Extrae de las pantallas todos los textos que pasan por la traducción:
//   t("…"), showError("…", …), buildCopy("…"), r("…")    (JavaScript)
//   <x data-i18n>…</x>, placeholder="…" data-i18n-ph, <title>  (HTML)
// y los textos fijos de i18n.js (nombres de códigos y errores).
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(import.meta.dirname, "..");
export const PAGES = readdirSync(ROOT).filter((f) => f.endsWith(".html")).map((f) => join(ROOT, f));
export const SCRIPTS = ["pos-core.js", "pos-refunds.js", "pos-sessions.js"].map((f) => join(ROOT, "public/js", f));

const unescapeJs = (s, q) => (q === '"' ? JSON.parse('"' + s + '"') : JSON.parse('"' + s.replace(/\\'/g, "'").replace(/"/g, '\\"') + '"'));

export function extractFromSource(src) {
  const found = new Set();
  // Llamadas cuyo primer argumento es un texto a traducir.
  const callRe = /\b(?:t|T|showError|buildCopy|r|core\.t|fail)\(\s*(["'])((?:\\.|(?!\1)[^\\])*)\1/g;
  for (const m of src.matchAll(callRe)) found.add(unescapeJs(m[2], m[1]));
  // Ternarios dentro de t(...): t(cond ? "a" : "b") no se usan; se exigen literales directos.
  const htmlRe = /<([a-zA-Z0-9]+)\b[^>]*\sdata-i18n(?=[\s>=])[^>]*>([\s\S]*?)<\/\1>/g;
  for (const m of src.matchAll(htmlRe)) found.add(m[2].trim());
  const phRe = /<[a-z]+\b(?=[^>]*\sdata-i18n-ph\b)[^>]*\splaceholder="([^"]*)"[^>]*>/g;
  for (const m of src.matchAll(phRe)) found.add(m[1]);
  const title = src.match(/<title>([^<]*)<\/title>/);
  if (title) found.add(title[1]);
  found.delete("");
  return found;
}

export function allKeys() {
  const keys = new Set();
  for (const f of [...PAGES, ...SCRIPTS]) for (const k of extractFromSource(readFileSync(f, "utf8"))) keys.add(k);
  return keys;
}

// Texto en español que quedó FUERA del sistema de traducción: literales de
// JS o texto visible del HTML con caracteres propios del español. Se ignoran
// los comentarios (el equipo comenta el código en español a propósito).
export function spanishLeftovers(src, file) {
  const out = [];
  const noComments = src
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n").map((l) => l.replace(/(^|[^:"'])\/\/.*$/, "$1")).join("\n");
  const lines = noComments.split("\n");
  const spanish = /[áéíóúñ¿¡]|\b(?:el|la|los|las|del|para|con|por|una|caja|pedido|evento|cobrar|entrega|insumo)\b/i;
  lines.forEach((line, i) => {
    // Texto marcado explícitamente como español (ej. el nombre del idioma
    // en su propio idioma dentro de un selector): es intencional.
    if (/\slang="es"/.test(line)) return;
    // Literales de JS en la línea
    for (const m of line.matchAll(/(["'`])((?:\\.|(?!\1)[^\\])*)\1/g)) {
      const s = m[2];
      if (/^[a-z_]+$/.test(s) || /^pos_/.test(s)) continue; // códigos / claves de storage
      if (/[áéíóúñ¿¡]/i.test(s)) out.push(`${file}:${i + 1}: ${s.slice(0, 80)}`);
    }
    // Texto visible del HTML (entre etiquetas)
    for (const m of line.matchAll(/>([^<>{}]+)</g)) {
      const s = m[1].trim();
      if (s && spanish.test(s) && /[a-zA-Z]{3,}/.test(s) && !/[=;(){}]/.test(s)) out.push(`${file}:${i + 1}: ${s.slice(0, 80)}`);
    }
  });
  return out;
}

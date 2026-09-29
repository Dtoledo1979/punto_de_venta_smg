// Uso: node tests/print-missing.mjs  → lista los textos sin traducción al español.
import { allKeys } from "./i18n-extract.js";
globalThis.document = { documentElement: { dataset: {} } };
await import("../public/js/i18n.js");
await import("../public/js/i18n-es.js");
const i = globalThis.posI18n, es = i.dictionaries.es;
const fixed = [...Object.values(i.LABELS).flatMap((g) => Object.values(g)), ...Object.values(i.ERRORS)];
const missing = [...new Set([...allKeys(), ...fixed])].filter((k) => !(k in es)).sort();
console.log(JSON.stringify(missing, null, 1));

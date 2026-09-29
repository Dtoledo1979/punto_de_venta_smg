import { describe, it, expect, beforeAll } from "vitest";
import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { allKeys, PAGES, spanishLeftovers } from "./i18n-extract.js";

let i18n;
beforeAll(async () => {
  globalThis.document = { documentElement: { dataset: {} } };
  await import("../public/js/i18n.js");
  await import("../public/js/i18n-es.js");
  i18n = globalThis.posI18n;
});

describe("traducciones", () => {
  it("todo texto de las pantallas tiene su versión en español", () => {
    const es = i18n.dictionaries.es;
    const missing = [...allKeys()].filter((k) => !(k in es));
    expect(missing, "Faltan en public/js/i18n-es.js:\n" + missing.join("\n")).toEqual([]);
  });

  it("los nombres de códigos y los errores del servidor también", () => {
    const es = i18n.dictionaries.es;
    const fixed = [
      ...Object.values(i18n.LABELS).flatMap((group) => Object.values(group)),
      ...Object.values(i18n.ERRORS),
      "No connection to the server. Check your internet.", "Something went wrong.",
    ];
    const missing = fixed.filter((k) => !(k in es));
    expect(missing, "Faltan en i18n-es.js:\n" + missing.join("\n")).toEqual([]);
  });

  it("las traducciones conservan los mismos {parámetros}", () => {
    const es = i18n.dictionaries.es;
    const params = (s) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(",");
    const bad = Object.entries(es).filter(([en, tr]) => params(en) !== params(tr)).map(([en]) => en);
    expect(bad).toEqual([]);
  });

  it("el diccionario no tiene claves duplicadas (la segunda pisaría a la primera)", () => {
    const src = readFileSync(new URL("../public/js/i18n-es.js", import.meta.url), "utf8");
    const keys = [...src.matchAll(/^\s*("(?:[^"\\]|\\.)*")\s*:/gm)].map((m) => JSON.parse(m[1]));
    const seen = new Set();
    const dup = keys.filter((k) => (seen.has(k) ? true : (seen.add(k), false)));
    expect(dup).toEqual([]);
    expect(keys.length).toBe(Object.keys(i18n.dictionaries.es).length);
  });

  it("no queda texto en español fuera del sistema de traducción", () => {
    const leftovers = PAGES.flatMap((f) => spanishLeftovers(readFileSync(f, "utf8"), basename(f)));
    expect(leftovers, leftovers.join("\n")).toEqual([]);
  });
});

describe("motor de traducción", () => {
  it("interpola parámetros y cae al inglés si falta la traducción", () => {
    i18n.setLang("es");
    expect(i18n.t("Order #{n} sent to delivery.", { n: 7 })).toBe("Pedido #7 enviado a Entrega.");
    expect(i18n.t("Text that does not exist")).toBe("Text that does not exist");
    expect(i18n.t("Total", null, "en")).toBe("Total");
    i18n.setLang("en");
    expect(i18n.t("Order #{n} sent to delivery.", { n: 7 })).toBe("Order #7 sent to delivery.");
  });

  it("traduce errores del servidor por código con sus datos", () => {
    i18n.setLang("es");
    const err = { message: "payment.total_mismatch", details: '{"paid": 13.49, "total": 13.5}' };
    expect(i18n.errorText(err, (k, v) => "$" + Number(v).toFixed(2))).toBe("Efectivo + tarjeta ($13.49) no coincide con el total ($13.50).");
    expect(i18n.errorText({ message: "algo raro" })).toBe("algo raro");
    i18n.setLang("en");
    expect(i18n.errorText({ message: "pin.incorrect" })).toMatch(/^Incorrect PIN/);
  });

  it("los códigos de la base tienen nombre en los dos idiomas", () => {
    expect(i18n.label("payment", "split", "en")).toBe("Split");
    expect(i18n.label("payment", "split", "es")).toBe("Mixto");
    expect(i18n.label("status", "voided", "es")).toBe("Anulado");
    expect(i18n.label("status", "codigo_desconocido")).toBe("codigo_desconocido");
  });
});

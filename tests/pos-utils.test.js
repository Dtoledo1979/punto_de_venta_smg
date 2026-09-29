import { describe, it, expect, beforeAll } from "vitest";

let u;
beforeAll(async () => {
  await import("../public/js/pos-utils.js");
  u = globalThis.posUtils;
});

describe("dinero en centavos", () => {
  it("evita errores de punto flotante", () => {
    expect(0.1 + 0.2).not.toBe(0.3); // el problema existe en JS...
    expect(u.sumMoney([0.1, 0.2])).toBe(0.3); // ...y acá no
    expect(u.sumMoney([4.5, 4.5, 4.5])).toBe(13.5);
    expect(u.sumMoney([19.99, 0.01])).toBe(20);
  });

  it("redondea casos límite correctamente", () => {
    expect(u.toCents(1.005)).toBe(101);
    expect(u.toCents(2.675)).toBe(268);
    expect(u.toCents(-1.005)).toBe(-101);
    expect(u.toCents("12.30")).toBe(1230);
    expect(u.toCents(null)).toBe(0);
    expect(u.toCents("abc")).toBe(0);
  });

  it("formatea NZD con centavos (antes $4.50 se mostraba como $5)", () => {
    expect(u.formatMoney(4.5, "NZD", "en-NZ")).toBe("$4.50");
    expect(u.formatMoney(1234.5, "NZD", "en-NZ")).toBe("$1,234.50");
    expect(u.formatMoney(0, "NZD", "en-NZ")).toBe("$0.00");
  });
});

describe("precio de línea con promoción (igual que create_order)", () => {
  const promo = { bundle_qty: 2, bundle_price: 5 };
  it("sin promoción", () => {
    expect(u.lineTotal(3, 4.5, null)).toBe(13.5);
  });
  it("2x$5 con 5 unidades a $3 = 2 packs + 1 suelta = $13", () => {
    expect(u.lineTotal(5, 3, promo)).toBe(13);
  });
  it("precio con centavos en packs", () => {
    expect(u.lineTotal(3, 1.1, { bundle_qty: 3, bundle_price: 3.3 })).toBe(3.3);
  });
});

describe("escape de HTML", () => {
  it("neutraliza etiquetas y atributos", () => {
    expect(u.escapeHtml('<img src=x onerror="alert(1)">')).toBe("&lt;img src=x onerror=&quot;alert(1)&quot;&gt;");
    expect(u.escapeHtml("O'Brien & Co")).toBe("O&#39;Brien &amp; Co");
    expect(u.escapeHtml(null)).toBe("");
  });
});

describe("CSV", () => {
  it("escapa comas y comillas", () => {
    expect(u.csvField('Hola, "mundo"')).toBe('"Hola, ""mundo"""');
  });
  it("neutraliza fórmulas", () => {
    expect(u.csvField("=HYPERLINK(\"http://x\")")).toBe("\"'=HYPERLINK(\"\"http://x\"\")\"");
    expect(u.csvField("+56 9 1234")).toBe("'+56 9 1234");
    expect(u.csvField("Daniel")).toBe("Daniel");
  });
});

import { describe, it, expect, beforeAll } from "vitest";

let u;
beforeAll(async () => {
  await import("../public/js/pos-utils.js");
  u = globalThis.posUtils;
});

// Escenario con los mismos números de la prueba en staging:
//  A: 1 Café $4.50 efectivo
//  B: 3 Piscola $34.50 mixto ($20 efectivo + $14.50 tarjeta)
//  C: 1 Terremoto cortesía (valor $15)
const orders = [
  { payment_method: "cash", total: 4.5, cash_amount: 4.5, card_amount: 0, items: [{ name: "Café", qty: 1, subtotal: 4.5 }] },
  { payment_method: "split", total: 34.5, cash_amount: 20, card_amount: 14.5, items: [{ name: "Piscola", qty: 3, subtotal: 34.5 }] },
  { payment_method: "complimentary", total: 15, cash_amount: 0, card_amount: 0, items: [{ name: "Terremoto", qty: 1, subtotal: 15 }] },
];

describe("resumen de ventas", () => {
  it("sin reembolsos cuadra con lo cobrado", () => {
    const s = u.summarize(orders, []);
    expect(s.gross).toBe(39);
    expect(s.net).toBe(39);
    expect(s.cash).toBe(24.5);
    expect(s.card).toBe(14.5);
    expect(u.sumMoney([s.cash, s.card])).toBe(s.net); // efectivo + tarjeta = neto
    expect(s.compCount).toBe(1);
    expect(s.compValue).toBe(15);
    expect(s.paidCount).toBe(2);
    expect(s.avgTicket).toBe(19.5);
    expect(s.byProduct.map((p) => p.name)).toEqual(["Piscola", "Café"]); // la cortesía no es venta
  });

  it("los reembolsos se restan del neto, del medio y del producto", () => {
    const refunds = [{ amount: 11.5, method: "card", lines: [{ name: "Piscola", qty: 1, amount: 11.5 }] }];
    const s = u.summarize(orders, refunds);
    expect(s.gross).toBe(39);
    expect(s.refunds).toBe(11.5);
    expect(s.net).toBe(27.5);
    expect(s.card).toBe(3);
    expect(s.cash).toBe(24.5);
    expect(u.sumMoney([s.cash, s.card])).toBe(s.net);
    const pisco = s.byProduct.find((p) => p.name === "Piscola");
    expect(pisco).toEqual({ name: "Piscola", qty: 2, total: 23 });
    expect(u.sumMoney(s.byProduct.map((p) => p.total))).toBe(s.net); // productos suman el neto
  });

  it("GST: suma el de las ventas y resta el de los reembolsos (cortesías sin GST)", () => {
    const withTax = orders.map((o) => ({ ...o, tax_amount: o.payment_method === "complimentary" ? 0 : Math.round(o.total * 0.15 / 1.15 * 100) / 100 }));
    // 4.50 → 0.59 ; 34.50 → 4.50
    expect(u.summarize(withTax, []).tax).toBe(5.09);
    const refunds = [{ amount: 11.5, method: "card", tax_amount: 1.5, lines: [{ name: "Piscola", qty: 1, amount: 11.5 }] }];
    expect(u.summarize(withTax, refunds).tax).toBe(3.59);
  });

  it("sin centavos perdidos con muchos montos pequeños", () => {
    const many = Array.from({ length: 1000 }, () => ({ payment_method: "cash", total: 0.1, cash_amount: 0.1, card_amount: 0, items: [{ name: "X", qty: 1, subtotal: 0.1 }] }));
    const s = u.summarize(many, []);
    expect(s.net).toBe(100);
    expect(s.byProduct[0].total).toBe(100);
  });

  it("vacío no rompe", () => {
    const s = u.summarize([], []);
    expect(s.net).toBe(0);
    expect(s.avgTicket).toBe(0);
    expect(s.byProduct).toEqual([]);
  });
});

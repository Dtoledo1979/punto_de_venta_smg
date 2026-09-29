// Utilidades puras del POS (sin DOM ni red), compartidas por todas las
// pantallas y cubiertas por tests (tests/pos-utils.test.js).
// Script clásico: expone globalThis.posUtils.
(function (root) {
  "use strict";

  // ---------------------------------------------------------------------
  // Dinero. Todo cálculo se hace en CENTAVOS enteros: sumar decimales en
  // JavaScript da errores (0.1 + 0.2 = 0.30000000000000004). El servidor
  // (numeric(10,2)) es la fuente de verdad; esto es para mostrar y para
  // validar lo que se ingresa antes de mandarlo.
  // ---------------------------------------------------------------------
  function toCents(amount) {
    const n = Number(amount);
    if (!Number.isFinite(n)) return 0;
    // El EPSILON corrige casos como 1.005 * 100 = 100.49999999999999.
    return Math.round((n + Math.sign(n) * Number.EPSILON) * 100);
  }

  function fromCents(cents) {
    return Math.round(cents) / 100;
  }

  // Suma exacta de montos (en unidades, ej. 4.5), vía centavos.
  function sumMoney(amounts) {
    return fromCents(amounts.reduce((acc, a) => acc + toCents(a), 0));
  }

  function roundMoney(amount) {
    return fromCents(toCents(amount));
  }

  const formatters = {};
  function formatMoney(amount, currency, locale) {
    const cur = currency || "NZD";
    const loc = locale || "en-NZ";
    const key = loc + "|" + cur;
    if (!formatters[key]) {
      formatters[key] = new Intl.NumberFormat(loc, { style: "currency", currency: cur });
    }
    return formatters[key].format(roundMoney(amount));
  }

  // Precio de una línea con promoción "N por $X": mismo cálculo que
  // create_order en el servidor, en centavos.
  function lineTotal(qty, unitPrice, promo) {
    const q = Math.trunc(Number(qty) || 0);
    const priceC = toCents(unitPrice);
    if (!promo || !(promo.bundle_qty > 1)) return fromCents(q * priceC);
    const bundles = Math.floor(q / promo.bundle_qty);
    const remainder = q - bundles * promo.bundle_qty;
    return fromCents(bundles * toCents(promo.bundle_price) + remainder * priceC);
  }

  // ---------------------------------------------------------------------
  // Seguridad en el HTML: todo texto que venga de la base (nombres de
  // productos, clientes, eventos, observaciones) pasa por acá antes de ir
  // a innerHTML. Evita que un nombre con <script> o <img onerror=...> se
  // ejecute en la sesión de otra persona de la organización.
  // ---------------------------------------------------------------------
  const HTML_ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;", "`": "&#96;" };
  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"'`]/g, (c) => HTML_ESCAPES[c]);
  }

  // CSV: comillas cuando hace falta, y neutraliza fórmulas (un nombre de
  // cliente "=HYPERLINK(...)" no debe ejecutarse al abrir el CSV en Excel).
  function csvField(value) {
    let s = String(value ?? "");
    if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
    return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }

  // ---------------------------------------------------------------------
  // Resumen de ventas (fuente única para cajas y dashboard).
  //   orders:  pedidos NO anulados y NO de prueba
  //   refunds: reembolsos NO de prueba de esos pedidos
  // Todo en centavos. Ventas netas = cobrado − reembolsado; las cortesías
  // no son ventas (se informan aparte, con su valor de referencia).
  // ---------------------------------------------------------------------
  function summarize(orders, refunds) {
    const C = toCents;
    const s = { grossC: 0, cashC: 0, cardC: 0, refundC: 0, refundCashC: 0, refundCardC: 0, paidCount: 0, compCount: 0, compValueC: 0, refundCount: 0, taxC: 0 };
    const byProduct = {};
    const prod = (name) => (byProduct[name] = byProduct[name] || { qty: 0, totalC: 0 });
    for (const o of orders || []) {
      if (o.payment_method === "complimentary") { s.compCount++; s.compValueC += C(o.total); continue; }
      s.paidCount++;
      s.grossC += C(o.total); s.cashC += C(o.cash_amount); s.cardC += C(o.card_amount); s.taxC += C(o.tax_amount || 0);
      for (const it of o.items || []) { const p = prod(it.name); p.qty += Number(it.qty); p.totalC += C(it.subtotal); }
    }
    for (const r of refunds || []) {
      s.refundCount++;
      s.refundC += C(r.amount); s.taxC -= C(r.tax_amount || 0);
      if (r.method === "cash") s.refundCashC += C(r.amount); else s.refundCardC += C(r.amount);
      for (const l of r.lines || []) { const p = prod(l.name); p.qty -= Number(l.qty); p.totalC -= C(l.amount); }
    }
    const netC = s.grossC - s.refundC;
    return {
      gross: fromCents(s.grossC), refunds: fromCents(s.refundC), net: fromCents(netC), tax: fromCents(s.taxC),
      cash: fromCents(s.cashC - s.refundCashC), card: fromCents(s.cardC - s.refundCardC),
      refundsCash: fromCents(s.refundCashC), refundsCard: fromCents(s.refundCardC),
      paidCount: s.paidCount, refundCount: s.refundCount,
      compCount: s.compCount, compValue: fromCents(s.compValueC),
      avgTicket: s.paidCount ? fromCents(Math.round(netC / s.paidCount)) : 0,
      byProduct: Object.entries(byProduct)
        .map(([name, p]) => ({ name, qty: p.qty, total: fromCents(p.totalC) }))
        .sort((a, b) => b.total - a.total),
    };
  }

  root.posUtils = { toCents, fromCents, sumMoney, roundMoney, formatMoney, lineTotal, escapeHtml, csvField, summarize };
})(typeof globalThis !== "undefined" ? globalThis : window);

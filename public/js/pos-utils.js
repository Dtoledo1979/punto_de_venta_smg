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

  root.posUtils = { toCents, fromCents, sumMoney, roundMoney, formatMoney, lineTotal, escapeHtml, csvField };
})(typeof globalThis !== "undefined" ? globalThis : window);

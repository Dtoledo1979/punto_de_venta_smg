// Traducción de la interfaz. El INGLÉS es el idioma fuente: los textos se
// escriben en inglés en el código y cada otro idioma es un diccionario
// "texto en inglés → traducción" (ver i18n-es.js). Si falta una traducción
// se muestra el inglés, nunca una clave vacía.
//
// La base de datos nunca guarda textos traducidos: guarda códigos
// ('cash', 'voided', 'payment.total_mismatch'...) y acá se les pone nombre.
//
//   t("Order #{n} sent to delivery", { n: 5 })
//   <h2 data-i18n>Menu</h2>                 → se traduce el contenido
//   <input placeholder="Search" data-i18n-ph> → se traduce el placeholder
(function (root) {
  "use strict";

  const SUPPORTED = ["en", "es"];
  const dictionaries = {};
  let current = "en";

  function interpolate(text, params) {
    if (!params) return text;
    return text.replace(/\{(\w+)\}/g, (m, k) => (params[k] !== undefined && params[k] !== null ? String(params[k]) : m));
  }

  function lookup(text, lang) {
    const l = lang || current;
    if (l === "en") return text;
    const d = dictionaries[l];
    return (d && d[text]) || text;
  }

  function t(text, params, lang) {
    return interpolate(lookup(text, lang), params);
  }

  // ---------------------------------------------------------------------
  // Nombres de los códigos que guarda la base de datos.
  // ---------------------------------------------------------------------
  const LABELS = {
    payment: { cash: "Cash", card: "Card", split: "Split", complimentary: "Complimentary" },
    status: { pending_delivery: "To deliver", delivered: "Delivered", voided: "Voided" },
    register: { product: "Products", ticket: "Tickets" },
    movement: {
      opening_stock: "Opening stock", purchase: "Restock", sale: "Sale", adjustment: "Adjustment",
      void_return: "Returned (void)", reopen_sale: "Deducted (reopen)",
    },
    role: { owner: "Owner", admin: "Admin", manager: "Manager", staff: "Staff" },
  };
  function label(kind, code, lang) {
    const en = LABELS[kind] && LABELS[kind][code];
    return en ? t(en, null, lang) : String(code ?? "");
  }

  // ---------------------------------------------------------------------
  // Errores del servidor: código estable + parámetros en DETAIL (JSON).
  // ---------------------------------------------------------------------
  const ERRORS = {
    "auth.forbidden": "Only an owner or admin account can do this.",
    "event.not_found": "Event not found.",
    "ingredient.not_found": "Ingredient not found.",
    "ingredient.unit_locked": "The unit can't change while there is stock loaded (in {unit}). Reset the stock to 0 first.",
    "location.not_found": "Location not found.",
    "member.already_member": "That user is already a member.",
    "member.invalid_role": "Invalid role.",
    "member.invalid_status": "Invalid status.",
    "member.last_owner": "The organisation must keep at least one active owner.",
    "member.not_found": "Member not found.",
    "member.owner_only": "Only an owner can manage owners.",
    "member.user_not_found": "There is no user with that email yet.",
    "order.event_required": "Start an event before selling.",
    "order.invalid_qty": "Invalid quantity for a product.",
    "order.invalid_transaction": "Invalid transaction id.",
    "order.no_items": "The order has no products.",
    "order.not_found": "Order not found.",
    "order.qty_not_integer": "Quantities must be whole numbers.",
    "order.qty_too_large": "Quantity too large for one product (max {max}).",
    "order.total_zero": "The order total must be greater than zero.",
    "payment.amounts_mismatch_method": "The amounts don't match the payment method.",
    "payment.invalid_method": "Invalid payment method.",
    "payment.negative_amount": "Payment amounts can't be negative.",
    "payment.total_mismatch": "Cash + card ({paid}) doesn't match the total ({total}).",
    "pin.incorrect": "Incorrect PIN (or locked after too many attempts — wait a few minutes).",
    "pin.invalid_format": "The PIN must be 4 to 8 digits.",
    "product.not_found": "Product not found in this register.",
    "promotion.not_found": "Promotion not found.",
    "recipe.ingredient_not_found": "A recipe ingredient doesn't belong to this register.",
    "recipe.invalid_qty": "Invalid recipe quantity.",
    "register.invalid_type": "Invalid register type.",
    "register.not_found": "Register not found, or you don't have access.",
    "stock.invalid_mode": "Invalid stock operation.",
    "ticket.invalid_start": "The starting number must be 1 or more.",
    "validation.name_required": "The name is required.",
  };

  // Recibe el error de supabase-js ({ message, details, code }) y devuelve
  // un texto para mostrar. `formatParam` permite formatear montos, etc.
  function errorText(error, formatParam) {
    if (!error) return "";
    const code = String(error.message || "");
    const en = ERRORS[code];
    if (!en) {
      if (/failed to fetch|networkerror|load failed/i.test(code)) return t("No connection to the server. Check your internet.");
      return code || t("Something went wrong.");
    }
    let params = null;
    try { params = error.details ? JSON.parse(error.details) : null; } catch (_) { params = null; }
    if (params && formatParam) for (const k of Object.keys(params)) params[k] = formatParam(k, params[k]);
    return t(en, params);
  }

  function register(lang, dict) { dictionaries[lang] = dict; }

  function setLang(lang) {
    current = SUPPORTED.includes(lang) ? lang : "en";
    document.documentElement.lang = current;
  }

  // Traduce el HTML estático marcado. El texto original (inglés) se guarda
  // la primera vez, así se puede volver a traducir sin perderlo.
  function translateDom(rootEl) {
    const scope = rootEl || document;
    scope.querySelectorAll("[data-i18n]").forEach((el) => {
      if (el.dataset.i18nSrc === undefined) el.dataset.i18nSrc = el.innerHTML.trim();
      el.innerHTML = lookup(el.dataset.i18nSrc);
    });
    scope.querySelectorAll("[data-i18n-ph]").forEach((el) => {
      if (el.dataset.i18nPhSrc === undefined) el.dataset.i18nPhSrc = el.getAttribute("placeholder") || "";
      el.setAttribute("placeholder", lookup(el.dataset.i18nPhSrc));
    });
    if (!rootEl) {
      if (document.documentElement.dataset.i18nTitle === undefined) document.documentElement.dataset.i18nTitle = document.title;
      document.title = lookup(document.documentElement.dataset.i18nTitle);
    }
  }

  root.posI18n = {
    SUPPORTED, LABELS, ERRORS, dictionaries,
    t, label, errorText, register, setLang, translateDom,
    get lang() { return current; },
  };
  root.t = t;
})(typeof globalThis !== "undefined" ? globalThis : window);

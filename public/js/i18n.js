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
      void_return: "Returned (void)", reopen_sale: "Deducted (reopen)", refund_return: "Returned (refund)",
      waste: "Waste", stocktake: "Stocktake",
    },
    role: { owner: "Owner", admin: "Admin", manager: "Manager", staff: "Staff" },
    reason: { wrong_item: "Wrong item", quality: "Quality issue", changed_mind: "Customer changed their mind", overcharged: "Overcharged", other: "Other" },
    payment_status: { approved: "Approved", declined: "Declined", cancelled: "Cancelled", voided: "Voided" },
    limit: { locations: "locations", registers: "registers" },
    plan: { starter: "Starter", pro: "Pro" },
    station: { bar: "Bar", kitchen: "Kitchen", coffee: "Coffee", collection: "Pickup counter", none: "No preparation" },
    waste_reason: { spillage: "Spillage", breakage: "Breakage", expired: "Expired", staff: "Staff consumption", prep_error: "Preparation error", other: "Other" },
    audit: {
      "order.void": "Order voided", "order.reopen": "Order reopened", "order.complimentary": "Complimentary sale",
      "order.refund": "Refund", "payment.declined": "Card declined", "payment.cancelled": "Card payment cancelled",
      "menu.add": "Product added", "menu.update": "Product changed", "menu.remove": "Product removed",
      "menu.location": "Product availability or price by location", "menu.sold_out": "Marked sold out", "menu.back_in_stock": "Back on sale",
      "recipe.change": "Recipe changed", "promotion.insert": "Promotion created", "promotion.update": "Promotion changed",
      "promotion.delete": "Promotion removed", "stock.opening_stock": "Opening stock", "stock.purchase": "Restock",
      "stock.adjustment": "Stock adjustment", "stock.waste": "Waste", "stock.stocktake": "Stocktake", "register.create": "Register created", "register.update": "Register changed",
      "supervisor_pin.change": "Supervisor PIN changed", "member.add": "Member added", "member.update": "Member changed",
      "event.close": "Event closed", "event.reopen": "Event reopened", "ticket.reset_numbering": "Ticket numbering reset",
      "org.update": "Organisation changed", "test_data.purge": "Test data cleared",
      "session.open": "Register opened", "session.close": "Register closed",
      "cash.cash_in": "Cash in", "cash.cash_out": "Cash out",
    },
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
    "order.immutable": "A sale can't be modified after it's recorded.",
    "order.invalid_transition": "That order can't change from {from} to {to}.",
    "order.has_refunds": "This order has refunds and can't be voided.",
    "payment.immutable": "Payments can't be modified.",
    "payment.invalid_attempt": "Invalid payment attempt.",
    "refund.immutable": "Refunds can't be modified.",
    "refund.invalid_reason": "Choose a reason for the refund.",
    "refund.order_voided": "This order is voided — there is nothing to refund.",
    "refund.complimentary": "Complimentary sales can't be refunded.",
    "refund.no_lines": "Choose at least one item to refund.",
    "refund.invalid_line": "Invalid refund line.",
    "refund.qty_exceeds": "Only {available} of {name} can still be refunded.",
    "refund.zero": "The refund amount must be greater than zero.",
    "refund.exceeds_method": "You can refund at most {amount} by {method}.",
    "audit.immutable": "The audit log can't be modified.",
    "stock.invalid_target": "Choose one product or ingredient.",
    "stock.invalid_qty": "Invalid quantity.",
    "stock.invalid_reason": "Choose a reason.",
    "stock.not_tracked": "Stock tracking isn't on for that item.",
    "stocktake.empty": "Count at least one item.",
    "stocktake.duplicate_item": "The same item was counted twice.",
    "stocktake.immutable": "A stocktake can't be modified.",
    "session.not_open": "The register is closed. Open it before selling (or turn on test mode).",
    "session.already_open": "This register is already open.",
    "session.invalid_amount": "Enter a valid amount.",
    "session.invalid_movement": "Invalid cash movement.",
    "session.reason_required": "Write the reason.",
    "session.pending_orders": "{n} orders are still waiting for delivery.",
    "session.immutable": "A closed register session can't be modified.",
    "order.session_closed": "That sale belongs to a register that's already closed — refund it instead of voiding.",
    "org.invalid_tax_rate": "Invalid tax rate.",
    "station.invalid": "Invalid station.",
    "subscription.limit_reached": "You've reached your plan's limit ({plan}: {limit} {what}).",
    "subscription.inactive": "Your subscription isn't active, so the register can't open for real sales. Test mode still works.",
    "org.too_many": "You already own the maximum number of businesses.",
    "org.invalid_currency": "Invalid currency.",
    "org.invalid_slug": "The short name must be 3 to 40 lowercase letters, numbers or dashes.",
    "org.slug_taken": "That short name is already taken — try another.",
    "register.session_open": "Close this register before deactivating it.",
    "org.details_required": "Fill in the legal name, address, city, contact person and phone.",
    "org.invalid_phone": "Enter a valid phone number (digits, spaces, +, dashes).",
    "org.invalid_nzbn": "The NZBN must be 13 digits.",
    "validation.too_long": "One of the fields is too long.",
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

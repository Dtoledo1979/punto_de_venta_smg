// Caja: la pantalla de venta (cajas de productos y de tickets).
//
//   window.POS_ENV.registerType = "product" | "ticket"
//
// El navegador solo manda qué producto, cuántos, qué opciones y la nota:
// precios, promociones, impuestos y stock los calcula el servidor
// (create_order). El total que se muestra se calcula igual que en el
// servidor para poder cobrar el monto exacto.
(function () {
  "use strict";
  const core = window.posCore, sb = core.sb, E = posUtils.escapeHtml;
  const $ = (id) => document.getElementById(id);
  const TYPE = (window.POS_ENV || {}).registerType === "ticket" ? "ticket" : "product";
  const M = (v) => core.money(Number(v));
  const cents = (v) => Math.round(Number(v) * 100);
  const fromCents = (c) => c / 100;
  const ss = {
    get(k) { try { return sessionStorage.getItem(k); } catch (_) { return null; } },
    set(k, v) { try { sessionStorage.setItem(k, v); } catch (_) { /* sin storage */ } },
    del(k) { try { sessionStorage.removeItem(k); } catch (_) { /* sin storage */ } },
  };
  const ls = {
    get(k) { try { return localStorage.getItem(k); } catch (_) { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (_) { /* sin storage */ } },
    del(k) { try { localStorage.removeItem(k); } catch (_) { /* sin storage */ } },
  };

  const S = {
    reg: null, org: {}, cat: { categories: [], products: [], modifier_groups: [] },
    operator: "", category: "all", q: "", cart: [], orderType: "here", customer: "",
    test: ss.get("pos_test_mode") === "1", events: [], closedEvents: [], event: null,
    waiting: [], lastOrder: null, txId: null, charging: false,
  };
  const pin = () => ss.get("pos_pin_" + S.reg.id) || "";
  const eventsMode = () => S.org.business_type === "events" || (S.org.features || {}).events === true;
  const showOrderType = () => TYPE === "product" && !eventsMode() && (S.org.features || {}).order_type !== false;
  const nameRequired = () => TYPE === "product" && eventsMode();
  const printPrefs = () => {
    let p = null; try { p = JSON.parse(ls.get("pos_print_" + S.reg.id) || "null"); } catch (_) { p = null; }
    return p || { customer: true, kitchen: TYPE === "product" };
  };

  function toast(text) {
    const el = $("toast"); el.textContent = text; el.classList.add("show");
    clearTimeout(toast._t); toast._t = setTimeout(() => el.classList.remove("show"), 2800);
  }
  const fail = (prefix, err) => toast(t(prefix) + ": " + core.errorText(err));

  // =====================================================================
  // Caja y bloqueo con PIN
  // =====================================================================
  async function resolveRegister() {
    const { data: regs, error } = await sb.from("registers").select("id, name, type, location_id, locations(name)")
      .eq("org_id", core.orgId).eq("type", TYPE).eq("active", true).order("created_at");
    if (error) { fatal(core.errorText(error)); return null; }
    if (!regs || !regs.length) {
      fatal(TYPE === "ticket" ? t("This business doesn't have a ticket register yet.") : t("This business doesn't have a register yet."),
        core.isAdmin() ? '<a class="btn btn-primary" href="/locales.html">' + E(t("Create a register")) + "</a>" : "");
      return null;
    }
    const saved = regs.find((r) => r.id === ls.get("pos_register_" + TYPE));
    if (regs.length === 1 || saved) return saved || regs[0];
    return new Promise((resolve) => {
      $("lock").hidden = false;
      $("lock-card").innerHTML = "<h1>" + E(t("Which register is this?")) + '</h1><p class="muted">' + E(t("This device will remember it.")) + '</p><div class="list">' +
        regs.map((r) => '<button class="btn btn-lg btn-block" type="button" data-id="' + E(r.id) + '" style="margin-bottom:8px;">' + E((r.locations ? r.locations.name + " · " : "") + r.name) + "</button>").join("") + "</div>";
      $("lock-card").querySelectorAll("button[data-id]").forEach((b) => b.onclick = () => { ls.set("pos_register_" + TYPE, b.dataset.id); resolve(regs.find((r) => r.id === b.dataset.id)); });
    });
  }

  function fatal(text, actionHtml) {
    $("lock").hidden = false;
    $("lock-card").innerHTML = "<h1>" + E(t("Register")) + '</h1><p class="muted">' + E(text) + "</p>" + (actionHtml || "") +
      '<a class="btn btn-ghost" href="/index.html">' + E(t("Back to the office")) + "</a>";
  }

  function showLock() {
    $("lock").hidden = false;
    let code = "";
    $("lock-card").innerHTML =
      '<div class="stack-sm"><span class="muted">' + E(core.org.name) + "</span><h1>" + E(S.reg.name) + '</h1><span class="muted">' + E(S.reg.locations ? S.reg.locations.name : "") + "</span></div>" +
      '<input class="input" id="lock-name" placeholder="' + E(t("Your name")) + '" autocomplete="off" value="' + E(ss.get("pos_operator_" + S.reg.id) || "") + '">' +
      '<div class="pin-dots" id="pin-dots" aria-label="PIN"></div>' +
      '<div class="keypad">' + ["1", "2", "3", "4", "5", "6", "7", "8", "9"].map((d) => '<button type="button" data-k="' + d + '">' + d + "</button>").join("") +
      '<button type="button" class="wide" data-k="del">⌫</button><button type="button" data-k="0">0</button><button type="button" class="wide" data-k="ok">' + E(t("Enter")) + "</button></div>" +
      '<div class="msg error" id="lock-msg" hidden></div>' +
      '<div class="row" style="justify-content:center;"><a class="btn btn-ghost btn-sm" href="/index.html">' + E(t("Back to the office")) + '</a>' +
      '<button class="btn btn-ghost btn-sm" type="button" id="lock-change">' + E(t("Change register")) + "</button></div>";
    const dots = () => { $("pin-dots").innerHTML = Array.from({ length: Math.max(4, code.length) }, (_, i) => '<i class="' + (i < code.length ? "on" : "") + '"></i>').join(""); };
    dots();
    const submit = async () => {
      const name = $("lock-name").value.trim(), m = $("lock-msg");
      if (!name) { m.textContent = t("Type your name."); m.hidden = false; $("lock-name").focus(); return; }
      if (code.length < 4) { m.textContent = t("Each PIN must be 4 to 8 digits."); m.hidden = false; return; }
      const { data: ok, error } = await sb.rpc("verify_register_pin", { p_register_id: S.reg.id, p_pin: code });
      if (error || !ok) { m.textContent = error ? core.errorText(error) : core.errorText({ message: "pin.incorrect" }); m.hidden = false; code = ""; dots(); return; }
      ss.set("pos_pin_" + S.reg.id, code); ss.set("pos_operator_" + S.reg.id, name);
      S.operator = name;
      $("lock").hidden = true;
      afterUnlock();
    };
    $("lock-card").querySelectorAll("[data-k]").forEach((b) => b.onclick = () => {
      const k = b.dataset.k;
      if (k === "del") code = code.slice(0, -1);
      else if (k === "ok") return submit();
      else if (code.length < 8) code += k;
      $("lock-msg").hidden = true; dots();
    });
    document.onkeydown = (e) => {
      if ($("lock").hidden || document.activeElement === $("lock-name")) { if (e.key === "Enter" && document.activeElement === $("lock-name")) submit(); return; }
      if (/^[0-9]$/.test(e.key) && code.length < 8) { code += e.key; dots(); }
      else if (e.key === "Backspace") { code = code.slice(0, -1); dots(); }
      else if (e.key === "Enter") submit();
    };
    $("lock-change").onclick = () => { ls.del("pos_register_" + TYPE); location.reload(); };
    if (!$("lock-name").value) $("lock-name").focus();
  }

  function lockNow() {
    ss.del("pos_pin_" + S.reg.id);
    closeAllDialogs();
    showLock();
  }

  // =====================================================================
  // Arranque
  // =====================================================================
  async function init() {
    applyTest();
    S.reg = await resolveRegister();
    if (!S.reg) return;
    $("reg-name").textContent = S.reg.name;
    $("reg-place").textContent = (S.reg.locations ? S.reg.locations.name : "");
    $("reg-mark").textContent = (core.org.name || "·").trim().charAt(0).toUpperCase();
    const savedPin = pin(), savedName = ss.get("pos_operator_" + S.reg.id);
    if (savedPin && savedName) {
      const { data: ok } = await sb.rpc("verify_register_pin", { p_register_id: S.reg.id, p_pin: savedPin });
      if (ok) { S.operator = savedName; $("lock").hidden = true; return afterUnlock(); }
    }
    showLock();
  }

  let unlockedOnce = false;
  async function afterUnlock() {
    $("reg-place").textContent = (S.reg.locations ? S.reg.locations.name + " · " : "") + S.operator;
    if (unlockedOnce) return;
    unlockedOnce = true;
    const { data: org } = await sb.from("organizations").select("business_type, features").eq("id", core.orgId).maybeSingle();
    S.org = org || {};
    await loadCatalog();
    if (eventsMode()) await loadEvents();
    renderAll();
    posSessions.mount($("session-slot"), { registerId: S.reg.id, pin, operator: () => S.operator, print: printHtml, toast });
    if (TYPE === "product") { await loadWaiting(); subscribeOrders(); setInterval(renderWaitingBadge, 30000); }
    subscribeCatalog();
  }

  async function loadCatalog() {
    const { data, error } = await sb.rpc("register_catalog", { p_register_id: S.reg.id });
    if (error) { fail("Could not load the menu", error); return; }
    S.cat = data;
    // Líneas del pedido con productos que ya no se venden aquí: se quitan.
    const ids = new Set(S.cat.products.map((p) => p.id));
    const before = S.cart.length;
    S.cart = S.cart.filter((l) => ids.has(l.product_id));
    if (S.cart.length !== before) toast(t("Some products in the order are no longer available and were removed."));
    // Precios actualizados para las líneas que siguen.
    S.cart.forEach((l) => { const p = productById(l.product_id); l.base = Number(p.price); l.unit = l.base + l.mods.reduce((s, m) => s + Number(m.price_delta), 0); });
  }

  let catTimer = null;
  function subscribeCatalog() {
    const reload = () => { clearTimeout(catTimer); catTimer = setTimeout(async () => { await loadCatalog(); renderAll(); }, 600); };
    sb.channel("reg-catalog-" + S.reg.id)
      .on("postgres_changes", { event: "*", schema: "pos", table: "products", filter: "org_id=eq." + core.orgId }, reload)
      .on("postgres_changes", { event: "*", schema: "pos", table: "product_locations", filter: "location_id=eq." + S.reg.location_id }, reload)
      .subscribe();
  }

  // =====================================================================
  // Eventos (negocios de eventos)
  // =====================================================================
  async function loadEvents() {
    const [{ data: open }, { data: closed }] = await Promise.all([
      sb.from("events").select("*").eq("org_id", core.orgId).eq("active", true).order("created_at"),
      sb.from("events").select("*").eq("org_id", core.orgId).eq("active", false).order("created_at", { ascending: false }).limit(8),
    ]);
    S.events = open || []; S.closedEvents = closed || [];
    const pref = ss.get("pos_event_" + S.reg.id) || ss.get("pos_selected_event_id");
    S.event = S.events.find((e) => e.id === pref) || (S.events.length === 1 ? S.events[0] : null);
    if (S.event) ss.set("pos_event_" + S.reg.id, S.event.id);
    renderEventChip();
  }
  function renderEventChip() {
    const b = $("event-btn");
    b.hidden = !eventsMode();
    b.textContent = S.event ? S.event.name : t("Choose event");
    b.classList.toggle("test-on", !S.event);
  }
  function openEvents() {
    const body = '<p class="muted">' + E(t("Sales and ticket numbers belong to the event you work on.")) + "</p>" +
      (S.events.length ? '<div class="list">' + S.events.map((e) => '<div class="list-item"><div class="grow"><b>' + E(e.name) + "</b>" +
        (e.event_date ? ' <span class="muted">· ' + E(core.fmtDate(e.event_date + "T12:00:00")) + "</span>" : "") + (S.event && S.event.id === e.id ? ' <span class="pill ok">' + E(t("Working here")) + "</span>" : "") + "</div>" +
        '<button class="btn btn-sm btn-primary" type="button" data-work="' + E(e.id) + '">' + E(t("Work here")) + "</button>" +
        '<button class="btn btn-sm btn-ghost" type="button" data-close-ev="' + E(e.id) + '">' + E(t("Close event")) + "</button></div>").join("") + "</div>"
        : '<p class="muted">' + E(t("No open events.")) + "</p>") +
      '<div class="form-section"><h3>' + E(t("Start new event")) + '</h3><div class="fields"><input class="input" id="ev-name" placeholder="' + E(t("Event name")) + '"><input class="input" id="ev-date" type="date"></div>' +
      '<div><button class="btn" type="button" id="ev-create">' + E(t("Start event")) + "</button></div></div>" +
      (S.closedEvents.length ? '<div class="form-section"><h3>' + E(t("Recently closed")) + '</h3><div class="list">' + S.closedEvents.map((e) =>
        '<div class="list-item"><span class="grow muted">' + E(e.name) + '</span><button class="btn btn-sm" type="button" data-reopen="' + E(e.id) + '">' + E(t("Reopen")) + "</button></div>").join("") + "</div></div>" : "");
    const d = dialog(t("Events"), body);
    d.querySelectorAll("[data-work]").forEach((b) => b.onclick = () => {
      S.event = S.events.find((e) => e.id === b.dataset.work);
      ss.set("pos_event_" + S.reg.id, S.event.id); ss.set("pos_selected_event_id", S.event.id); ss.set("pos_selected_event_name", S.event.name);
      renderEventChip(); d.close(); toast(t("Working on: {name}", { name: S.event.name }));
    });
    d.querySelectorAll("[data-close-ev]").forEach((b) => b.onclick = async () => {
      if (b.dataset.confirm !== "1") { b.dataset.confirm = "1"; b.textContent = t("Tap again to confirm"); return; }
      const { error } = await sb.rpc("close_event", { p_register_id: S.reg.id, p_pin: pin(), p_event_id: b.dataset.closeEv });
      if (error) return fail("Could not close the event", error);
      toast(t("Event closed.")); d.close(); await loadEvents();
    });
    d.querySelectorAll("[data-reopen]").forEach((b) => b.onclick = async () => {
      const { error } = await sb.rpc("reopen_event", { p_register_id: S.reg.id, p_pin: pin(), p_event_id: b.dataset.reopen });
      if (error) return fail("Could not reopen the event", error);
      toast(t("Event reopened.")); d.close(); await loadEvents();
    });
    d.querySelector("#ev-create").onclick = async () => {
      const name = d.querySelector("#ev-name").value.trim();
      if (!name) { toast(t("Type the event name.")); return; }
      const { data, error } = await sb.rpc("create_event", { p_register_id: S.reg.id, p_pin: pin(), p_name: name, p_event_date: d.querySelector("#ev-date").value || null });
      if (error) return fail("Could not create the event", error);
      ss.set("pos_event_" + S.reg.id, data.id); d.close(); toast(t("Event started.")); await loadEvents();
    };
  }

  // =====================================================================
  // Productos
  // =====================================================================
  const productById = (id) => S.cat.products.find((p) => p.id === id);
  const groupById = (id) => S.cat.modifier_groups.find((g) => g.id === id);
  const catById = (id) => S.cat.categories.find((c) => c.id === id);
  const qtyInCart = (pid) => S.cart.filter((l) => l.product_id === pid).reduce((s, l) => s + l.qty, 0);

  function renderAll() { renderCats(); renderTiles(); renderOrder(); }

  function renderCats() {
    const cats = S.cat.categories;
    $("cats").hidden = cats.length === 0;
    $("cats").innerHTML = '<button type="button" data-c="all" aria-pressed="' + String(S.category === "all") + '">' + E(t("All")) + "</button>" +
      cats.map((c) => '<button type="button" data-c="' + E(c.id) + '" aria-pressed="' + String(S.category === c.id) + '"><span class="sw" style="background:' + E(c.color || "var(--line-strong)") + '"></span>' + E(c.name) + "</button>").join("");
    $("cats").querySelectorAll("button").forEach((b) => b.onclick = () => { S.category = b.dataset.c; renderCats(); renderTiles(); });
  }

  function renderTiles() {
    const q = S.q.trim().toLowerCase();
    const list = S.cat.products.filter((p) => (q ? p.name.toLowerCase().includes(q) : (S.category === "all" || p.category_id === S.category)));
    if (!S.cat.products.length) {
      $("tiles").innerHTML = '<div class="empty" style="grid-column:1/-1;"><b>' + E(t("No products for this register yet")) + "</b><span>" +
        E(t("Add them in the office, in Products.")) + "</span>" + (["owner", "admin", "manager"].includes(core.role) ? '<a class="btn" href="/productos.html">' + E(t("Go to Products")) + "</a>" : "") + "</div>";
      return;
    }
    $("tiles").innerHTML = list.length ? list.map((p) => {
      const tags = [];
      if (p.sold_out) tags.push('<span class="tag bad">' + E(t("Sold out")) + "</span>");
      else if (p.track_stock && p.stock_qty !== null) {
        const left = Number(p.stock_qty) - qtyInCart(p.id);
        const low = p.initial_stock > 0 ? left / p.initial_stock <= 0.25 : left <= 3;
        tags.push('<span class="tag ' + (left <= 0 ? "bad" : low ? "warn" : "") + '">' + E(t("{n} left", { n: Math.max(0, left) })) + "</span>");
      }
      if (p.promotion) tags.push('<span class="tag ok">' + E(t("{qty} for {price}", { qty: p.promotion.bundle_qty, price: M(p.promotion.bundle_price) })) + "</span>");
      const color = p.color || (catById(p.category_id) || {}).color || "";
      return '<button type="button" class="tile' + (p.sold_out ? " out" : "") + '" data-id="' + E(p.id) + '"' + (color ? ' style="--tile:' + E(color) + '"' : "") + ">" +
        (p.groups.length ? '<span class="opt-dot" title="' + E(t("Has options")) + '"></span>' : "") +
        "<span>" + E(p.name) + '</span><span class="p">' + E(M(p.price)) + "</span>" + (tags.length ? '<span class="tags">' + tags.join("") + "</span>" : "") + "</button>";
    }).join("") : '<div class="empty" style="grid-column:1/-1;"><span>' + E(t("No products match your search.")) + "</span></div>";
    $("tiles").querySelectorAll(".tile").forEach(wireTile);
  }

  // Toque = agregar; mantener presionado = agotado / disponible.
  function wireTile(el) {
    let timer = null, long = false;
    const p = productById(el.dataset.id);
    el.addEventListener("pointerdown", () => { long = false; timer = setTimeout(() => { long = true; openAvailability(p); }, 600); });
    ["pointerup", "pointerleave", "pointercancel"].forEach((ev) => el.addEventListener(ev, () => clearTimeout(timer)));
    el.addEventListener("contextmenu", (e) => { e.preventDefault(); clearTimeout(timer); long = true; openAvailability(p); });
    el.addEventListener("click", () => {
      if (long) { long = false; return; }
      if (p.sold_out) { openAvailability(p); return; }
      if (p.groups.length) openOptions(p); else addLine(p, [], "", 1);
    });
  }

  function openAvailability(p) {
    const d = dialog(p.name, '<p class="muted">' + E(p.sold_out ? t("This product is marked as sold out at this location.") : t("Mark it as sold out if you run out today. It comes back when you mark it again.")) + "</p>",
      [{ label: p.sold_out ? t("Back on sale") : t("Mark sold out"), primary: true, onClick: async () => {
        const { error } = await sb.rpc("set_sold_out", { p_register_id: S.reg.id, p_pin: pin(), p_product_id: p.id, p_sold_out: !p.sold_out });
        if (error) return fail("Could not update the product", error), false;
        toast(p.sold_out ? t("{name} is back on sale.", { name: p.name }) : t("{name} marked sold out.", { name: p.name }));
        await loadCatalog(); renderAll(); return true;
      } }]);
    return d;
  }

  // Hoja de opciones (Tamaño, Leche, Sabores…). Si viene "line", se edita esa línea.
  function openOptions(p, line) {
    const groups = p.groups.map(groupById).filter(Boolean);
    const sel = {};
    groups.forEach((g) => {
      const chosen = line ? line.mods.filter((m) => m.group_id === g.id).map((m) => m.id) : g.options.filter((o) => o.is_default).map((o) => o.id);
      sel[g.id] = new Set(chosen.slice(0, g.max));
    });
    let qty = line ? line.qty : 1;
    const rule = (g) => g.min > 0 ? (g.max === 1 ? t("Choose 1") : t("Choose {min} to {max}", { min: g.min, max: g.max })) : (g.max === 1 ? t("Optional") : t("Optional · up to {n}", { n: g.max }));
    const body = groups.map((g) => '<div class="opt-group" data-g="' + E(g.id) + '"><h3>' + E(g.name) + '<span class="rule">' + E(rule(g)) + '</span></h3><div class="choice-grid">' +
      g.options.map((o) => '<button type="button" class="choice" data-o="' + E(o.id) + '" aria-pressed="' + String(sel[g.id].has(o.id)) + '">' + E(o.name) +
        (Number(o.price_delta) ? ' <span class="muted">' + (Number(o.price_delta) > 0 ? "+" : "−") + E(M(Math.abs(o.price_delta))) + "</span>" : "") + "</button>").join("") + "</div></div>").join("") +
      '<div class="field"><label for="opt-note">' + E(t("Note for this item (optional)")) + '</label><input class="input" id="opt-note" maxlength="80" placeholder="' + E(t("e.g. extra hot, no onion")) + '" value="' + E(line ? line.note : "") + '"></div>' +
      '<div class="row-between"><span class="label">' + E(t("Quantity")) + '</span><span class="stepper"><button type="button" id="q-minus">−</button><span id="q-val">' + qty + '</span><button type="button" id="q-plus">+</button></span></div>';
    let addBtn;
    const unitPrice = () => Number(p.price) + groups.reduce((s, g) => s + g.options.filter((o) => sel[g.id].has(o.id)).reduce((a, o) => a + Number(o.price_delta), 0), 0);
    const refresh = () => {
      if (addBtn) addBtn.textContent = (line ? t("Update") : t("Add")) + " · " + M(fromCents(cents(unitPrice()) * qty));
      $("q-val").textContent = qty;
    };
    const d = dialog(p.name + " · " + M(p.price), body, [{ label: "", primary: true, onClick: () => {
      const missing = groups.filter((g) => sel[g.id].size < g.min);
      d.querySelectorAll(".opt-group").forEach((el) => el.classList.toggle("missing", missing.some((g) => g.id === el.dataset.g)));
      if (missing.length) { toast(t("Choose {group}.", { group: missing[0].name })); return false; }
      const mods = [];
      groups.forEach((g) => g.options.forEach((o) => { if (sel[g.id].has(o.id)) mods.push({ id: o.id, name: o.name, price_delta: Number(o.price_delta), group_id: g.id }); }));
      const note = d.querySelector("#opt-note").value.trim();
      if (line) S.cart = S.cart.filter((l) => l !== line);
      addLine(p, mods, note, qty);
      return true;
    } }], { wide: true });
    addBtn = d.querySelector(".dialog-foot .btn-primary");
    d.querySelectorAll(".opt-group").forEach((el) => {
      const g = groupById(el.dataset.g);
      el.querySelectorAll(".choice").forEach((c) => c.onclick = () => {
        const set = sel[g.id], id = c.dataset.o;
        if (set.has(id)) { if (g.max === 1 && g.min === 1) return; set.delete(id); }
        else if (g.max === 1) { set.clear(); set.add(id); }
        else if (set.size < g.max) set.add(id);
        else { toast(t("Up to {n} in {group}.", { n: g.max, group: g.name })); return; }
        el.querySelectorAll(".choice").forEach((x) => x.setAttribute("aria-pressed", String(set.has(x.dataset.o))));
        el.classList.remove("missing");
        refresh();
      });
    });
    d.querySelector("#q-minus").onclick = () => { qty = Math.max(1, qty - 1); refresh(); };
    d.querySelector("#q-plus").onclick = () => { qty = Math.min(500, qty + 1); refresh(); };
    refresh();
  }

  function lineKey(pid, mods, note) { return pid + "|" + mods.map((m) => m.id).sort().join(",") + "|" + note; }
  function addLine(p, mods, note, qty) {
    const key = lineKey(p.id, mods, note);
    const found = S.cart.find((l) => l.key === key);
    if (found) found.qty = Math.min(500, found.qty + qty);
    else S.cart.push({ key, product_id: p.id, name: p.name, qty, base: Number(p.price), unit: Number(p.price) + mods.reduce((s, m) => s + m.price_delta, 0), mods, note });
    if (p.track_stock && p.stock_qty !== null && qtyInCart(p.id) > Number(p.stock_qty)) toast(t("Only {n} of {name} left in stock.", { n: Math.max(0, Number(p.stock_qty)), name: p.name }));
    S.txId = null;
    renderOrder(); renderTiles();
  }

  // Totales iguales al servidor: promo "N por $X" sobre el precio base del
  // producto, repartida entre sus líneas en orden; las opciones se cobran igual.
  function totals() {
    const disc = {};
    S.cart.forEach((l) => {
      const p = productById(l.product_id);
      if (!p || !p.promotion || disc[l.product_id] !== undefined) return;
      const q = qtyInCart(l.product_id), n = p.promotion.bundle_qty;
      disc[l.product_id] = Math.max(0, Math.floor(q / n) * (n * cents(l.base) - cents(p.promotion.bundle_price)));
    });
    let total = 0;
    const lines = S.cart.map((l) => {
      const gross = Math.round(l.qty * l.unit * 100);
      const d = Math.min(disc[l.product_id] || 0, Math.round(l.qty * l.base * 100));
      if (d) disc[l.product_id] -= d;
      total += gross - d;
      return { line: l, gross, discount: d, subtotal: gross - d };
    });
    const rate = Number(core.org.tax_rate || 0);
    return { lines, total, tax: rate > 0 ? Math.round(total * rate / (1 + rate)) : 0 };
  }

  function renderOrder() {
    $("order-type").hidden = !showOrderType();
    $("order-type").querySelectorAll("button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.t === S.orderType)));
    $("customer").placeholder = nameRequired() ? t("Customer name (required)") : t("Name for the order (optional)");
    const tt = totals();
    $("lines").innerHTML = S.cart.length ? tt.lines.map(({ line: l, gross, discount, subtotal }, i) =>
      '<div class="line" data-i="' + i + '"><div class="qty"><button type="button" data-d="-1" aria-label="Less">−</button><span>' + l.qty + '</span><button type="button" data-d="1" aria-label="More">+</button></div>' +
      '<div class="nm"><b>' + E(l.name) + "</b>" + (l.mods.length ? "<small>" + E(l.mods.map((m) => m.name).join(" · ")) + "</small>" : "") + (l.note ? "<small>“" + E(l.note) + "”</small>" : "") + "</div>" +
      '<div class="amt">' + (discount ? "<s>" + E(M(fromCents(gross))) + "</s>" : "") + E(M(fromCents(subtotal))) + "</div></div>").join("")
      : '<div class="order-empty">' + E(t("Tap a product to add it.")) + "</div>";
    $("lines").querySelectorAll(".line").forEach((row) => {
      const l = tt.lines[Number(row.dataset.i)].line;
      row.querySelectorAll("[data-d]").forEach((b) => b.onclick = () => {
        l.qty += Number(b.dataset.d);
        if (l.qty <= 0) S.cart = S.cart.filter((x) => x !== l);
        S.txId = null; renderOrder(); renderTiles();
      });
      row.querySelector(".nm").onclick = () => { const p = productById(l.product_id); if (p && p.groups.length) openOptions(p, l); else editNote(l); };
    });
    $("tax-line").textContent = t("Includes {tax} {amount}", { tax: core.org.tax_name || "GST", amount: M(fromCents(tt.tax)) });
    $("total").textContent = M(fromCents(tt.total));
    const count = S.cart.reduce((s, l) => s + l.qty, 0);
    $("charge").disabled = !S.cart.length;
    $("charge").textContent = S.cart.length ? t("Charge {amount}", { amount: M(fromCents(tt.total)) }) : t("Charge");
    $("order-bar").textContent = t("View order ({n}) · {amount}", { n: count, amount: M(fromCents(tt.total)) });
    $("order-bar").hidden = !S.cart.length;
    $("clear").hidden = !S.cart.length;
  }

  function editNote(l) {
    const d = dialog(l.name, '<div class="field"><label for="ln-note">' + E(t("Note for this item (optional)")) + '</label><input class="input" id="ln-note" maxlength="80" value="' + E(l.note) + '"></div>',
      [{ label: t("Save"), primary: true, onClick: () => {
        const note = d.querySelector("#ln-note").value.trim();
        const p = productById(l.product_id);
        S.cart = S.cart.filter((x) => x !== l);
        addLine(p, l.mods, note, l.qty);
        return true;
      } }]);
  }

  // =====================================================================
  // Cobro
  // =====================================================================
  function canCharge() {
    if (!S.cart.length) return false;
    if (eventsMode() && !S.event) { toast(t("Choose or start an event first.")); openEvents(); return false; }
    if (!S.test && !posSessions.isOpen()) { toast(t("Open the register before selling (or turn on test mode).")); return false; }
    S.customer = $("customer").value.trim();
    if (nameRequired() && !S.customer) { toast(t("Type the customer's name before charging.")); $("customer").focus(); return false; }
    return true;
  }

  function stockWarnings() {
    const out = [];
    const seen = new Set();
    S.cart.forEach((l) => {
      const p = productById(l.product_id);
      if (!p || seen.has(p.id) || !p.track_stock || p.stock_qty === null) return;
      seen.add(p.id);
      const q = qtyInCart(p.id);
      if (q > Number(p.stock_qty)) out.push(t("{name}: {left} left, you're selling {qty}", { name: p.name, left: Math.max(0, Number(p.stock_qty)), qty: q }));
    });
    return out;
  }

  function openPayment() {
    if (!canCharge()) return;
    const total = totals().total;
    const warn = stockWarnings();
    const d = dialog(t("Charge"), '<div class="pay-total">' + E(M(fromCents(total))) + "</div>" +
      (warn.length ? '<div class="notice warn"><span class="dot"></span><span>' + E(t("Not enough stock:")) + " " + E(warn.join(" · ")) + ". " + E(t("You can sell anyway; stock goes negative until you record the restock.")) + "</span></div>" : "") +
      (S.test ? '<div class="notice bad"><span class="dot"></span><span>' + E(t("Test mode: this sale is not real and doesn't touch stock or reports.")) + "</span></div>" : "") +
      '<div class="pay-methods"><button class="btn btn-primary" type="button" data-m="card">' + E(t("Card")) + '</button><button class="btn btn-primary" type="button" data-m="cash">' + E(t("Cash")) + "</button>" +
      '<button class="btn" type="button" data-m="split">' + E(t("Cash and card")) + '</button><button class="btn" type="button" data-m="comp">' + E(t("Complimentary")) + "</button></div>");
    d.querySelectorAll("[data-m]").forEach((b) => b.onclick = () => {
      d.close();
      ({ card: () => payCard(0, total, "card", 0), cash: () => payCash(total), split: () => paySplit(total), comp: () => payComp() })[b.dataset.m]();
    });
  }

  function payCash(total) {
    const options = [...new Set([total, ...[500, 1000, 2000, 5000, 10000].map((step) => Math.ceil(total / step) * step)])].filter((c) => c >= total).slice(0, 5);
    const d = dialog(t("Cash"), '<div class="pay-total">' + E(M(fromCents(total))) + "</div>" +
      '<div class="quick-cash">' + options.map((c) => '<button class="btn" type="button" data-c="' + c + '">' + E(c === total ? t("Exact") : M(fromCents(c))) + "</button>").join("") + "</div>" +
      '<div class="field"><label for="cash-in">' + E(t("Amount received")) + '</label><input class="input" id="cash-in" inputmode="decimal" placeholder="' + E(M(fromCents(total))) + '"></div>' +
      '<div class="change-box" id="change-box">' + E(t("Type or tap the amount received.")) + "</div>",
      [{ label: t("Confirm cash sale"), primary: true, onClick: () => {
        const rec = received();
        if (rec === null || rec < total) { toast(t("The amount received is less than the total. Use \"Cash and card\" to split it.")); return false; }
        finalize(total, 0, "cash", rec);
        return true;
      } }]);
    const input = d.querySelector("#cash-in");
    const received = () => { const s = input.value.trim().replace(",", "."); if (!s) return null; const n = Number(s); return Number.isFinite(n) && n >= 0 ? cents(n) : null; };
    const update = () => {
      const rec = received(), box = d.querySelector("#change-box");
      if (rec === null) { box.textContent = t("Type or tap the amount received."); return; }
      box.innerHTML = rec >= total ? E(t("Change")) + "<b>" + E(M(fromCents(rec - total))) + "</b>" : E(t("{amount} still to pay", { amount: M(fromCents(total - rec)) }));
    };
    input.oninput = update;
    d.querySelectorAll("[data-c]").forEach((b) => b.onclick = () => { input.value = (Number(b.dataset.c) / 100).toFixed(2); update(); });
    input.focus();
  }

  function paySplit(total) {
    const d = dialog(t("Cash and card"), '<div class="pay-total">' + E(M(fromCents(total))) + "</div>" +
      '<div class="field"><label for="split-cash">' + E(t("Cash part")) + '</label><input class="input" id="split-cash" inputmode="decimal"></div>' +
      '<p class="muted" id="split-rest"></p>',
      [{ label: t("Continue to card"), primary: true, onClick: () => {
        const c = cashPart();
        if (!(c > 0 && c < total)) { toast(t("The cash part must be more than zero and less than the total.")); return false; }
        payCard(c, total - c, "split", c);
        return true;
      } }]);
    const input = d.querySelector("#split-cash");
    const cashPart = () => { const n = Number(input.value.trim().replace(",", ".")); return Number.isFinite(n) ? cents(n) : NaN; };
    input.oninput = () => { const c = cashPart(); d.querySelector("#split-rest").textContent = c > 0 && c < total ? t("{amount} on card", { amount: M(fromCents(total - c)) }) : ""; };
    input.focus();
  }

  // Tarjeta: el cajero cobra en el terminal y confirma lo que el terminal dice.
  function payCard(cash, card, method, received) {
    const d = dialog(t("Card"), '<p class="muted" style="text-align:center;">' + E(t("Charge this amount on the EFTPOS terminal")) + '</p><div class="pay-total">' + E(M(fromCents(card))) + "</div>" +
      '<p class="muted" style="text-align:center;">' + E(t("Only confirm once the terminal shows APPROVED.")) + "</p>" +
      '<div class="pay-methods"><button class="btn btn-danger" type="button" id="card-declined">' + E(t("Declined")) + '</button><button class="btn btn-primary" type="button" id="card-ok">' + E(t("Approved")) + "</button></div>",
      [], { onCancel: () => recordAttempt(card, "cancelled") });
    d.querySelector("#card-declined").onclick = async () => { d._noCancel = true; d.close(); await recordAttempt(card, "declined"); toast(t("Card declined — nothing was charged, printed or sent.")); };
    d.querySelector("#card-ok").onclick = () => { d._noCancel = true; d.close(); finalize(cash, card, method, received); };
  }
  async function recordAttempt(card, status) {
    if (!(card > 0)) return;
    const { error } = await sb.rpc("record_payment_attempt", { p_register_id: S.reg.id, p_pin: pin(), p_amount: fromCents(card), p_status: status, p_operator: S.operator || null, p_is_test: S.test });
    if (error) fail("Could not record the card attempt", error);
  }

  function payComp() {
    const d = dialog(t("Complimentary"), '<p class="muted">' + E(t("A complimentary sale needs the supervisor PIN. It's recorded in the activity log.")) + "</p>" +
      '<div class="field"><label for="sup-pin">' + E(t("Supervisor PIN")) + '</label><input class="input" id="sup-pin" type="password" inputmode="numeric" maxlength="8" autocomplete="off"></div>',
      [{ label: t("Confirm complimentary"), primary: true, onClick: async () => {
        const sp = d.querySelector("#sup-pin").value;
        const { data: ok } = await sb.rpc("verify_supervisor_pin", { p_register_id: S.reg.id, p_pin: sp });
        if (!ok) { toast(t("Incorrect supervisor PIN.")); return false; }
        finalize(0, 0, "complimentary", 0, sp);
        return true;
      } }]);
    d.querySelector("#sup-pin").focus();
  }

  async function finalize(cash, card, method, received, supervisorPin) {
    if (S.charging) return;
    S.charging = true;
    try {
      const items = S.cart.map((l) => ({ id: l.product_id, qty: l.qty, modifiers: l.mods.map((m) => m.id), note: l.note || undefined }));
      if (!S.txId) S.txId = crypto.randomUUID();
      const { data: order, error } = await sb.rpc("create_order", {
        p_register_id: S.reg.id, p_pin: pin(), p_event_id: eventsMode() && S.event ? S.event.id : null, p_items: items,
        p_payment_method: method, p_cash: fromCents(cash), p_card: fromCents(card),
        p_customer_name: S.customer || null, p_obs: null, p_attended_by: S.operator || null,
        p_supervisor_pin: supervisorPin || null, p_is_test: S.test, p_client_transaction_id: S.txId,
        p_order_type: showOrderType() ? S.orderType : null, p_table: null,
      });
      // Si fue un corte de red, el mismo identificador se reutiliza al reintentar.
      if (error || !order) { fail("Could not record the order", error || { message: "pin.incorrect" }); if (error && /product\.|modifier\./.test(error.message || "")) { await loadCatalog(); renderAll(); } return; }
      S.txId = null;
      S.lastOrder = order;
      printOrder(order, { cash, card, method, received });
      posSessions.refresh();
      const changeC = method === "cash" ? received - cents(order.total) : 0;
      S.cart = []; $("customer").value = ""; S.customer = "";
      $("reg-root").classList.remove("order-open");
      renderOrder();
      if (S.cat.products.some((p) => p.track_stock) || items.length) { await loadCatalog(); renderTiles(); }
      showDone(order, changeC);
      if (TYPE === "product") loadWaiting();
    } finally {
      S.charging = false;
    }
  }

  function showDone(order, changeC) {
    const d = dialog(order.is_test ? t("Test sale recorded") : t("Sale recorded"),
      '<p class="muted" style="text-align:center;">' + E(TYPE === "ticket" ? t("Ticket number") : t("Order number")) + '</p><div class="done-num">#' + E(String(order.ticket_num)) + "</div>" +
      (changeC > 0 ? '<div class="change-box">' + E(t("Change")) + "<b>" + E(M(fromCents(changeC))) + "</b></div>" : "") +
      (TYPE === "product" ? '<p class="muted" style="text-align:center;">' + E(t("Sent to preparation.")) + "</p>" : ""),
      [{ label: t("Print again"), onClick: () => { printOrder(order, { method: order.payment_method, cash: cents(order.cash_amount), card: cents(order.card_amount), received: cents(order.cash_amount) }); return false; } },
       { label: t("Void this sale"), danger: true, confirm: true, onClick: async () => {
          const { error } = await sb.rpc("void_order", { p_register_id: S.reg.id, p_pin: pin(), p_order_id: order.id });
          if (error) return fail("Could not void", error), false;
          toast(t("Order #{n} voided.", { n: order.ticket_num })); posSessions.refresh(); loadCatalog().then(renderTiles); if (TYPE === "product") loadWaiting(); return true; } },
       { label: t("New order"), primary: true, onClick: () => true }]);
    const timer = setTimeout(() => { if (d.open) d.close(); }, changeC > 0 ? 12000 : 5000);
    d.addEventListener("close", () => clearTimeout(timer), { once: true });
  }

  // =====================================================================
  // Pedidos en espera y búsqueda
  // =====================================================================
  async function loadWaiting() {
    const { data } = await sb.from("orders").select("*").eq("register_id", S.reg.id).eq("status", "pending_delivery").order("paid_at");
    S.waiting = data || [];
    renderWaitingBadge();
    if ($("dlg").open && $("dlg")._kind === "orders") renderOrdersTab();
  }
  function subscribeOrders() {
    sb.channel("reg-orders-" + S.reg.id)
      .on("postgres_changes", { event: "*", schema: "pos", table: "orders", filter: "register_id=eq." + S.reg.id }, () => loadWaiting())
      .subscribe();
  }
  function renderWaitingBadge() { $("orders-badge").textContent = S.waiting.length; $("orders-badge").hidden = !S.waiting.length; }

  let ordersTab = TYPE === "product" ? "waiting" : "find", lastSearch = [];
  function openOrders() {
    const d = dialog(t("Orders"), '<div class="tabs" id="o-tabs">' + (TYPE === "product" ? '<button type="button" data-t="waiting">' + E(t("Waiting")) + "</button>" : "") +
      '<button type="button" data-t="find">' + E(t("Find a sale")) + '</button></div><div id="o-body" class="stack"></div>', [], { wide: true });
    d._kind = "orders";
    d.querySelectorAll("#o-tabs button").forEach((b) => b.onclick = () => { ordersTab = b.dataset.t; renderOrdersTab(); });
    renderOrdersTab();
  }
  function renderOrdersTab() {
    const d = $("dlg"), body = d.querySelector("#o-body");
    if (!body) return;
    d.querySelectorAll("#o-tabs button").forEach((b) => b.setAttribute("aria-selected", String(b.dataset.t === ordersTab)));
    if (ordersTab === "waiting") {
      body.innerHTML = S.waiting.length ? '<div class="orders-list">' + S.waiting.map((o) => {
        const mins = Math.max(0, Math.floor((Date.now() - new Date(o.paid_at).getTime()) / 60000));
        return '<div class="ocard"><div class="h"><span>' + (o.is_test ? "🧪 " : "") + "#" + o.ticket_num + (o.customer_name ? " · " + E(o.customer_name) : "") +
          (o.order_type ? ' <span class="pill">' + E(o.order_type === "takeaway" ? t("Takeaway") : o.order_type === "here" ? t("Eat in") : t("Delivery")) + "</span>" : "") + '</span><span class="mins ' + (mins >= 10 ? "bad" : mins >= 5 ? "warn" : "") + '">' + E(t("{n} min", { n: mins })) + "</span></div>" +
          o.items.map((it) => '<div class="it' + (it.delivered ? " done" : "") + '">' + it.qty + "× " + E(it.name) + (it.modifiers && it.modifiers.length ? ' <span class="muted">· ' + E(it.modifiers.map((m) => m.name).join(", ")) + "</span>" : "") + (it.note ? ' <span class="muted">“' + E(it.note) + "”</span>" : "") + "</div>").join("") + "</div>";
      }).join("") + "</div>" + '<p class="hint">' + E(t("Orders are marked delivered on the Delivery screen.")) + '</p><a class="btn" href="/despacho.html">' + E(t("Open the Delivery screen")) + "</a>"
        : '<div class="empty"><b>' + E(t("Nothing waiting")) + "</b><span>" + E(t("Paid orders show up here until they're delivered.")) + "</span></div>";
      return;
    }
    body.innerHTML = '<div class="row"><input class="input grow" id="o-q" placeholder="' + E(t("Order number or customer name")) + '"><button class="btn btn-primary" type="button" id="o-go">' + E(t("Search")) + "</button></div>" +
      (eventsMode() ? '<label class="switch"><input type="checkbox" id="o-all"><span>' + E(t("Search all events (not just the current one)")) + "</span></label>" : "") +
      '<div id="o-results" class="orders-list"></div>';
    const go = async () => {
      const q = body.querySelector("#o-q").value.trim();
      let query = sb.from("orders").select("*, events(name)").eq("register_id", S.reg.id).order("paid_at", { ascending: false }).limit(20);
      if (eventsMode() && S.event && !(body.querySelector("#o-all") || {}).checked) query = query.eq("event_id", S.event.id);
      if (q) query = /^\d+$/.test(q) ? query.eq("ticket_num", Number(q)) : query.ilike("customer_name", "%" + q + "%");
      const { data, error } = await query;
      if (error) { body.querySelector("#o-results").innerHTML = '<div class="msg error">' + E(core.errorText(error)) + "</div>"; return; }
      lastSearch = data || [];
      renderResults();
    };
    body.querySelector("#o-go").onclick = go;
    body.querySelector("#o-q").onkeydown = (e) => { if (e.key === "Enter") go(); };
    go();
  }
  function renderResults() {
    const box = $("dlg").querySelector("#o-results");
    if (!box) return;
    if (!lastSearch.length) { box.innerHTML = '<p class="muted">' + E(t("No results.")) + "</p>"; return; }
    box.innerHTML = lastSearch.map((o) => {
      const refunded = Number(o.refunded_total) > 0;
      const canRefund = o.status !== "voided" && o.payment_method !== "complimentary" && Number(o.refunded_total) < Number(o.total);
      return '<div class="ocard"><div class="h"><span>#' + o.ticket_num + " · " + E(o.customer_name || t("(no name)")) + "</span><span>" + E(M(o.total)) + "</span></div>" +
        '<div class="muted" style="font-size:13px;">' + E([o.events ? o.events.name : "", core.fmtDayTime(o.paid_at), core.label("status", o.status), core.label("payment", o.payment_method),
          refunded ? t("Refunded {amount}", { amount: M(o.refunded_total) }) : "", o.is_test ? "🧪" : ""].filter(Boolean).join(" · ")) + "</div>" +
        '<div class="it">' + E(o.items.map((it) => it.qty + "× " + it.name).join(", ")) + "</div>" +
        '<div class="acts"><button class="btn btn-sm" type="button" data-print="' + E(o.id) + '">' + E(t("Print")) + "</button>" +
        (TYPE === "product" && o.status !== "pending_delivery" ? '<button class="btn btn-sm" type="button" data-reopen="' + E(o.id) + '">' + E(t("Reopen")) + "</button>" : "") +
        (canRefund ? '<button class="btn btn-sm" type="button" data-refund="' + E(o.id) + '">' + E(t("Refund")) + "</button>" : "") +
        (o.status !== "voided" && !refunded ? '<button class="btn btn-sm btn-danger" type="button" data-void="' + E(o.id) + '">' + E(t("Void")) + "</button>" : "") + "</div></div>";
    }).join("");
    const byId = (id) => lastSearch.find((o) => o.id === id);
    box.querySelectorAll("[data-print]").forEach((b) => b.onclick = () => { const o = byId(b.dataset.print); printOrder(o, { method: o.payment_method, cash: cents(o.cash_amount), card: cents(o.card_amount), received: cents(o.cash_amount) }); });
    box.querySelectorAll("[data-reopen]").forEach((b) => b.onclick = async () => {
      const { error } = await sb.rpc("reopen_order", { p_register_id: S.reg.id, p_pin: pin(), p_order_id: b.dataset.reopen });
      if (error) return fail("Could not reopen", error);
      toast(t("Order reopened — it's back on the Delivery screen.")); refreshSearch();
    });
    box.querySelectorAll("[data-void]").forEach((b) => b.onclick = async () => {
      if (b.dataset.confirm !== "1") { b.dataset.confirm = "1"; b.textContent = t("Tap again to confirm"); return; }
      const { error } = await sb.rpc("void_order", { p_register_id: S.reg.id, p_pin: pin(), p_order_id: b.dataset.void });
      if (error) return fail("Could not void", error);
      toast(t("Order voided.")); posSessions.refresh(); loadCatalog().then(renderTiles); refreshSearch();
    });
    box.querySelectorAll("[data-refund]").forEach((b) => b.onclick = () => {
      const o = byId(b.dataset.refund);
      $("dlg").close();
      posRefunds.open(o, { registerId: S.reg.id, pin: pin(), operator: S.operator, onError: (e) => fail("Could not refund", e),
        onDone: (refund) => { toast(t("Refund of {amount} recorded ({method}).", { amount: M(refund.amount), method: core.label("payment", refund.method) })); printRefund(o, refund); posSessions.refresh(); loadCatalog().then(renderTiles); } });
    });
  }
  async function refreshSearch() {
    const ids = lastSearch.map((o) => o.id);
    if (!ids.length) return;
    const { data } = await sb.from("orders").select("*, events(name)").in("id", ids).order("paid_at", { ascending: false });
    lastSearch = data || []; renderResults();
  }

  // =====================================================================
  // Menú de la caja
  // =====================================================================
  function openMenu() {
    const pp = printPrefs();
    const d = dialog(t("Register"),
      '<div class="list">' +
      '<div class="list-item"><div class="grow"><b>' + E(S.reg.name) + '</b><div class="muted">' + E((S.reg.locations ? S.reg.locations.name + " · " : "") + S.operator) + "</div></div>" +
      '<button class="btn btn-sm" type="button" id="m-lock">' + E(t("Switch person")) + "</button></div>" +
      '<label class="list-item switch"><input type="checkbox" id="m-test"' + (S.test ? " checked" : "") + "><span>" + E(t("Test mode (sales are not real)")) + "</span></label>" +
      '<label class="list-item switch"><input type="checkbox" id="m-pc"' + (pp.customer ? " checked" : "") + "><span>" + E(t("Print the customer receipt")) + "</span></label>" +
      (TYPE === "product" ? '<label class="list-item switch"><input type="checkbox" id="m-pk"' + (pp.kitchen ? " checked" : "") + "><span>" + E(t("Print a preparation copy")) + "</span></label>" : "") +
      "</div>" +
      '<div class="row"><button class="btn" type="button" id="m-change">' + E(t("Change register")) + '</button><a class="btn" href="/index.html">' + E(t("Back to the office")) + "</a></div>");
    d.querySelector("#m-lock").onclick = () => { d.close(); lockNow(); };
    d.querySelector("#m-test").onchange = (e) => { S.test = e.target.checked; ss.set("pos_test_mode", S.test ? "1" : "0"); applyTest(); };
    const savePrint = () => ls.set("pos_print_" + S.reg.id, JSON.stringify({ customer: d.querySelector("#m-pc").checked, kitchen: d.querySelector("#m-pk") ? d.querySelector("#m-pk").checked : false }));
    d.querySelector("#m-pc").onchange = savePrint;
    if (d.querySelector("#m-pk")) d.querySelector("#m-pk").onchange = savePrint;
    d.querySelector("#m-change").onclick = () => { ls.del("pos_register_" + TYPE); location.reload(); };
  }
  function applyTest() {
    $("test-banner").hidden = !S.test;
    $("test-btn").hidden = !S.test;
  }

  // =====================================================================
  // Diálogo genérico de la caja
  //   actions: [{label, primary, danger, confirm, onClick → true cierra}]
  // =====================================================================
  function closeAllDialogs() { const d = $("dlg"); if (d.open) { d._noCancel = true; d.close(); } }
  function dialog(title, body, actions, opts) {
    opts = opts || {};
    const d = $("dlg");
    if (d.open) { d._noCancel = true; d.close(); }
    d._kind = null; d._noCancel = false;
    d.className = "dialog" + (opts.wide ? " wide" : "");
    d.innerHTML = '<div class="dialog-body"><div class="dialog-head"><h2>' + E(title) + '</h2><button class="x-btn" type="button" data-x aria-label="Close">×</button></div>' + body +
      (actions && actions.length ? '<div class="dialog-foot"><span class="grow"></span>' + actions.map((a, i) =>
        '<button class="btn' + (a.primary ? " btn-primary btn-lg" : a.danger ? " btn-danger" : "") + '" type="button" data-a="' + i + '">' + E(a.label) + "</button>").join("") + "</div>" : "") + "</div>";
    d.querySelector("[data-x]").onclick = () => d.close();
    let busy = false;
    (actions || []).forEach((a, i) => {
      const b = d.querySelector('[data-a="' + i + '"]');
      b.onclick = async () => {
        if (busy) return;
        if (a.confirm && b.dataset.confirm !== "1") { b.dataset.confirm = "1"; b.textContent = t("Tap again to confirm"); return; }
        busy = true; b.disabled = true;
        try { const r = await a.onClick(); if (r !== false) { d._noCancel = true; d.close(); } } finally { busy = false; b.disabled = false; }
      };
    });
    d.onclose = () => { if (!d._noCancel && opts.onCancel) opts.onCancel(); };
    d.showModal();
    return d;
  }

  // =====================================================================
  // Impresión (en el idioma del negocio)
  // =====================================================================
  const queue = [];
  let printing = false, printingSince = 0;
  function printHtml(html) { queue.push(html); pump(); }
  function pump() {
    if (printing && Date.now() - printingSince > 10000) printing = false;
    if (printing || !queue.length) return;
    printing = true; printingSince = Date.now();
    const html = queue.shift(), area = $("receipt-area");
    area.innerHTML = html;
    let done = false;
    const finish = () => { if (done) return; done = true; window.removeEventListener("afterprint", finish); printing = false; setTimeout(pump, 300); };
    window.addEventListener("afterprint", finish);
    window.print();
    setTimeout(finish, 4000);
  }

  function printOrder(order, pay) {
    const pp = printPrefs(), rl = core.receiptLang();
    const r = (text, params) => E(t(text, params, rl));
    const time = core.fmtTime(order.paid_at);
    const isComp = order.payment_method === "complimentary";
    const typeLabel = order.order_type === "takeaway" ? r("TAKEAWAY") : order.order_type === "here" ? r("EAT IN") : order.order_type === "delivery" ? r("DELIVERY") : "";
    const ev = S.event && order.event_id === S.event.id ? S.event.name : "";
    const lineHtml = (l, withPrice) => '<div class="line"><span class="iname">' + l.qty + "× " + E(l.name) + "</span>" + (withPrice ? '<span class="iprice">' + (isComp ? "<s>" + M(l.subtotal) + "</s> " + M(0) : M(l.subtotal)) + "</span>" : "") + "</div>" +
      (l.modifiers && l.modifiers.length ? '<div class="mods">' + E(l.modifiers.map((m) => m.name).join(", ")) + "</div>" : "") +
      (l.note ? '<div class="mods">“' + E(l.note) + "”</div>" : "") +
      (withPrice && Number(l.discount) > 0 ? '<div class="mods">' + r("Promotion −{amount}", { amount: M(l.discount) }) + "</div>" : "");
    if (TYPE === "product" && pp.kitchen) {
      printHtml('<div class="receipt-copy"><h4>' + r("PREPARATION") + '</h4><div class="big">#' + order.ticket_num + "</div>" +
        (order.customer_name ? '<div class="line" style="justify-content:center;"><b>' + E(order.customer_name) + "</b></div>" : "") +
        (typeLabel ? '<div class="line" style="justify-content:center;"><b>' + typeLabel + "</b></div>" : "") +
        (order.is_test ? '<div class="line" style="justify-content:center;"><b>' + r("***** TEST — NOT A REAL SALE *****") + "</b></div>" : "") +
        '<div class="line"><span>' + E(ev) + "</span><span>" + time + "</span></div><hr>" + order.items.map((l) => lineHtml(l, false)).join("") + "</div>");
    }
    if (!pp.customer) return;
    let html = '<div class="receipt-copy"><h3>' + E(core.org.name) + "</h3><h4>" + (TYPE === "ticket" ? r("Ticket") : r("RECEIPT")) + "</h4>";
    if (core.org.tax_number) html += '<div class="line" style="justify-content:center;"><span>' + r("{tax} No. {n}", { tax: core.org.tax_name || "GST", n: core.org.tax_number }) + "</span></div>";
    if (order.is_test) html += '<div class="line" style="justify-content:center;"><b>' + r("***** TEST — NOT A REAL SALE *****") + "</b></div>";
    if (ev) html += '<div class="line" style="justify-content:center;"><b>' + E(ev) + "</b></div>";
    html += '<div class="line"><b>' + r("Order #{n}", { n: order.ticket_num }) + "</b><span>" + core.fmtDate(order.paid_at) + " " + time + "</span></div>";
    if (typeLabel) html += '<div class="line"><span>' + typeLabel + "</span></div>";
    if (order.customer_name) html += '<div class="line"><span class="iname">' + r("Customer") + '</span><span class="iprice">' + E(order.customer_name) + "</span></div>";
    if (order.attended_by) html += '<div class="line"><span class="iname">' + r("Served by") + '</span><span class="iprice">' + E(order.attended_by) + "</span></div>";
    html += "<hr>" + order.items.map((l) => lineHtml(l, true)).join("") + "<hr>";
    if (isComp) {
      html += '<div class="line"><b>' + r("COMPLIMENTARY") + "</b></div>" + '<div class="line"><span class="iname">' + r("Reference value") + '</span><span class="iprice">' + M(order.total) + "</span></div>" +
        '<div class="line total"><span class="iname">' + r("TOTAL DUE") + '</span><span class="iprice">' + M(0) + "</span></div>";
    } else {
      html += '<div class="line total"><span class="iname">' + r("TOTAL") + '</span><span class="iprice">' + M(order.total) + "</span></div>";
      if (Number(order.tax_amount) > 0) html += '<div class="line"><span class="iname">' + r("Includes {tax}", { tax: core.org.tax_name || "GST" }) + '</span><span class="iprice">' + M(order.tax_amount) + "</span></div>";
      if (order.payment_method === "split") html += '<div class="line"><span class="iname">' + r("Cash") + '</span><span class="iprice">' + M(order.cash_amount) + '</span></div><div class="line"><span class="iname">' + r("Card") + '</span><span class="iprice">' + M(order.card_amount) + "</span></div>";
      else html += '<div class="line"><span class="iname">' + E(core.label("payment", order.payment_method, rl)) + '</span><span class="iprice">' + M(order.total) + "</span></div>";
      if (order.payment_method === "cash" && pay && pay.received > cents(order.total)) {
        html += '<div class="line"><span class="iname">' + r("Received") + '</span><span class="iprice">' + M(fromCents(pay.received)) + "</span></div>" +
          '<div class="line"><span class="iname">' + r("Change") + '</span><span class="iprice">' + M(fromCents(pay.received - cents(order.total))) + "</span></div>";
      }
    }
    printHtml(html + "</div>");
  }

  function printRefund(o, refund) {
    const rl = core.receiptLang(), r = (text, params) => E(t(text, params, rl));
    let html = '<div class="receipt-copy"><h3>' + E(core.org.name) + "</h3><h4>" + r("REFUND") + "</h4>";
    if (refund.is_test) html += '<div class="line" style="justify-content:center;"><b>' + r("***** TEST — NOT A REAL SALE *****") + "</b></div>";
    html += '<div class="line"><b>' + r("Order #{n}", { n: o.ticket_num }) + "</b><span>" + core.fmtDayTime(refund.created_at) + "</span></div><hr>";
    refund.lines.forEach((l) => { html += '<div class="line"><span class="iname">' + l.qty + "× " + E(l.name) + '</span><span class="iprice">-' + M(l.amount) + "</span></div>"; });
    html += '<hr><div class="line total"><span class="iname">' + r("REFUNDED") + '</span><span class="iprice">-' + M(refund.amount) + "</span></div>" +
      '<div class="line"><span class="iname">' + r("Method") + '</span><span class="iprice">' + E(core.label("payment", refund.method, rl)) + "</span></div></div>";
    printHtml(html);
  }

  // =====================================================================
  // Controles fijos
  // =====================================================================
  $("search").oninput = () => { S.q = $("search").value; renderTiles(); };
  $("order-type").querySelectorAll("button").forEach((b) => b.onclick = () => { S.orderType = b.dataset.t; renderOrder(); });
  $("customer").oninput = () => { S.customer = $("customer").value; };
  $("charge").onclick = openPayment;
  $("clear").onclick = () => { S.cart = []; S.txId = null; renderOrder(); renderTiles(); };
  $("order-bar").onclick = () => $("reg-root").classList.add("order-open");
  $("order-close").onclick = () => $("reg-root").classList.remove("order-open");
  $("orders-btn").onclick = openOrders;
  $("menu-btn").onclick = openMenu;
  $("event-btn").onclick = openEvents;
  $("test-btn").onclick = openMenu;

  core.ready.then(init);
})();

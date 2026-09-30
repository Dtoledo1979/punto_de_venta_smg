// Núcleo compartido de todas las pantallas del POS: conexión a Supabase,
// sesión (Supabase Auth), organización activa, idioma y formatos, y
// adaptación al contrato de las funciones del schema pos.
//
// Script clásico (no módulo) a propósito: las pantallas usan funciones
// globales desde onclick="...". Requiere, antes de este archivo:
//   window.POS_ENV   (lo completa Vite desde VITE_SUPABASE_URL / _ANON_KEY)
//   /vendor/supabase.js, /js/pos-utils.js, /js/i18n.js, /js/i18n-es.js
//
// Uso en una pantalla:
//   const sb = posCore.sb;
//   posCore.ready.then(init);   // init corre con sesión + organización + idioma
(function () {
  "use strict";

  const LANG_KEY = "pos_lang";
  const ORG_KEY = "pos_org_id";
  const storage = {
    get(k) { try { return localStorage.getItem(k); } catch (_) { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (_) { /* sin storage */ } },
  };

  // Idioma provisorio (antes de conocer la organización): el elegido en este
  // dispositivo, o inglés.
  posI18n.setLang(storage.get(LANG_KEY) || "en");

  const env = window.POS_ENV || {};
  const configured = env.supabaseUrl && env.supabaseAnonKey &&
    !String(env.supabaseUrl).startsWith("%") && !String(env.supabaseAnonKey).startsWith("%");
  if (!configured) {
    document.addEventListener("DOMContentLoaded", () => {
      document.documentElement.classList.remove("pos-auth-pending");
      document.body.innerHTML = '<p style="font-family:sans-serif; padding:24px;">Missing configuration: ' +
        "VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (see .env.example).</p>";
    });
    throw new Error("POS_ENV not configured");
  }

  const sb = window.supabase.createClient(env.supabaseUrl, env.supabaseAnonKey, {
    db: { schema: "pos" },
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
  });

  // Las funciones protegidas por PIN devuelven null/false cuando el PIN es
  // incorrecto (no lanzan error: así el intento fallido queda registrado
  // para el bloqueo por intentos). Acá se convierte ese resultado en un
  // error normal con código, para que cada pantalla lo maneje igual.
  const PIN_GUARDED = new Set([
    "create_event", "close_event", "reopen_event",
    "add_menu_item", "update_menu_item", "remove_menu_item", "set_item_color",
    "disable_stock", "restock_item",
    "upsert_ingredient", "remove_ingredient", "restock_ingredient",
    "set_recipe", "upsert_promotion", "delete_promotion",
    "create_order", "void_order", "reopen_order",
    "despacho_toggle_item", "despacho_confirm_all",
    "record_payment_attempt", "refund_order", "record_waste", "record_stocktake",
    "open_register_session", "record_cash_movement", "close_register_session",
    "set_item_station", "despacho_mark_station",
  ]);
  const rawRpc = sb.rpc.bind(sb);
  sb.rpc = function (fn, args, opts) {
    const query = rawRpc(fn, args, opts);
    if (!PIN_GUARDED.has(fn)) return query;
    return Promise.resolve(query).then((res) =>
      !res.error && (res.data === null || res.data === false)
        ? { ...res, error: { message: "pin.incorrect", code: "pin.incorrect" } }
        : res);
  };

  // Formatos según la REGIÓN de la organización (no según el idioma): en NZ
  // siempre día/mes y NZ$, esté la pantalla en inglés o en español.
  const fmtCache = {};
  function dtf(opts) {
    const loc = (core.org && core.org.locale) || "en-NZ";
    const key = loc + JSON.stringify(opts);
    if (!fmtCache[key]) {
      const tz = core.org && core.org.timezone;
      try { fmtCache[key] = new Intl.DateTimeFormat(loc, tz ? { ...opts, timeZone: tz } : opts); }
      catch (_) { fmtCache[key] = new Intl.DateTimeFormat("en-NZ", opts); }
    }
    return fmtCache[key];
  }

  const core = {
    sb,
    session: null,
    user: null,
    orgId: null,
    org: null,        // { name, currency, timezone, language, locale }
    role: null,       // owner | admin | manager | staff
    memberships: [],
    isAdmin() { return core.role === "owner" || core.role === "admin"; },
    esc: posUtils.escapeHtml,
    t: posI18n.t,
    label: posI18n.label,
    // Idioma de lo que se IMPRIME (boletas): el de la organización.
    receiptLang() { return (core.org && core.org.language) || "en"; },
    money(amount) {
      return posUtils.formatMoney(amount, core.org && core.org.currency, (core.org && core.org.locale) || "en-NZ");
    },
    fmtTime(d) { return dtf({ hour: "2-digit", minute: "2-digit" }).format(new Date(d)); },
    fmtTimeSec(d) { return dtf({ hour: "2-digit", minute: "2-digit", second: "2-digit" }).format(new Date(d)); },
    fmtDate(d) { return dtf({ day: "2-digit", month: "2-digit", year: "numeric" }).format(new Date(d)); },
    fmtDayTime(d) { return dtf({ day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }).format(new Date(d)); },
    errorText(error) {
      return posI18n.errorText(error, (k, v) =>
        ["paid", "total", "amount"].includes(k) ? core.money(v) : k === "method" ? core.label("payment", v) : k === "what" ? core.label("limit", v) : v);
    },
    setLang(lang) {
      storage.set(LANG_KEY, lang);
      location.reload();
    },
    async logout() {
      try { sessionStorage.clear(); } catch (_) { /* sin storage */ }
      await sb.auth.signOut();
      location.replace("/login.html");
    },
    switchOrg(orgId) {
      storage.set(ORG_KEY, orgId);
      try { sessionStorage.clear(); } catch (_) { /* sin storage */ }
      location.href = "/index.html";
    },
  };
  window.posCore = core;
  core.langSelect = () => langSelect();

  const style = document.createElement("style");
  style.textContent = "html.pos-auth-pending body{visibility:hidden}" +
    ".pos-userbar{display:flex;align-items:center;gap:8px;font-size:12.5px;color:#C9D3DC;flex-wrap:wrap}" +
    ".pos-userbar b{color:#fff;font-weight:600}.pos-userbar a{color:#C9D3DC;cursor:pointer;text-decoration:underline}" +
    ".pos-userbar select{font-size:12.5px;padding:2px 4px;border-radius:6px}";
  document.head.appendChild(style);

  function whenDomReady(fn) {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", fn);
    else fn();
  }

  function langSelect() {
    return '<select class="pos-lang" aria-label="Language">' + posI18n.SUPPORTED.map((l) =>
      '<option value="' + l + '"' + (l === posI18n.lang ? " selected" : "") + ">" + l.toUpperCase() + "</option>").join("") + "</select>";
  }

  // Páginas públicas (login): solo conexión e idioma, sin exigir sesión.
  if (env.publicPage) {
    document.documentElement.classList.remove("pos-auth-pending");
    core.ready = Promise.resolve(core);
    core.langSelect = langSelect;
    whenDomReady(() => posI18n.translateDom());
    return;
  }
  document.documentElement.classList.add("pos-auth-pending");

  function goToLogin() {
    const next = location.pathname + location.search + location.hash;
    location.replace("/login.html?next=" + encodeURIComponent(next));
    return new Promise(() => {}); // la página se está yendo: no seguir
  }

  function renderUserBar() {
    const host = document.querySelector("header, .top, .app-nav");
    const bar = document.createElement("span");
    bar.className = "pos-userbar";
    let orgHtml = "<b>" + core.esc(core.org.name) + "</b>";
    if (core.memberships.length > 1) {
      orgHtml = '<select class="pos-org" aria-label="' + core.esc(core.t("Organisation")) + '">' + core.memberships.map((m) =>
        '<option value="' + core.esc(m.org_id) + '"' + (m.org_id === core.orgId ? " selected" : "") + ">" +
        core.esc(m.organizations.name) + "</option>").join("") + "</select>";
    }
    bar.innerHTML = orgHtml + "<span>· " + core.esc(core.user.email) + "</span>" + langSelect() +
      "<a>" + core.esc(core.t("Sign out")) + "</a>";
    bar.querySelector("a").addEventListener("click", () => core.logout());
    bar.querySelector(".pos-lang").addEventListener("change", (e) => core.setLang(e.target.value));
    const orgSel = bar.querySelector(".pos-org");
    if (orgSel) orgSel.addEventListener("change", () => core.switchOrg(orgSel.value));
    if (host) host.appendChild(bar);
    else {
      bar.style.cssText = "position:fixed;bottom:8px;right:10px;background:#0E1116;padding:6px 10px;border-radius:8px;z-index:50";
      document.body.appendChild(bar);
    }
  }

  // Aviso de suscripción: días de prueba, prueba vencida o pago pendiente.
  // (Informativo: la base de datos es la que impide abrir caja sin
  // suscripción vigente.)
  async function showSubscriptionBanner() {
    const { data: e } = await sb.rpc("org_entitlements", { p_org_id: core.orgId });
    if (!e) return;
    core.entitlements = e;
    let text = null, bad = false;
    if (e.status === "incomplete") { text = core.t("Your subscription is awaiting payment. You can set everything up and use test mode; registers open for real sales once payment is confirmed."); bad = true; }
    else if (!e.can_operate) { text = core.t("Your subscription isn't active (cancelled). You can look around and use test mode, but registers can't open for real sales."); bad = true; }
    else if (e.status === "past_due") { text = core.t("Payment is overdue — please update your billing to avoid interruption."); bad = true; }
    if (!text) return;
    const div = document.createElement("div");
    div.style.cssText = "text-align:center;font:600 13px Inter,Arial,sans-serif;padding:7px 12px;" + (bad ? "background:#FDECEA;color:#A3271D" : "background:#EEF8DA;color:#3A5200");
    div.textContent = text;
    document.body.insertBefore(div, document.body.firstChild);
  }

  function showBlocked(message) {
    whenDomReady(() => {
      document.documentElement.classList.remove("pos-auth-pending");
      document.body.innerHTML = '<div style="font-family:Inter,Arial,sans-serif;max-width:420px;margin:80px auto;padding:24px;text-align:center">' +
        "<p>" + core.esc(message) + '</p><p><a href="#" id="pos-logout">' + core.esc(core.t("Sign out")) + "</a></p></div>";
      document.getElementById("pos-logout").addEventListener("click", (e) => { e.preventDefault(); core.logout(); });
    });
  }

  core.ready = (async () => {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return goToLogin();
    core.session = session;
    core.user = session.user;

    const { data: mems, error } = await sb.from("memberships")
      .select("org_id, role, organizations(name, currency, timezone, status, language, locale, tax_rate, tax_name, tax_number)")
      .eq("user_id", session.user.id).eq("status", "active");
    if (error) { showBlocked(core.t("Could not load your organisation: {msg}", { msg: core.errorText(error) })); return new Promise(() => {}); }

    // La RLS ya oculta las organizaciones suspendidas (organizations viene null).
    core.memberships = (mems || []).filter((m) => m.organizations);

    // Página de alta (onboarding): funciona con o sin organización.
    if (env.noOrgPage) {
      posI18n.setLang(storage.get(LANG_KEY) || "en");
      await new Promise((resolve) => whenDomReady(resolve));
      posI18n.translateDom();
      document.documentElement.classList.remove("pos-auth-pending");
      return core;
    }
    if (!core.memberships.length) {
      if ((mems || []).length) {
        showBlocked(core.t("Your organisation is suspended. Contact support to reactivate it."));
        return new Promise(() => {});
      }
      // Cuenta nueva sin negocio: al alta guiada.
      location.replace("/onboarding.html");
      return new Promise(() => {});
    }

    const saved = storage.get(ORG_KEY);
    const m = core.memberships.find((x) => x.org_id === saved) || core.memberships[0];
    core.orgId = m.org_id;
    core.role = m.role;
    core.org = m.organizations;
    storage.set(ORG_KEY, core.orgId);

    // Idioma de la pantalla: el elegido en este dispositivo; si no, el de la organización.
    posI18n.setLang(storage.get(LANG_KEY) || core.org.language || "en");

    // La pantalla arranca (init) recién con el HTML traducido.
    await new Promise((resolve) => whenDomReady(resolve));
    posI18n.translateDom();
    renderUserBar();
    document.documentElement.classList.remove("pos-auth-pending");
    showSubscriptionBanner();

    // Sesión cerrada en otra pestaña o refresh token vencido → al login.
    sb.auth.onAuthStateChange((event) => { if (event === "SIGNED_OUT") goToLogin(); });
    return core;
  })();
})();

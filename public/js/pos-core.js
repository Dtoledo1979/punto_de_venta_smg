// Núcleo compartido de todas las pantallas del POS: conexión a Supabase,
// sesión (Supabase Auth), organización activa y adaptación al contrato de
// las funciones del schema pos.
//
// Script clásico (no módulo) a propósito: las pantallas usan funciones
// globales desde onclick="...". Requiere, antes de este archivo:
//   window.POS_ENV   (lo completa Vite desde VITE_SUPABASE_URL / _ANON_KEY)
//   /vendor/supabase.js
//   /js/pos-utils.js
//
// Uso en una pantalla:
//   const sb = posCore.sb;
//   posCore.ready.then(init);   // init corre solo con sesión + organización
(function () {
  "use strict";

  const env = window.POS_ENV || {};
  const configured = env.supabaseUrl && env.supabaseAnonKey &&
    !String(env.supabaseUrl).startsWith("%") && !String(env.supabaseAnonKey).startsWith("%");
  if (!configured) {
    document.addEventListener("DOMContentLoaded", () => {
      document.body.innerHTML = '<p style="font-family:sans-serif; padding:24px;">Falta configurar ' +
        "VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY (ver .env.example).</p>";
    });
    throw new Error("POS_ENV sin configurar");
  }

  const sb = window.supabase.createClient(env.supabaseUrl, env.supabaseAnonKey, {
    db: { schema: "pos" },
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
  });

  // Las funciones protegidas por PIN devuelven null/false cuando el PIN es
  // incorrecto (no lanzan error: así el intento fallido queda registrado
  // para el bloqueo por intentos). Acá se convierte ese resultado en un
  // error normal, para que cada pantalla lo maneje igual que cualquier otro.
  const PIN_GUARDED = new Set([
    "create_event", "close_event", "reopen_event",
    "add_menu_item", "update_menu_item", "remove_menu_item", "set_item_color",
    "disable_stock", "restock_item",
    "upsert_ingredient", "remove_ingredient", "restock_ingredient",
    "set_recipe", "upsert_promotion", "delete_promotion",
    "create_order", "void_order", "reopen_order",
    "despacho_toggle_item", "despacho_confirm_all",
  ]);
  const rawRpc = sb.rpc.bind(sb);
  sb.rpc = function (fn, args, opts) {
    const query = rawRpc(fn, args, opts);
    if (!PIN_GUARDED.has(fn)) return query;
    return Promise.resolve(query).then((res) =>
      !res.error && (res.data === null || res.data === false)
        ? { ...res, error: { message: "PIN incorrecto (o bloqueado por intentos fallidos — espera unos minutos).", code: "PIN_INCORRECTO" } }
        : res);
  };

  const ORG_KEY = "pos_org_id";
  const core = {
    sb,
    session: null,
    user: null,
    orgId: null,
    org: null,        // { name, currency, timezone }
    role: null,       // owner | admin | manager | staff
    memberships: [],
    isAdmin() { return core.role === "owner" || core.role === "admin"; },
    money(amount) { return posUtils.formatMoney(amount, core.org && core.org.currency); },
    esc: posUtils.escapeHtml,
    async logout() {
      try { sessionStorage.clear(); } catch (_) { /* sin storage disponible */ }
      await sb.auth.signOut();
      location.replace("/login.html");
    },
    switchOrg(orgId) {
      try { localStorage.setItem(ORG_KEY, orgId); } catch (_) { /* sin storage */ }
      try { sessionStorage.clear(); } catch (_) { /* sin storage */ }
      location.href = "/index.html";
    },
  };
  window.posCore = core;

  // Mientras se verifica la sesión, la página queda oculta (evita mostrar
  // por un instante una pantalla que después redirige al login).
  const style = document.createElement("style");
  style.textContent = "html.pos-auth-pending body{visibility:hidden}" +
    ".pos-userbar{display:flex;align-items:center;gap:8px;font-size:12.5px;color:#C9D3DC;flex-wrap:wrap}" +
    ".pos-userbar b{color:#fff;font-weight:600}.pos-userbar a{color:#C9D3DC;cursor:pointer;text-decoration:underline}" +
    ".pos-userbar select{font-size:12.5px;padding:2px 4px;border-radius:6px}";
  document.head.appendChild(style);

  // Páginas públicas (login): solo conexión, sin exigir sesión.
  if (env.publicPage) {
    document.documentElement.classList.remove("pos-auth-pending");
    core.ready = Promise.resolve(core);
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
      orgHtml = '<select aria-label="Organización">' + core.memberships.map((m) =>
        '<option value="' + core.esc(m.org_id) + '"' + (m.org_id === core.orgId ? " selected" : "") + ">" +
        core.esc(m.organizations.name) + "</option>").join("") + "</select>";
    }
    bar.innerHTML = orgHtml + "<span>· " + core.esc(core.user.email) + "</span><a>Salir</a>";
    bar.querySelector("a").addEventListener("click", () => core.logout());
    const sel = bar.querySelector("select");
    if (sel) sel.addEventListener("change", () => core.switchOrg(sel.value));
    if (host) host.appendChild(bar);
    else {
      bar.style.cssText = "position:fixed;bottom:8px;right:10px;background:#0E1116;padding:6px 10px;border-radius:8px;z-index:50";
      document.body.appendChild(bar);
    }
  }

  function showBlocked(message) {
    document.documentElement.classList.remove("pos-auth-pending");
    document.body.innerHTML = '<div style="font-family:Inter,Arial,sans-serif;max-width:420px;margin:80px auto;padding:24px;text-align:center">' +
      "<p>" + core.esc(message) + '</p><p><a href="#" id="pos-logout">Cerrar sesión</a></p></div>';
    document.getElementById("pos-logout").addEventListener("click", (e) => { e.preventDefault(); core.logout(); });
  }

  core.ready = (async () => {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return goToLogin();
    core.session = session;
    core.user = session.user;

    const { data: mems, error } = await sb.from("memberships")
      .select("org_id, role, organizations(name, currency, timezone, status)")
      .eq("user_id", session.user.id).eq("status", "active");
    if (error) { showBlocked("No se pudo cargar tu organización: " + error.message); return new Promise(() => {}); }

    // La RLS ya oculta las organizaciones suspendidas (organizations viene null).
    core.memberships = (mems || []).filter((m) => m.organizations);
    if (!core.memberships.length) {
      showBlocked("Tu cuenta (" + session.user.email + ") no pertenece a ninguna organización activa. Pide acceso a un administrador.");
      return new Promise(() => {});
    }

    let saved = null;
    try { saved = localStorage.getItem(ORG_KEY); } catch (_) { /* sin storage */ }
    const m = core.memberships.find((x) => x.org_id === saved) || core.memberships[0];
    core.orgId = m.org_id;
    core.role = m.role;
    core.org = m.organizations;
    try { localStorage.setItem(ORG_KEY, core.orgId); } catch (_) { /* sin storage */ }

    const show = () => { renderUserBar(); document.documentElement.classList.remove("pos-auth-pending"); };
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", show);
    else show();

    // Sesión cerrada en otra pestaña o refresh token vencido → al login.
    sb.auth.onAuthStateChange((event) => { if (event === "SIGNED_OUT") goToLogin(); });
    return core;
  })();
})();

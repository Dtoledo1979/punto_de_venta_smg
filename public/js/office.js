// Estructura común de la oficina (back office): menú lateral, barra
// superior en el teléfono, selector de negocio, idioma y "Abrir caja".
//
// Uso en una pantalla de oficina:
//   window.POS_ENV = { ..., officePage: "today" }   (clave del ítem activo)
//   <main class="main-inner">…contenido…</main>
//   <script src="/js/office.js"></script>   (después de pos-core.js)
//
// El menú se arma apenas carga el HTML (con textos data-i18n, que pos-core
// traduce al conocer el idioma) y se completa cuando hay sesión.
(function () {
  "use strict";
  const core = window.posCore;
  const t = posI18n.t;
  const E = posUtils.escapeHtml;
  const active = (window.POS_ENV || {}).officePage || "";
  // Marca textos para el extractor de traducciones (se traducen en fill()).
  const T = (s) => s;

  const ICONS = {
    today: '<path d="M3 11l9-7 9 7"/><path d="M5 10v10h14V10"/>',
    sales: '<path d="M4 20V10"/><path d="M10 20V4"/><path d="M16 20v-7"/><path d="M22 20H2"/>',
    products: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
    inventory: '<path d="M3 7l9-4 9 4-9 4-9-4z"/><path d="M3 7v10l9 4 9-4V7"/><path d="M12 11v10"/>',
    team: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.8-3.6 3.4-5.5 6.5-5.5s5.7 1.9 6.5 5.5"/><path d="M16 4.6a3.5 3.5 0 010 6.8"/><path d="M18 14.8c1.8.8 3 2.5 3.5 5.2"/>',
    locations: '<path d="M12 21s-7-6.2-7-11.5A7 7 0 0119 9.5C19 14.8 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9a1.7 1.7 0 001.5 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z"/>',
  };
  // Hasta las fases B y D, Productos, Inventario y Ventas abren las
  // pantallas existentes.
  const NAV = [
    { key: "today", href: "/index.html", label: T("Today"), roles: null },
    { key: "sales", href: "/dashboard.html", label: T("Sales"), roles: ["owner", "admin", "manager"] },
    { key: "products", href: "/insumos.html#productos", label: T("Products"), roles: ["owner", "admin", "manager"] },
    { key: "inventory", href: "/insumos.html#insumos", label: T("Inventory"), roles: ["owner", "admin", "manager"] },
    { key: "team", href: "/equipo.html", label: T("Team"), roles: ["owner", "admin"] },
    { key: "locations", href: "/locales.html", label: T("Locations and registers"), roles: ["owner", "admin"] },
    { key: "settings", href: "/ajustes.html", label: T("Settings"), roles: ["owner", "admin"] },
  ];
  const icon = (k) => '<svg viewBox="0 0 24 24" aria-hidden="true">' + ICONS[k] + "</svg>";

  function build() {
    const main = document.querySelector("main.main-inner");
    if (!main) return;
    const office = document.createElement("div");
    office.className = "office";
    office.innerHTML =
      '<aside class="side" id="office-side" aria-label="Menu">' +
        '<div class="side-brand"><span class="mark" id="office-mark">·</span><span class="name" id="office-org"></span></div>' +
        '<nav class="side-nav">' + NAV.map((n) =>
          '<a href="' + n.href + '" data-key="' + n.key + '"' + (n.key === active ? ' aria-current="page"' : "") + (n.roles ? " hidden" : "") + ">" +
          icon(n.key) + '<span class="nav-label"></span></a>').join("") + "</nav>" +
        '<div class="side-action"><button class="btn btn-primary btn-block" id="office-open-register" type="button" data-i18n>Open a register</button></div>' +
        '<div class="side-foot"><span class="who" id="office-who"></span>' +
          '<div class="row"><span id="office-lang"></span><button class="link" id="office-logout" type="button" data-i18n>Sign out</button></div></div>' +
      "</aside>" +
      '<div class="main">' +
        '<div class="topbar"><button type="button" id="office-menu" aria-label="Menu"><svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg></button>' +
          '<span class="name" id="office-org-top"></span></div>' +
        '<div id="office-banner"></div>' +
      "</div>";
    main.parentNode.insertBefore(office, main);
    office.querySelector(".main").appendChild(main);

    const toast = document.createElement("div");
    toast.className = "toast"; toast.id = "office-toast"; toast.setAttribute("role", "status");
    document.body.appendChild(toast);

    const dlg = document.createElement("dialog");
    dlg.className = "dialog"; dlg.id = "office-register-dialog";
    dlg.innerHTML = '<div class="dialog-body"><div><h2 data-i18n>Open a register</h2><p class="muted" data-i18n>Choose where you are selling. This device remembers your choice.</p></div>' +
      '<div class="list" id="office-register-list"></div>' +
      '<div class="dialog-actions"><button class="btn" type="button" id="office-register-close" data-i18n>Cancel</button></div></div>';
    document.body.appendChild(dlg);

    document.getElementById("office-menu").onclick = () => office.classList.toggle("nav-open");
    office.addEventListener("click", (e) => { if (e.target === office) office.classList.remove("nav-open"); });
    document.getElementById("office-register-close").onclick = () => dlg.close();
    document.getElementById("office-open-register").onclick = openRegisterDialog;
  }

  async function openRegisterDialog() {
    const dlg = document.getElementById("office-register-dialog");
    const list = document.getElementById("office-register-list");
    list.innerHTML = '<p class="muted">' + E(t("Loading…")) + "</p>";
    dlg.showModal();
    const [{ data: regs }, { data: locs }] = await Promise.all([
      core.sb.from("registers").select("id, name, type, location_id, active").eq("org_id", core.orgId).eq("active", true).order("created_at"),
      core.sb.from("locations").select("id, name").eq("org_id", core.orgId).order("created_at"),
    ]);
    if (!regs || !regs.length) {
      list.innerHTML = '<div class="empty"><b>' + E(t("No registers yet")) + "</b><span>" +
        E(t("Create your first register in Locations and registers.")) + "</span>" +
        (core.isAdmin() ? '<a class="btn" href="/locales.html">' + E(t("Go to Locations and registers")) + "</a>" : "") + "</div>";
      return;
    }
    const locName = Object.fromEntries((locs || []).map((l) => [l.id, l.name]));
    list.innerHTML = regs.map((r) =>
      '<div class="list-item"><div class="grow"><b>' + E(r.name) + '</b><div class="muted">' + E(locName[r.location_id] || "") + " · " +
        E(core.label("register", r.type)) + "</div></div>" +
        '<button class="btn btn-sm btn-primary" type="button" data-id="' + E(r.id) + '" data-type="' + E(r.type) + '">' + E(t("Open")) + "</button>" +
        (r.type === "product" ? '<button class="btn btn-sm" type="button" data-id="' + E(r.id) + '" data-type="delivery">' + E(t("Delivery")) + "</button>" : "") +
      "</div>").join("");
    list.querySelectorAll("button[data-id]").forEach((b) => b.onclick = () => {
      const kind = b.dataset.type;
      try { localStorage.setItem("pos_register_" + (kind === "delivery" ? "product" : kind), b.dataset.id); } catch (_) { /* sin storage */ }
      location.href = kind === "ticket" ? "/pos-tickets.html" : kind === "delivery" ? "/despacho.html" : "/pos-productos.html";
    });
  }

  function fill() {
    // Por si pos-core tradujo la página antes de que existiera el menú.
    posI18n.translateDom(document.getElementById("office-side"));
    posI18n.translateDom(document.getElementById("office-register-dialog"));
    const org = core.org || {};
    document.getElementById("office-org-top").textContent = org.name || "";
    document.getElementById("office-mark").textContent = (org.name || "·").trim().charAt(0).toUpperCase();
    const orgSlot = document.getElementById("office-org");
    if (core.memberships.length > 1) {
      orgSlot.innerHTML = '<select aria-label="' + E(t("Organisation")) + '">' + core.memberships.map((m) =>
        '<option value="' + E(m.org_id) + '"' + (m.org_id === core.orgId ? " selected" : "") + ">" + E(m.organizations.name) + "</option>").join("") + "</select>";
      orgSlot.querySelector("select").onchange = (e) => core.switchOrg(e.target.value);
    } else orgSlot.textContent = org.name || "";
    document.getElementById("office-who").textContent = core.user.email + " · " + core.label("role", core.role);
    document.getElementById("office-lang").innerHTML = core.langSelect();
    document.querySelector("#office-lang select").onchange = (e) => core.setLang(e.target.value);
    document.getElementById("office-logout").onclick = () => core.logout();
    document.querySelectorAll(".side-nav a").forEach((a) => {
      const item = NAV.find((n) => n.key === a.dataset.key);
      a.hidden = !!(item.roles && !item.roles.includes(core.role));
      a.querySelector(".nav-label").textContent = t(item.label);
    });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", build);
  else build();
  core.ready.then(fill);

  let toastTimer = null;
  window.posOffice = {
    openRegisterDialog,
    toast(text) {
      const el = document.getElementById("office-toast");
      el.textContent = text; el.classList.add("show");
      clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove("show"), 2800);
    },
    // Si el rol no alcanza, reemplaza el contenido por un aviso y devuelve false.
    require(roles) {
      if (roles.includes(core.role)) return true;
      document.querySelector("main.main-inner").innerHTML = '<div class="panel"><div class="empty"><b>' +
        E(t("You don't have access to this section")) + "</b><span>" + E(t("Ask an owner or admin of the business.")) + "</span></div></div>";
      return false;
    },
  };
})();

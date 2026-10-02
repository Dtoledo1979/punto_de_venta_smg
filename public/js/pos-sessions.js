// Sesión de caja en las pantallas de venta: barra con el estado, abrir con
// fondo inicial, entradas/salidas de efectivo, cierre con arqueo y reporte Z.
//
//   posSessions.mount(el, { registerId, pin, operator, print, onChange })
//   posSessions.isOpen()   → para avisar antes de cobrar (el servidor igual lo exige)
//
// El cierre es "a ciegas": se pide contar el efectivo ANTES de mostrar lo
// esperado, para que el conteo no se acomode al número del sistema.
(function () {
  "use strict";
  const E = (s) => posCore.esc(s);
  const M = (n) => posCore.money(n);
  let state = { session: null, opts: null, el: null };

  const style = document.createElement("style");
  style.textContent =
    ".pos-session{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:8px 12px;margin:12px 18px 0;color:var(--ink);font-size:13.5px}" +
    ".pos-session.closed{background:var(--warn-soft);border-color:transparent}" +
    ".pos-session .acts{display:flex;gap:6px;flex-wrap:wrap}" +
    ".pos-session button{border:1px solid var(--line);background:var(--surface);color:var(--ink);border-radius:8px;padding:8px 12px;font-size:13px;cursor:pointer;min-height:38px;font-family:inherit}" +
    ".pos-session button.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-ink);font-weight:700}" +
    "@media (min-width:1140px){.pos-session{max-width:1064px;margin-left:auto;margin-right:auto}}" +
    "#session-overlay{position:fixed;inset:0;background:rgba(10,15,13,.45);display:flex;align-items:center;justify-content:center;z-index:10002;padding:16px}" +
    "#session-overlay .box{background:var(--surface);color:var(--ink);border-radius:14px;padding:20px;max-width:420px;width:100%;max-height:92vh;overflow:auto;font-family:var(--f-body)}" +
    "#session-overlay h3{font-family:var(--f-display);margin:0 0 6px;font-size:17px}" +
    "#session-overlay p{font-size:13px;color:var(--muted);margin:0 0 10px}" +
    "#session-overlay input,#session-overlay select{width:100%;padding:11px;font-size:17px;border:1px solid var(--line-strong);background:var(--surface);color:var(--ink);border-radius:9px;margin-bottom:8px;font-family:inherit}" +
    "#session-overlay table{width:100%;border-collapse:collapse;font-size:13.5px;margin:6px 0}" +
    "#session-overlay td{padding:5px 2px;border-bottom:1px solid var(--line)}#session-overlay td:last-child{text-align:right;font-variant-numeric:tabular-nums}" +
    "#session-overlay .var{font-family:var(--f-display);font-weight:800;font-size:20px;margin:8px 0}" +
    "#session-overlay .row{display:flex;gap:8px;margin-top:10px}#session-overlay .row button{flex:1;min-height:46px;border:0;border-radius:10px;font-size:15px;font-weight:600;cursor:pointer}" +
    "#session-overlay .cancel{background:var(--sunken);color:var(--ink)}#session-overlay .ok{background:var(--accent);color:var(--accent-ink)}";
  document.head.appendChild(style);

  function overlay(html) {
    const el = document.createElement("div");
    el.id = "session-overlay";
    el.innerHTML = '<div class="box" role="dialog" aria-modal="true">' + html + "</div>";
    document.body.appendChild(el);
    return el;
  }
  const readAmount = (v) => { const n = Number(v); return v !== "" && Number.isFinite(n) && n >= 0 ? posUtils.roundMoney(n) : null; };
  const toast = (msg) => (state.opts.toast || alert)(msg);
  const fail = (prefix, err) => toast(t(prefix) + ": " + posCore.errorText(err));

  async function refresh() {
    const { data, error } = await posCore.sb.rpc("get_open_session", { p_register_id: state.opts.registerId });
    if (error) { state.el.innerHTML = '<div class="pos-session closed">' + E(posCore.errorText(error)) + "</div>"; return; }
    state.session = data;
    render();
    state.opts.onChange && state.opts.onChange(data);
  }

  function render() {
    const s = state.session;
    if (!s) {
      state.el.innerHTML = '<div class="pos-session closed"><span>' + E(t("🔒 Register closed — open it to start selling (test mode works without it).")) + '</span>' +
        '<div class="acts"><button class="primary" data-a="open">' + E(t("Open register")) + "</button></div></div>";
    } else {
      state.el.innerHTML = '<div class="pos-session"><span>' + E(t("🟢 Open since {time} · float {float} · cash expected {expected}", {
        time: posCore.fmtTime(s.opened_at), float: M(s.opening_float), expected: M(s.live.expected_cash) })) + "</span>" +
        '<div class="acts"><button data-a="move">' + E(t("Cash in / out")) + '</button><button data-a="close">' + E(t("Close register")) + "</button></div></div>";
    }
    state.el.querySelectorAll("button[data-a]").forEach((b) => {
      b.onclick = () => ({ open: openDialog, move: moveDialog, close: closeDialog })[b.dataset.a]();
    });
  }

  function openDialog() {
    const el = overlay("<h3>" + E(t("Open register")) + "</h3><p>" + E(t("Count the cash in the drawer before you start (the float).")) + "</p>" +
      '<input type="number" min="0" step="0.01" inputmode="decimal" class="f" placeholder="$0.00">' +
      '<div class="row"><button class="cancel">' + E(t("Cancel")) + '</button><button class="ok">' + E(t("Open register")) + "</button></div>");
    el.querySelector(".cancel").onclick = () => el.remove();
    el.querySelector(".ok").onclick = async () => {
      const amount = readAmount(el.querySelector(".f").value);
      if (amount === null) { toast(t("Enter a valid amount.")); return; }
      const { error } = await posCore.sb.rpc("open_register_session", { p_register_id: state.opts.registerId, p_pin: state.opts.pin(), p_opening_float: amount, p_by: state.opts.operator() });
      if (error) { fail("Could not open the register", error); return; }
      el.remove(); toast(t("Register open with a float of {amount}.", { amount: M(amount) })); refresh();
    };
    el.querySelector(".f").focus();
  }

  function moveDialog() {
    const el = overlay("<h3>" + E(t("Cash in / out")) + "</h3><p>" + E(t("Cash that goes into or out of the drawer without a sale (float top-up, paying a supplier, bank drop).")) + "</p>" +
      '<select class="ty"><option value="cash_out">' + E(t("Cash out")) + '</option><option value="cash_in">' + E(t("Cash in")) + "</option></select>" +
      '<input type="number" min="0" step="0.01" inputmode="decimal" class="f" placeholder="$0.00">' +
      '<input type="text" class="rs" placeholder="' + E(t("Reason (required)")) + '">' +
      '<div class="row"><button class="cancel">' + E(t("Cancel")) + '</button><button class="ok">' + E(t("Save")) + "</button></div>");
    el.querySelector(".cancel").onclick = () => el.remove();
    el.querySelector(".ok").onclick = async () => {
      const amount = readAmount(el.querySelector(".f").value);
      const reason = el.querySelector(".rs").value.trim();
      if (!(amount > 0)) { toast(t("Enter a valid amount.")); return; }
      if (!reason) { toast(t("Write the reason.")); return; }
      const { error } = await posCore.sb.rpc("record_cash_movement", { p_register_id: state.opts.registerId, p_pin: state.opts.pin(),
        p_type: el.querySelector(".ty").value, p_amount: amount, p_reason: reason, p_by: state.opts.operator() });
      if (error) { fail("Could not record the cash movement", error); return; }
      el.remove(); toast(t("Cash movement recorded.")); refresh();
    };
  }

  function closeDialog(force) {
    const el = overlay("<h3>" + E(t("Close register")) + "</h3><p>" + E(t("Count all the cash in the drawer and enter the total. The expected amount is shown after you count.")) + "</p>" +
      '<input type="number" min="0" step="0.01" inputmode="decimal" class="f" placeholder="$0.00">' +
      '<input type="text" class="nt" placeholder="' + E(t("Note (optional)")) + '">' +
      '<div class="row"><button class="cancel">' + E(t("Cancel")) + '</button><button class="ok">' + E(t("Close register")) + "</button></div>");
    el.querySelector(".cancel").onclick = () => el.remove();
    el.querySelector(".ok").onclick = async () => {
      const counted = readAmount(el.querySelector(".f").value);
      if (counted === null) { toast(t("Enter a valid amount.")); return; }
      let res = await posCore.sb.rpc("close_register_session", { p_register_id: state.opts.registerId, p_pin: state.opts.pin(),
        p_counted_cash: counted, p_note: el.querySelector(".nt").value.trim() || null, p_by: state.opts.operator(), p_force: !!force });
      if (res.error && res.error.message === "session.pending_orders") {
        let n = "?"; try { n = JSON.parse(res.error.details).n; } catch (_) { /* sin detalle */ }
        if (!confirm(t("{n} orders are still waiting for delivery. Close the register anyway?", { n }))) return;
        res = await posCore.sb.rpc("close_register_session", { p_register_id: state.opts.registerId, p_pin: state.opts.pin(),
          p_counted_cash: counted, p_note: el.querySelector(".nt").value.trim() || null, p_by: state.opts.operator(), p_force: true });
      }
      if (res.error) { fail("Could not close the register", res.error); return; }
      el.remove();
      showZ(res.data);
      refresh();
    };
    el.querySelector(".f").focus();
  }

  // Reporte Z: en pantalla y para imprimir (idioma de la organización).
  function zRows(s, lang) {
    const T = (x) => t(x, null, lang), tot = s.totals;
    return [
      [T("Opening float"), M(s.opening_float)],
      [T("Cash sales"), M(tot.cash_sales)], [T("Cash refunds"), "−" + M(tot.cash_refunds)],
      [T("Cash in"), M(tot.cash_in)], [T("Cash out"), "−" + M(tot.cash_out)],
      [T("Expected cash"), M(s.expected_cash)], [T("Counted cash"), M(s.counted_cash)],
      [T("Difference"), (s.cash_variance > 0 ? "+" : "") + M(s.cash_variance)],
      ["—", ""],
      [T("Card sales"), M(tot.card_sales)], [T("Card refunds"), "−" + M(tot.card_refunds)],
      [T("Gross sales"), M(tot.gross_sales)], [T("Refunds"), "−" + M(tot.refunds_total)], [T("Net sales"), M(tot.net_sales)],
      [t("{tax} included", { tax: posCore.org.tax_name || "GST" }, lang), M(tot.tax_net)],
      [T("Sales"), String(tot.orders)], [T("Voided"), String(tot.voided_orders)],
      [T("Complimentary"), tot.complimentary + " (" + M(tot.complimentary_value) + ")"],
      [T("Declined card attempts"), String(tot.declined_card_attempts)],
    ];
  }

  function zHtml(s, lang) {
    const T = (x, p) => E(t(x, p, lang));
    return '<div class="receipt-copy"><h3>' + E(posCore.org.name) + "</h3><h4>" + T("Z REPORT") + "</h4>" +
      '<div class="line"><span class="iname">' + T("Opened") + '</span><span class="iprice">' + posCore.fmtDayTime(s.opened_at) + "</span></div>" +
      '<div class="line"><span class="iname">' + T("Closed") + '</span><span class="iprice">' + posCore.fmtDayTime(s.closed_at) + "</span></div>" +
      (s.closed_by_name ? '<div class="line"><span class="iname">' + T("Closed by") + '</span><span class="iprice">' + E(s.closed_by_name) + "</span></div>" : "") + "<hr>" +
      zRows(s, lang).map(([a, b]) => a === "—" ? "<hr>" : '<div class="line"><span class="iname">' + E(a) + '</span><span class="iprice">' + E(b) + "</span></div>").join("") +
      (s.close_note ? '<hr><div class="obs">' + E(s.close_note) + "</div>" : "") + "</div>";
  }

  function showZ(s) {
    const v = Number(s.cash_variance);
    const el = overlay("<h3>" + E(t("Register closed")) + '</h3><div class="var" style="color:' + (v === 0 ? "var(--ok)" : "var(--bad)") + '">' +
      E(v === 0 ? t("Cash matches exactly.") : t("Difference: {amount}", { amount: (v > 0 ? "+" : "") + M(v) })) + "</div>" +
      "<table>" + zRows(s).map(([a, b]) => a === "—" ? '<tr><td colspan="2"></td></tr>' : "<tr><td>" + E(a) + "</td><td>" + E(b) + "</td></tr>").join("") + "</table>" +
      '<div class="row"><button class="cancel">' + E(t("Done")) + '</button><button class="ok">' + E(t("Print Z report")) + "</button></div>");
    el.querySelector(".cancel").onclick = () => el.remove();
    el.querySelector(".ok").onclick = () => { state.opts.print && state.opts.print(zHtml(s, posCore.receiptLang())); };
  }

  window.posSessions = {
    mount(el, opts) { state = { session: null, opts, el }; return refresh(); },
    refresh,
    isOpen() { return !!state.session; },
    zHtml,
  };
})();

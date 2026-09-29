// Reembolsos desde las cajas (productos y tickets). Ventana con las líneas
// del pedido, cuánto queda por reembolsar de cada una, medio, motivo,
// devolución de stock y PIN de supervisor. El monto final lo calcula el
// servidor (refund_order); acá solo se muestra una estimación.
//
//   posRefunds.open(order, { registerId, pin, operator, onDone })
(function () {
  "use strict";
  const REASONS = ["wrong_item", "quality", "changed_mind", "overcharged", "other"];

  const style = document.createElement("style");
  style.textContent =
    "#refund-overlay{position:fixed;inset:0;background:rgba(10,13,18,.6);display:flex;align-items:center;justify-content:center;z-index:10002;padding:16px}" +
    "#refund-overlay .rf{background:#fff;border-radius:14px;padding:20px;max-width:440px;width:100%;max-height:92vh;overflow:auto;font-family:Inter,Arial,sans-serif;color:#12161C}" +
    "#refund-overlay h3{font-family:Sora,sans-serif;margin:0 0 4px;font-size:17px}" +
    "#refund-overlay .sub{font-size:13px;color:#62707D;margin:0 0 12px}" +
    "#refund-overlay .ln{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:8px 0;border-bottom:1px solid #E2E6EA;font-size:14px}" +
    "#refund-overlay .ln input{width:64px;padding:8px;font-size:16px;border:1px solid #E2E6EA;border-radius:8px;text-align:center}" +
    "#refund-overlay .ln small{color:#62707D;display:block}" +
    "#refund-overlay label.f{display:block;font-size:12.5px;color:#62707D;margin:10px 0 4px}" +
    "#refund-overlay select,#refund-overlay .full{width:100%;padding:10px;font-size:15px;border:1px solid #E2E6EA;border-radius:8px;font-family:inherit}" +
    "#refund-overlay .chk{display:flex;gap:8px;align-items:center;font-size:13.5px;margin-top:10px}" +
    "#refund-overlay .est{font-family:Sora,sans-serif;font-weight:800;font-size:22px;margin:12px 0 4px}" +
    "#refund-overlay .row{display:flex;gap:8px;margin-top:14px}" +
    "#refund-overlay .row button{flex:1;min-height:46px;border:0;border-radius:10px;font-size:15px;font-weight:600;cursor:pointer}" +
    "#refund-overlay .cancel{background:#F4F6F8;border:1px solid #E2E6EA!important}" +
    "#refund-overlay .ok{background:#E4483A;color:#fff}" +
    "#refund-overlay .ok:disabled{opacity:.5}";
  document.head.appendChild(style);

  const E = (s) => posCore.esc(s);

  async function open(order, opts) {
    const { data: prev, error } = await posCore.sb.from("refunds").select("amount, method, lines").eq("order_id", order.id);
    if (error) { opts.onError && opts.onError(error); return; }

    // Lo que ya se reembolsó, por línea y por medio de pago.
    const doneQty = {}, doneAmt = {};
    const byMethod = { cash: 0, card: 0 };
    (prev || []).forEach((r) => {
      byMethod[r.method] = posUtils.sumMoney([byMethod[r.method], r.amount]);
      (r.lines || []).forEach((l) => {
        doneQty[l.index] = (doneQty[l.index] || 0) + Number(l.qty);
        doneAmt[l.index] = posUtils.sumMoney([doneAmt[l.index] || 0, l.amount]);
      });
    });
    const available = {
      cash: posUtils.sumMoney([order.cash_amount, -byMethod.cash]),
      card: posUtils.sumMoney([order.card_amount, -byMethod.card]),
    };
    const lines = order.items.map((it, i) => ({ index: i, name: it.name, qty: Number(it.qty), subtotal: Number(it.subtotal), left: Number(it.qty) - (doneQty[i] || 0), doneAmt: doneAmt[i] || 0 }));
    const defaultMethod = available.card > available.cash ? "card" : "cash";

    const el = document.createElement("div");
    el.id = "refund-overlay";
    el.innerHTML = '<div class="rf" role="dialog" aria-modal="true">' +
      "<h3>" + E(t("Refund ticket #{n}", { n: order.ticket_num })) + "</h3>" +
      '<p class="sub">' + E(t("Choose what to refund. The customer gets the money back; the sale stays on record.")) + "</p>" +
      lines.map((l) => '<div class="ln"><div>' + E(l.qty + "x " + l.name) + "<small>" +
        E(l.left > 0 ? t("{n} can still be refunded", { n: l.left }) : t("Already fully refunded")) + "</small></div>" +
        '<input type="number" min="0" step="1" inputmode="numeric" value="0" max="' + l.left + '" data-index="' + l.index + '"' + (l.left > 0 ? "" : " disabled") + "></div>").join("") +
      '<label class="f">' + E(t("Refund method")) + '</label><select class="rf-method">' +
        ["cash", "card"].map((m) => '<option value="' + m + '"' + (m === defaultMethod ? " selected" : "") + (available[m] > 0 ? "" : " disabled") + ">" +
          E(posCore.label("payment", m) + " — " + t("up to {amount}", { amount: posCore.money(available[m]) })) + "</option>").join("") + "</select>" +
      '<label class="f">' + E(t("Reason")) + '</label><select class="rf-reason">' +
        REASONS.map((r) => '<option value="' + r + '">' + E(posCore.label("reason", r)) + "</option>").join("") + "</select>" +
      '<label class="f">' + E(t("Note (optional)")) + '</label><input type="text" class="full rf-note">' +
      '<label class="chk"><input type="checkbox" class="rf-restock"> ' + E(t("Put the items back in stock (only if they weren't used)")) + "</label>" +
      '<div class="est rf-est"></div>' +
      '<label class="f">' + E(t("Supervisor PIN")) + '</label><input type="password" inputmode="numeric" maxlength="8" class="full rf-pin">' +
      '<div class="row"><button class="cancel rf-cancel">' + E(t("Cancel")) + '</button><button class="ok rf-ok">' + E(t("Refund")) + "</button></div>" +
      "</div>";
    document.body.appendChild(el);

    const q = (s) => el.querySelector(s);
    function chosen() {
      return [...el.querySelectorAll("input[data-index]")].map((inp) => {
        const l = lines[Number(inp.dataset.index)];
        const n = Math.max(0, Math.min(l.left, Math.trunc(Number(inp.value) || 0)));
        return { l, n };
      }).filter((x) => x.n > 0);
    }
    // Estimación con la misma regla que el servidor: proporcional, y la
    // última unidad se lleva el resto.
    function estimate() {
      return posUtils.sumMoney(chosen().map(({ l, n }) =>
        n === l.left ? posUtils.sumMoney([l.subtotal, -l.doneAmt]) : posUtils.roundMoney(l.subtotal * n / l.qty)));
    }
    function refresh() {
      const est = estimate();
      q(".rf-est").textContent = est > 0 ? t("To refund: {amount}", { amount: posCore.money(est) }) : "";
      q(".rf-ok").disabled = !(est > 0);
    }
    el.addEventListener("input", refresh);
    refresh();

    const close = () => el.remove();
    q(".rf-cancel").onclick = close;
    let txId = crypto.randomUUID(); // un id por intento: un doble toque no duplica el reembolso
    q(".rf-ok").onclick = async () => {
      const sel = chosen();
      if (!sel.length) return;
      const method = q(".rf-method").value;
      const est = estimate();
      if (est > available[method]) { opts.onError && opts.onError({ message: "refund.exceeds_method", details: JSON.stringify({ method, amount: available[method] }) }); return; }
      q(".rf-ok").disabled = true;
      const { data, error: err } = await posCore.sb.rpc("refund_order", {
        p_register_id: opts.registerId, p_pin: opts.pin, p_order_id: order.id,
        p_lines: sel.map(({ l, n }) => ({ index: l.index, qty: n })),
        p_method: method, p_reason: q(".rf-reason").value, p_supervisor_pin: q(".rf-pin").value,
        p_restock: q(".rf-restock").checked, p_note: q(".rf-note").value.trim() || null,
        p_operator: opts.operator || null, p_client_transaction_id: txId,
      });
      if (err || !data) {
        q(".rf-ok").disabled = false;
        opts.onError && opts.onError(err || { message: "pin.incorrect" });
        return;
      }
      close();
      opts.onDone && opts.onDone(data);
    };
    q(".rf-pin").focus();
  }

  window.posRefunds = { open, REASONS };
})();

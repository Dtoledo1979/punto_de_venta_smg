-- =====================================================================
-- Fase B (3/3) — Vender con el catálogo del negocio.
--
-- create_order:
--   * productos del negocio disponibles en el local de la caja, con su
--     precio del local; no se vende lo agotado;
--   * opciones (Tamaño, Leche, Sabores…) validadas contra el producto,
--     con mínimos/máximos; el precio de cada opción lo pone el servidor;
--   * nota por línea ("sin cebolla");
--   * para servir / para llevar / delivery y mesa;
--   * evento opcional: los negocios sin eventos numeran por caja y día;
--   * consumo de insumos: receta del producto + receta de cada opción,
--     guardado por línea (devolver una línea repone exactamente eso);
--   * stock por LOCAL (dos cajas del mismo local comparten stock).
-- Anular, reabrir y devolver usan el stock del local.
-- Se eliminan las tablas y funciones del catálogo por caja.
-- =====================================================================

-- Pedidos: tipo y mesa también son inmutables.
create or replace function pos._orders_guard() returns trigger
language plpgsql as $$
declare v_old_lines jsonb; v_new_lines jsonb;
begin
  if new.org_id <> old.org_id or new.register_id <> old.register_id or new.event_id is distinct from old.event_id
     or new.ticket_num <> old.ticket_num or new.total <> old.total or new.payment_method <> old.payment_method
     or new.cash_amount <> old.cash_amount or new.card_amount <> old.card_amount or new.is_test <> old.is_test
     or new.paid_at <> old.paid_at or new.client_transaction_id is distinct from old.client_transaction_id
     or new.ingredient_consumption is distinct from old.ingredient_consumption
     or new.tax_rate <> old.tax_rate or new.tax_amount <> old.tax_amount or new.session_id is distinct from old.session_id
     or new.order_type is distinct from old.order_type or new.table_label is distinct from old.table_label then
    raise exception 'order.immutable';
  end if;
  select coalesce(jsonb_agg(e - 'delivered' order by ord), '[]') into v_old_lines from jsonb_array_elements(old.items) with ordinality x(e, ord);
  select coalesce(jsonb_agg(e - 'delivered' order by ord), '[]') into v_new_lines from jsonb_array_elements(new.items) with ordinality x(e, ord);
  if v_old_lines <> v_new_lines then raise exception 'order.immutable'; end if;
  if new.refunded_total < old.refunded_total then raise exception 'order.immutable'; end if;
  if new.status <> old.status then
    if not ((old.status, new.status) in (
         ('pending_delivery','delivered'), ('pending_delivery','voided'),
         ('delivered','voided'), ('delivered','pending_delivery'), ('voided','pending_delivery'))) then
      raise exception 'order.invalid_transition' using detail = json_build_object('from', old.status, 'to', new.status)::text;
    end if;
    if new.status = 'voided' and new.refunded_total > 0 then raise exception 'order.has_refunds'; end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Stock de un pedido (vender = −1, anular = +1, reabrir = −1).
-- Productos con control de stock + consumo de insumos guardado en la
-- venta. Acepta el formato anterior (ingredient_id) y el nuevo
-- (stock_item_id): los ids se conservaron en la migración.
-- ---------------------------------------------------------------------
create or replace function pos._apply_order_stock(p_order pos.orders, p_sign int, p_type text) returns void
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_item jsonb; v_loc uuid; v_target uuid;
begin
  select location_id into v_loc from pos.registers where id = p_order.register_id;
  for v_item in select * from jsonb_array_elements(p_order.items) loop
    if v_item ? 'id' and exists (select 1 from pos.products where id = (v_item->>'id')::uuid and org_id = p_order.org_id and track_stock) then
      perform pos._stock_change(p_order.org_id, v_loc, (v_item->>'id')::uuid, null, coalesce((v_item->>'qty')::numeric, 0) * p_sign, p_type,
                                p_register_id => p_order.register_id, p_order_id => p_order.id, p_event_id => p_order.event_id);
    end if;
  end loop;
  for v_item in select * from jsonb_array_elements(coalesce(p_order.ingredient_consumption, '[]'::jsonb)) loop
    v_target := coalesce(v_item->>'stock_item_id', v_item->>'ingredient_id')::uuid;
    if exists (select 1 from pos.stock_items where id = v_target and org_id = p_order.org_id) then
      perform pos._stock_change(p_order.org_id, v_loc, null, v_target, (v_item->>'qty')::numeric * p_sign, p_type,
                                p_register_id => p_order.register_id, p_order_id => p_order.id, p_event_id => p_order.event_id);
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- create_order (catálogo del negocio)
--   p_items = [{"id": producto, "qty": 2, "modifiers": [uuid, ...], "note": "sin azúcar"}, ...]
-- ---------------------------------------------------------------------
drop function pos.create_order(uuid, text, uuid, jsonb, text, numeric, numeric, text, text, text, text, boolean, uuid);
create function pos.create_order(
  p_register_id uuid, p_pin text, p_event_id uuid, p_items jsonb,
  p_payment_method text, p_cash numeric, p_card numeric,
  p_customer_name text, p_obs text, p_attended_by text,
  p_supervisor_pin text default null, p_is_test boolean default false,
  p_client_transaction_id uuid default null,
  p_order_type text default null, p_table text default null
) returns pos.orders
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_reg pos.registers;
  v_org pos.organizations;
  v_order pos.orders;
  v_elem jsonb; v_line record; v_mod record; v_grp record;
  v_prod record;
  v_mods uuid[]; v_mod_json jsonb; v_unit numeric; v_count int;
  v_lines jsonb := '[]'::jsonb;      -- líneas ya resueltas, en orden
  v_items jsonb := '[]'::jsonb;      -- foto final de la venta
  v_consumption jsonb := '[]'::jsonb;
  v_total numeric := 0; v_tax numeric; v_ticket_num int; v_status text; v_delivered_at timestamptz;
  v_session uuid; v_idx int; v_qty numeric; v_note text;
  v_line_disc numeric; v_line_gross numeric;
  v_max_qty_per_line constant numeric := 500;
begin
  -- Autorización primero (antes de mirar la idempotencia).
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_attended_by, ''), true);
  select * into v_org from pos.organizations where id = v_reg.org_id;

  if p_client_transaction_id is not null then
    select * into v_order from pos.orders where client_transaction_id = p_client_transaction_id and register_id = v_reg.id;
    if v_order.id is not null then return v_order; end if;
  end if;

  if not coalesce(p_is_test, false) then
    select id into v_session from pos.register_sessions where register_id = v_reg.id and status = 'open';
    if v_session is null then raise exception 'session.not_open'; end if;
  end if;

  if p_payment_method not in ('cash','card','split','complimentary') then raise exception 'payment.invalid_method'; end if;
  if p_payment_method = 'complimentary' and not pos._check_supervisor_pin(v_reg.org_id, p_supervisor_pin) then return null; end if;
  if coalesce(p_cash, 0) < 0 or coalesce(p_card, 0) < 0 then raise exception 'payment.negative_amount'; end if;
  if (p_payment_method = 'cash' and coalesce(p_card, 0) <> 0)
     or (p_payment_method = 'card' and coalesce(p_cash, 0) <> 0)
     or (p_payment_method = 'split' and (coalesce(p_cash, 0) <= 0 or coalesce(p_card, 0) <= 0))
     or (p_payment_method = 'complimentary' and (coalesce(p_cash, 0) <> 0 or coalesce(p_card, 0) <> 0)) then
    raise exception 'payment.amounts_mismatch_method' using detail = json_build_object('method', p_payment_method)::text;
  end if;
  if p_order_type is not null and p_order_type not in ('here','takeaway','delivery') then raise exception 'order.invalid_type'; end if;
  if p_table is not null and length(trim(p_table)) > 20 then raise exception 'validation.too_long'; end if;
  if p_event_id is not null and not exists (select 1 from pos.events where id = p_event_id and org_id = v_reg.org_id) then
    raise exception 'event.not_found';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'order.no_items'; end if;

  -- 1) Resolver cada línea: producto del local, opciones y precio del servidor.
  create temp table if not exists _order_lines (
    ord int, product_id uuid, name text, station text, base_price numeric, unit_price numeric,
    qty numeric, mods uuid[], mods_json jsonb, note text, track boolean
  ) on commit drop;
  truncate _order_lines;
  v_idx := 0;
  for v_elem in select * from jsonb_array_elements(p_items) loop
    v_idx := v_idx + 1;
    if not (v_elem ? 'id') then raise exception 'order.no_items'; end if;
    v_qty := coalesce((v_elem->>'qty')::numeric, 0);
    if v_qty <= 0 then raise exception 'order.invalid_qty'; end if;
    if v_qty <> trunc(v_qty) then raise exception 'order.qty_not_integer'; end if;
    if v_qty > v_max_qty_per_line then raise exception 'order.qty_too_large' using detail = json_build_object('max', v_max_qty_per_line)::text; end if;
    v_note := nullif(left(trim(coalesce(v_elem->>'note', '')), 80), '');

    select p.id, p.name, p.station, p.track_stock, coalesce(pl.price, p.price) as price,
           coalesce(pl.available, true) as available, coalesce(pl.sold_out, false) as sold_out
      into v_prod
      from pos.products p left join pos.product_locations pl on pl.product_id = p.id and pl.location_id = v_reg.location_id
      where p.id = (v_elem->>'id')::uuid and p.org_id = v_reg.org_id and p.active and p.kind = v_reg.type;
    if v_prod.id is null or not v_prod.available then
      raise exception 'product.not_found' using detail = json_build_object('id', v_elem->>'id')::text;
    end if;
    if v_prod.sold_out then raise exception 'product.sold_out' using detail = json_build_object('name', v_prod.name)::text; end if;

    -- Opciones: únicas, de grupos del producto, dentro de los límites.
    select coalesce(array_agg(distinct x::uuid order by x::uuid), '{}') into v_mods
      from jsonb_array_elements_text(coalesce(v_elem->'modifiers', '[]'::jsonb)) x;
    if exists (select 1 from unnest(v_mods) m(id)
               where not exists (select 1 from pos.modifiers mo join pos.product_modifier_groups pmg on pmg.group_id = mo.group_id
                                 join pos.modifier_groups g on g.id = mo.group_id and g.active
                                 where mo.id = m.id and mo.active and pmg.product_id = v_prod.id)) then
      raise exception 'modifier.not_found';
    end if;
    for v_grp in
      select g.id, g.name, g.min_select, g.max_select,
             (select count(*) from pos.modifiers mo where mo.group_id = g.id and mo.id = any (v_mods)) as chosen
      from pos.product_modifier_groups pmg join pos.modifier_groups g on g.id = pmg.group_id and g.active
      where pmg.product_id = v_prod.id
    loop
      if v_grp.chosen < v_grp.min_select then
        raise exception 'modifier.required' using detail = json_build_object('group', v_grp.name, 'product', v_prod.name)::text;
      end if;
      if v_grp.chosen > v_grp.max_select then
        raise exception 'modifier.too_many' using detail = json_build_object('group', v_grp.name, 'max', v_grp.max_select)::text;
      end if;
    end loop;
    select coalesce(jsonb_agg(jsonb_build_object('id', mo.id, 'name', mo.name, 'group', g.name, 'price_delta', mo.price_delta)
                              order by g.sort_order, mo.sort_order), '[]'::jsonb),
           coalesce(sum(mo.price_delta), 0)
      into v_mod_json, v_unit
      from pos.modifiers mo join pos.modifier_groups g on g.id = mo.group_id where mo.id = any (v_mods);
    v_unit := v_prod.price + v_unit;
    if v_unit < 0 then raise exception 'product.invalid_price'; end if;

    insert into _order_lines values (v_idx, v_prod.id, v_prod.name, v_prod.station, v_prod.price, v_unit, v_qty, v_mods, v_mod_json, v_note, v_prod.track_stock);
  end loop;

  -- 2) Unir líneas idénticas (mismo producto, opciones y nota) y aplicar
  --    la promo "N por $X" sobre el total de unidades de cada producto
  --    (el descuento es sobre el precio base; las opciones se cobran igual).
  create temp table if not exists _order_disc (product_id uuid primary key, disc numeric) on commit drop;
  truncate _order_disc;
  insert into _order_disc (product_id, disc)
    select t.product_id,
           greatest(round(floor(t.qty / pr.bundle_qty) * (pr.bundle_qty * t.base_price - pr.bundle_price), 2), 0)
    from (select product_id, base_price, sum(qty) as qty from _order_lines group by product_id, base_price) t
    cross join lateral (
      select bundle_qty, bundle_price from pos.product_promotions pr
      where pr.product_id = t.product_id and pr.active
        and (pr.location_id is null or pr.location_id = v_reg.location_id)
        and (pr.starts_at is null or pr.starts_at <= now()) and (pr.ends_at is null or pr.ends_at >= now())
      order by pr.location_id nulls last, pr.created_at desc limit 1) pr;

  v_idx := -1;
  for v_line in
    select product_id, name, station, base_price, unit_price, sum(qty) as qty, mods, mods_json, note, track, min(ord) as first_ord
    from _order_lines group by product_id, name, station, base_price, unit_price, mods, mods_json, note, track
    order by min(ord)
  loop
    v_line_gross := round(v_line.qty * v_line.unit_price, 2);
    -- Descuento de la promo del producto, repartido entre sus líneas en orden.
    v_line_disc := least(coalesce((select disc from _order_disc where product_id = v_line.product_id), 0), round(v_line.qty * v_line.base_price, 2));
    if v_line_disc > 0 then update _order_disc set disc = disc - v_line_disc where product_id = v_line.product_id; end if;
    v_idx := v_idx + 1;
    v_lines := v_lines || jsonb_build_object(
      'id', v_line.product_id, 'name', v_line.name, 'qty', v_line.qty,
      'price', v_line.unit_price, 'base_price', v_line.base_price,
      'modifiers', v_line.mods_json, 'note', v_line.note,
      'discount', v_line_disc, 'subtotal', v_line_gross - v_line_disc,
      'delivered', (v_reg.type = 'ticket' or v_line.station = 'none'),
      'station', v_line.station);
    v_total := v_total + v_line_gross - v_line_disc;

    -- Consumo de insumos de ESTA línea (receta + opciones).
    v_consumption := v_consumption || coalesce((
      select jsonb_agg(jsonb_build_object('line', v_idx, 'stock_item_id', x.stock_item_id, 'qty', round(x.qty * v_line.qty, 3), 'menu_item_id', v_line.product_id))
      from (select stock_item_id, sum(q) as qty from (
              select r.stock_item_id, r.qty_per_unit as q from pos.product_recipes r where r.product_id = v_line.product_id
              union all
              select mr.stock_item_id, mr.qty_per_unit from pos.modifier_recipes mr where mr.modifier_id = any (v_line.mods)) z
            group by stock_item_id having sum(q) <> 0) x), '[]'::jsonb);
  end loop;
  v_items := v_lines;

  if p_payment_method <> 'complimentary' and v_total <= 0 then raise exception 'order.total_zero'; end if;
  v_total := round(v_total, 2);
  v_tax := case when p_payment_method = 'complimentary' or v_org.tax_rate = 0 then 0
                else round(v_total * v_org.tax_rate / (1 + v_org.tax_rate), 2) end;
  if p_payment_method <> 'complimentary' and round(coalesce(p_cash,0) + coalesce(p_card,0), 2) <> v_total then
    raise exception 'payment.total_mismatch' using detail = json_build_object('paid', round(coalesce(p_cash,0) + coalesce(p_card,0), 2), 'total', v_total)::text;
  end if;

  -- 3) Número de pedido: por caja y evento, o por caja y día.
  if p_event_id is not null then
    insert into pos.ticket_counters (org_id, register_id, event_id, next_ticket)
      values (v_reg.org_id, v_reg.id, p_event_id, 2)
      on conflict (register_id, event_id) do update set next_ticket = pos.ticket_counters.next_ticket + 1
      returning next_ticket - 1 into v_ticket_num;
  else
    insert into pos.order_counters (org_id, register_id, day, next_number)
      values (v_reg.org_id, v_reg.id, (now() at time zone v_org.timezone)::date, 2)
      on conflict (register_id, day) do update set next_number = pos.order_counters.next_number + 1
      returning next_number - 1 into v_ticket_num;
  end if;

  if v_reg.type = 'ticket' then v_status := 'delivered'; v_delivered_at := now();
  else v_status := 'pending_delivery';
  end if;

  begin
    insert into pos.orders (
      org_id, register_id, event_id, ticket_num, items, total, payment_method,
      cash_amount, card_amount, customer_name, attended_by, sold_by_user, status, obs, delivered_at,
      ingredient_consumption, is_test, client_transaction_id, session_id, tax_rate, tax_amount, order_type, table_label
    ) values (
      v_reg.org_id, v_reg.id, p_event_id, v_ticket_num, v_items, v_total, p_payment_method,
      coalesce(p_cash,0), coalesce(p_card,0), nullif(trim(p_customer_name), ''), p_attended_by, auth.uid(), v_status, nullif(trim(p_obs), ''), v_delivered_at,
      v_consumption, coalesce(p_is_test, false), p_client_transaction_id, v_session, v_org.tax_rate, v_tax, p_order_type, nullif(trim(p_table), '')
    ) returning * into v_order;
  exception
    when unique_violation then
      select * into v_order from pos.orders where client_transaction_id = p_client_transaction_id and register_id = v_reg.id;
      if v_order.id is null then raise exception 'order.invalid_transaction'; end if;
      return v_order;
  end;

  if coalesce(p_cash, 0) > 0 then
    insert into pos.payments (org_id, register_id, order_id, kind, method, amount, status, is_test, client_transaction_id, operator_name, created_by_user, session_id)
      values (v_reg.org_id, v_reg.id, v_order.id, 'payment', 'cash', p_cash, 'approved', v_order.is_test, p_client_transaction_id, p_attended_by, auth.uid(), v_session);
  end if;
  if coalesce(p_card, 0) > 0 then
    insert into pos.payments (org_id, register_id, order_id, kind, method, amount, status, is_test, client_transaction_id, operator_name, created_by_user, session_id)
      values (v_reg.org_id, v_reg.id, v_order.id, 'payment', 'card', p_card, 'approved', v_order.is_test, p_client_transaction_id, p_attended_by, auth.uid(), v_session);
  end if;

  -- El modo prueba no toca el inventario real. El stock puede quedar
  -- negativo a propósito (para que el historial cuadre); la caja avisa.
  if not v_order.is_test then
    perform pos._apply_order_stock(v_order, -1, 'sale');
  end if;
  return v_order;
end;
$$;

-- ---------------------------------------------------------------------
-- Devoluciones: igual que antes; reponer stock usa el stock del local y
-- el consumo guardado de cada línea.
-- ---------------------------------------------------------------------
create or replace function pos.refund_order(
  p_register_id uuid, p_pin text, p_order_id uuid, p_lines jsonb, p_method text, p_reason text,
  p_supervisor_pin text, p_restock boolean default false, p_note text default null,
  p_operator text default null, p_client_transaction_id uuid default null
) returns pos.refunds
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_reg pos.registers; v_order pos.orders; v_ref pos.refunds;
  v_line jsonb; v_idx int; v_qty numeric; v_item jsonb; v_item_qty numeric;
  v_prev_qty numeric; v_prev_amt numeric; v_amount numeric; v_total numeric := 0;
  v_lines jsonb := '[]'::jsonb; v_seen int[] := '{}';
  v_paid_method numeric; v_refunded_method numeric; v_cons jsonb; v_ing_qty numeric;
  v_restock boolean; v_session uuid; v_loc uuid; v_target uuid;
begin
  v_reg := pos._register_with_any_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  if not pos._check_supervisor_pin(v_reg.org_id, p_supervisor_pin) then return null; end if;
  perform set_config('pos.operator', coalesce(p_operator, ''), true);

  if p_client_transaction_id is not null then
    select * into v_ref from pos.refunds where client_transaction_id = p_client_transaction_id and register_id = v_reg.id;
    if v_ref.id is not null then return v_ref; end if;
  end if;

  if p_method is null or p_method not in ('cash','card') then raise exception 'payment.invalid_method'; end if;
  if p_reason is null or p_reason not in ('wrong_item','quality','changed_mind','overcharged','other') then
    raise exception 'refund.invalid_reason';
  end if;

  select * into v_order from pos.orders where id = p_order_id and register_id = v_reg.id for update;
  if v_order.id is null then raise exception 'order.not_found'; end if;
  if v_order.status = 'voided' then raise exception 'refund.order_voided'; end if;
  if v_order.payment_method = 'complimentary' then raise exception 'refund.complimentary'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'refund.no_lines';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_idx := (v_line->>'index')::int;
    v_qty := (v_line->>'qty')::numeric;
    if v_idx is null or v_idx < 0 or v_idx >= jsonb_array_length(v_order.items) or v_idx = any (v_seen) then
      raise exception 'refund.invalid_line';
    end if;
    v_seen := v_seen || v_idx;
    if v_qty is null or v_qty <= 0 or v_qty <> trunc(v_qty) then raise exception 'order.qty_not_integer'; end if;

    v_item := v_order.items -> v_idx;
    v_item_qty := (v_item->>'qty')::numeric;
    select coalesce(sum((l->>'qty')::numeric), 0), coalesce(sum((l->>'amount')::numeric), 0)
      into v_prev_qty, v_prev_amt
      from pos.refunds r, jsonb_array_elements(r.lines) l
      where r.order_id = v_order.id and (l->>'index')::int = v_idx;
    if v_prev_qty + v_qty > v_item_qty then
      raise exception 'refund.qty_exceeds' using detail = json_build_object('name', v_item->>'name', 'available', v_item_qty - v_prev_qty)::text;
    end if;
    if v_prev_qty + v_qty = v_item_qty then
      v_amount := (v_item->>'subtotal')::numeric - v_prev_amt;
    else
      v_amount := round((v_item->>'subtotal')::numeric * v_qty / v_item_qty, 2);
    end if;
    v_total := v_total + v_amount;
    v_lines := v_lines || jsonb_build_object('index', v_idx, 'id', v_item->>'id', 'name', v_item->>'name',
                                             'qty', v_qty, 'item_qty', v_item_qty, 'amount', v_amount);
  end loop;
  v_total := round(v_total, 2);
  if v_total <= 0 then raise exception 'refund.zero'; end if;

  v_paid_method := case p_method when 'cash' then v_order.cash_amount else v_order.card_amount end;
  select coalesce(sum(amount), 0) into v_refunded_method from pos.refunds where order_id = v_order.id and method = p_method;
  if v_refunded_method + v_total > v_paid_method then
    raise exception 'refund.exceeds_method' using detail = json_build_object('method', p_method, 'amount', v_paid_method - v_refunded_method)::text;
  end if;

  if not v_order.is_test then
    select id into v_session from pos.register_sessions where register_id = v_reg.id and status = 'open';
    if v_session is null and p_method = 'cash' then raise exception 'session.not_open'; end if;
  end if;

  v_restock := coalesce(p_restock, false) and not v_order.is_test;
  begin
    insert into pos.refunds (org_id, register_id, order_id, amount, method, reason, note, lines, restocked,
                             is_test, client_transaction_id, operator_name, created_by_user, session_id, tax_amount)
      values (v_reg.org_id, v_reg.id, v_order.id, v_total, p_method, p_reason, p_note, v_lines, v_restock,
              v_order.is_test, p_client_transaction_id, p_operator, auth.uid(), v_session,
              case when v_order.tax_rate = 0 then 0 else round(v_total * v_order.tax_rate / (1 + v_order.tax_rate), 2) end)
      returning * into v_ref;
  exception when unique_violation then
    select * into v_ref from pos.refunds where client_transaction_id = p_client_transaction_id and register_id = v_reg.id;
    if v_ref.id is null then raise exception 'order.invalid_transaction'; end if;
    return v_ref;
  end;

  insert into pos.payments (org_id, register_id, order_id, refund_id, kind, method, amount, status, is_test, client_transaction_id, operator_name, created_by_user, session_id)
    values (v_reg.org_id, v_reg.id, v_order.id, v_ref.id, 'refund', p_method, v_total, 'approved', v_order.is_test, p_client_transaction_id, p_operator, auth.uid(), v_session);
  update pos.orders set refunded_total = refunded_total + v_total where id = v_order.id;

  if v_restock then
    select location_id into v_loc from pos.registers where id = v_order.register_id;
    for v_line in select * from jsonb_array_elements(v_lines) loop
      if exists (select 1 from pos.products where id = (v_line->>'id')::uuid and org_id = v_reg.org_id and track_stock) then
        perform pos._stock_change(v_reg.org_id, v_loc, (v_line->>'id')::uuid, null, (v_line->>'qty')::numeric, 'refund_return',
                                  p_by => p_operator, p_register_id => v_reg.id, p_order_id => v_order.id, p_event_id => v_order.event_id);
      end if;
      -- Insumos: proporcional a lo consumido por ESA línea (formato nuevo:
      -- "line"; ventas anteriores: por producto).
      for v_cons in
        select c from jsonb_array_elements(coalesce(v_order.ingredient_consumption, '[]'::jsonb)) c
        where (c ? 'line' and (c->>'line')::int = (v_line->>'index')::int)
           or (not c ? 'line' and c->>'menu_item_id' = v_line->>'id')
      loop
        v_target := coalesce(v_cons->>'stock_item_id', v_cons->>'ingredient_id')::uuid;
        v_ing_qty := round((v_cons->>'qty')::numeric * (v_line->>'qty')::numeric / (v_line->>'item_qty')::numeric, 3);
        if exists (select 1 from pos.stock_items where id = v_target and org_id = v_reg.org_id) then
          perform pos._stock_change(v_reg.org_id, v_loc, null, v_target, v_ing_qty, 'refund_return',
                                    p_by => p_operator, p_register_id => v_reg.id, p_order_id => v_order.id, p_event_id => v_order.event_id);
        end if;
      end loop;
    end loop;
  end if;
  return v_ref;
end;
$$;

-- ---------------------------------------------------------------------
-- Retiro del catálogo por caja
-- ---------------------------------------------------------------------
drop function pos.add_menu_item;
drop function pos.update_menu_item;
drop function pos.remove_menu_item;
drop function pos.set_item_color;
drop function pos.set_item_station;
drop function pos.upsert_ingredient;
drop function pos.set_recipe;
drop function pos.upsert_promotion;
drop function pos.delete_promotion;
drop function pos.remove_ingredient;
drop function pos.disable_stock;
drop function pos.restock_item;
drop function pos.restock_ingredient;
drop function pos.record_waste;
drop function pos.record_stocktake;

drop table pos.recipe_items, pos.promotions, pos.stock_movements, pos.stocktakes, pos.ingredients, pos.menu_items cascade;
drop function if exists pos._audit_menu_items();
drop function if exists pos._audit_promotions();
drop function if exists pos._audit_recipe();
drop function if exists pos._audit_stock();
drop function if exists pos._audit_stocktakes();
drop function if exists pos._stocktakes_guard();

-- ---------------------------------------------------------------------
-- "Hoy": stock bajo por local con el catálogo nuevo (el campo "register"
-- ahora trae el nombre del local).
-- ---------------------------------------------------------------------
create or replace function pos.today_overview(p_org_id uuid, p_location_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_tz text; v_start timestamptz; v_now timestamptz := now();
  v_week constant interval := interval '7 days';
  v_res jsonb;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin','manager']);
  if p_location_id is not null and not exists (select 1 from pos.locations where id = p_location_id and org_id = p_org_id) then
    raise exception 'location.not_found';
  end if;
  select timezone into v_tz from pos.organizations where id = p_org_id;
  v_start := date_trunc('day', v_now at time zone v_tz) at time zone v_tz;

  with regs as (
    select r.id, r.location_id from pos.registers r
    where r.org_id = p_org_id and (p_location_id is null or r.location_id = p_location_id)
  ),
  ord as (
    select o.*, regs.location_id from pos.orders o join regs on regs.id = o.register_id
    where o.org_id = p_org_id and not o.is_test and o.status <> 'voided' and o.payment_method <> 'complimentary'
      and ((o.paid_at >= v_start and o.paid_at <= v_now) or (o.paid_at >= v_start - v_week and o.paid_at <= v_now - v_week))
  ),
  ref as (
    select f.amount, f.created_at, regs.location_id from pos.refunds f join regs on regs.id = f.register_id
    where f.org_id = p_org_id and not f.is_test
      and ((f.created_at >= v_start and f.created_at <= v_now) or (f.created_at >= v_start - v_week and f.created_at <= v_now - v_week))
  ),
  totals as (
    select
      coalesce(sum(total) filter (where paid_at >= v_start), 0) as gross,
      count(*) filter (where paid_at >= v_start) as orders,
      coalesce(sum(total) filter (where paid_at < v_start), 0) as gross_lw,
      count(*) filter (where paid_at < v_start) as orders_lw
    from ord
  ),
  rtotals as (
    select coalesce(sum(amount) filter (where created_at >= v_start), 0) as refunds,
           coalesce(sum(amount) filter (where created_at < v_start), 0) as refunds_lw
    from ref
  )
  select jsonb_build_object(
    'timezone', v_tz,
    'day_start', v_start,
    'as_of', v_now,
    'sales', t.gross - r.refunds,
    'orders', t.orders,
    'avg_ticket', case when t.orders > 0 then round(t.gross / t.orders, 2) else 0 end,
    'refunds', r.refunds,
    'last_week', jsonb_build_object(
      'sales', t.gross_lw - r.refunds_lw, 'orders', t.orders_lw,
      'avg_ticket', case when t.orders_lw > 0 then round(t.gross_lw / t.orders_lw, 2) else 0 end),
    'by_location', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name,
               'sales', coalesce((select sum(total) from ord where ord.location_id = l.id and paid_at >= v_start), 0)
                      - coalesce((select sum(amount) from ref where ref.location_id = l.id and created_at >= v_start), 0),
               'orders', (select count(*) from ord where ord.location_id = l.id and paid_at >= v_start))
             order by l.created_at)
      from pos.locations l where l.org_id = p_org_id and (p_location_id is null or l.id = p_location_id)), '[]'::jsonb),
    'top_products', coalesce((
      select jsonb_agg(x order by x.qty desc, x.name) from (
        select it->>'name' as name, sum((it->>'qty')::numeric) as qty, sum((it->>'subtotal')::numeric) as sales
        from ord, jsonb_array_elements(ord.items) it
        where ord.paid_at >= v_start
        group by it->>'name' order by 2 desc, 1 limit 5) x), '[]'::jsonb),
    'registers', jsonb_build_object(
      'total', (select count(*) from pos.registers r join regs on regs.id = r.id where r.active),
      'open', (select count(*) from pos.register_sessions s join regs on regs.id = s.register_id where s.status = 'open')),
    'open_sessions', coalesce((
      select jsonb_agg(jsonb_build_object('register', r.name, 'location', l.name, 'opened_at', s.opened_at, 'opened_by', s.opened_by_name) order by s.opened_at)
      from pos.register_sessions s join pos.registers r on r.id = s.register_id join regs on regs.id = r.id
      join pos.locations l on l.id = r.location_id where s.status = 'open'), '[]'::jsonb),
    'low_stock', coalesce((
      select jsonb_agg(y order by y.pct) from (
        select p.name, pl.stock_qty as qty, null::text as unit, round(pl.stock_qty / pl.initial_stock, 3) as pct, l.name as register
        from pos.product_locations pl join pos.products p on p.id = pl.product_id and p.active and p.track_stock
        join pos.locations l on l.id = pl.location_id
        where pl.org_id = p_org_id and (p_location_id is null or pl.location_id = p_location_id)
          and pl.initial_stock > 0 and pl.stock_qty / pl.initial_stock <= 0.25
        union all
        select s.name, sl.qty, s.unit, round(sl.qty / sl.initial_qty, 3), l.name
        from pos.stock_levels sl join pos.stock_items s on s.id = sl.stock_item_id and s.active
        join pos.locations l on l.id = sl.location_id
        where sl.org_id = p_org_id and (p_location_id is null or sl.location_id = p_location_id)
          and sl.initial_qty > 0 and sl.qty / sl.initial_qty <= 0.25
        order by 4 limit 8) y), '[]'::jsonb),
    'last_close_variance', (
      select jsonb_build_object('register', r.name, 'variance', s.cash_variance, 'closed_at', s.closed_at)
      from pos.register_sessions s join pos.registers r on r.id = s.register_id join regs on regs.id = r.id
      where s.status = 'closed' and s.cash_variance <> 0 and s.closed_at >= v_start - interval '1 day'
      order by s.closed_at desc limit 1),
    'setup', jsonb_build_object(
      'details', (select legal_name is not null and address_line is not null and contact_phone is not null from pos.organizations where id = p_org_id),
      'products', exists (select 1 from pos.products p where p.org_id = p_org_id and p.active),
      'registers', exists (select 1 from pos.registers r where r.org_id = p_org_id and r.active),
      'first_sale', exists (select 1 from pos.orders o where o.org_id = p_org_id),
      'team', (select count(*) from pos.memberships m where m.org_id = p_org_id and m.status = 'active') > 1)
  ) into v_res
  from totals t, rtotals r;
  return v_res;
end;
$$;

-- ---------------------------------------------------------------------
-- Permisos de las funciones nuevas o con firma nueva
-- ---------------------------------------------------------------------
revoke execute on function pos.create_order(uuid, text, uuid, jsonb, text, numeric, numeric, text, text, text, text, boolean, uuid, text, text) from public, anon;
grant execute on function pos.create_order(uuid, text, uuid, jsonb, text, numeric, numeric, text, text, text, text, boolean, uuid, text, text) to authenticated;
revoke execute on function pos._apply_order_stock(pos.orders, int, text) from public, anon, authenticated;
grant execute on all functions in schema pos to service_role;

-- ---------------------------------------------------------------------
-- Endurecimiento general (igual que la migración de permisos): las
-- funciones nuevas nacen ejecutables por anon por los default privileges
-- globales de Supabase, y CREATE OR REPLACE borra el search_path fijo.
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure::text as sig, p.proname, p.proconfig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'pos'
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname like '\_%' then
      execute format('revoke execute on function %s from authenticated', f.sig);
    end if;
    if not exists (select 1 from unnest(coalesce(f.proconfig, '{}')) c where c like 'search_path=%') then
      execute format('alter function %s set search_path = pos, extensions, pg_temp', f.sig);
    end if;
  end loop;
end $$;
grant execute on all functions in schema pos to service_role;

-- =====================================================================
-- Fase 5 — Ruteo por estación (KDS).
--
-- Cada producto tiene una estación de preparación: bar, kitchen, coffee,
-- collection (retiro/mostrador) o none (no se prepara: se entrega al
-- cobrar). La estación se guarda en cada línea del pedido al vender.
-- La pantalla de Entrega puede filtrarse por estación: cada dispositivo
-- (bar, cocina, café) ve y marca solo lo suyo; la vista "todas" cierra el
-- pedido completo.
-- =====================================================================

alter table pos.menu_items
  add column station text not null default 'bar'
    check (station in ('bar','kitchen','coffee','collection','none'));

-- Líneas de pedidos existentes: estación "bar" (todas venían de la barra).
alter table pos.orders disable trigger orders_guard;
update pos.orders set items = (
  select coalesce(jsonb_agg(case when e ? 'station' then e else e || '{"station":"bar"}'::jsonb end order by ord), '[]'::jsonb)
  from jsonb_array_elements(items) with ordinality x(e, ord));
alter table pos.orders enable trigger orders_guard;

create function pos.set_item_station(p_register_id uuid, p_pin text, p_item_id uuid, p_station text)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  if p_station not in ('bar','kitchen','coffee','collection','none') then raise exception 'station.invalid'; end if;
  update pos.menu_items set station = p_station where id = p_item_id and register_id = v_reg.id;
  if not found then raise exception 'product.not_found'; end if;
  return true;
end;
$$;

-- Marca como listas todas las líneas de UNA estación de un pedido (un
-- solo UPDATE: dos estaciones marcando a la vez no se pisan).
create function pos.despacho_mark_station(p_register_id uuid, p_despacho_pin text, p_order_id uuid, p_station text, p_by text default null)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_despacho_pin(p_register_id, p_despacho_pin);
  if v_reg.id is null then return false; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);
  if p_station not in ('bar','kitchen','coffee','collection','none') then raise exception 'station.invalid'; end if;
  update pos.orders set items = (
    select jsonb_agg(case when coalesce(e->>'station', 'bar') = p_station then e || '{"delivered":true}'::jsonb else e end order by ord)
    from jsonb_array_elements(items) with ordinality x(e, ord))
  where id = p_order_id and register_id = v_reg.id and status = 'pending_delivery';
  if not found then raise exception 'order.not_found'; end if;
  return true;
end;
$$;

grant execute on function pos.set_item_station(uuid, text, uuid, text) to authenticated;
grant execute on function pos.despacho_mark_station(uuid, text, uuid, text, text) to authenticated;
grant execute on all functions in schema pos to service_role;

-- La auditoría registra el cambio de estación de un producto.
create or replace function pos._audit_menu_items() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    perform pos._audit(new.org_id, new.register_id, 'menu.add', 'menu_item', new.id,
      jsonb_build_object('name', new.name, 'price', new.price));
  elsif new.active is distinct from old.active and not new.active then
    perform pos._audit(new.org_id, new.register_id, 'menu.remove', 'menu_item', new.id, jsonb_build_object('name', new.name));
  elsif new.price is distinct from old.price or new.name is distinct from old.name or new.station is distinct from old.station then
    perform pos._audit(new.org_id, new.register_id, 'menu.update', 'menu_item', new.id,
      jsonb_build_object('old_name', old.name, 'new_name', new.name, 'old_price', old.price, 'new_price', new.price,
                         'old_station', old.station, 'new_station', new.station));
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- create_order: guarda la estación de cada línea
-- ---------------------------------------------------------------------
create or replace function pos.create_order(
  p_register_id uuid, p_pin text, p_event_id uuid, p_items jsonb,
  p_payment_method text, p_cash numeric, p_card numeric,
  p_customer_name text, p_obs text, p_attended_by text,
  p_supervisor_pin text default null, p_is_test boolean default false,
  p_client_transaction_id uuid default null
) returns pos.orders
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_reg pos.registers;
  v_total numeric := 0;
  v_ticket_num int;
  v_status text;
  v_delivered_at timestamptz := null;
  v_order pos.orders;
  v_item jsonb;
  v_stock_after numeric;
  v_recipe_line record;
  v_ingredient_after numeric;
  v_sold_qty numeric;
  v_consumption jsonb := '[]'::jsonb;
  v_agg record;
  v_menu_item pos.menu_items;
  v_promo pos.promotions;
  v_bundles numeric;
  v_remainder numeric;
  v_line_subtotal numeric;
  v_resolved_items jsonb := '[]'::jsonb;
  v_max_qty_per_line constant numeric := 500; -- tope de cordura por línea, no una regla de negocio
  v_session uuid;
  v_tax_rate numeric;
  v_tax numeric;
begin
  -- Autorización PRIMERO (antes, la búsqueda por idempotencia iba antes
  -- del PIN: cualquiera que conociera un client_transaction_id podía leer
  -- ese pedido sin PIN).
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_attended_by, ''), true);

  -- Idempotencia: si este intento de cobro ya se registró en esta caja,
  -- devolver esa misma venta en vez de crear otra.
  if p_client_transaction_id is not null then
    select * into v_order from pos.orders
      where client_transaction_id = p_client_transaction_id and register_id = v_reg.id;
    if v_order.id is not null then return v_order; end if;
  end if;

  -- Vender de verdad exige una sesión de caja abierta (las ventas de prueba no).
  if not coalesce(p_is_test, false) then
    select id into v_session from pos.register_sessions where register_id = v_reg.id and status = 'open';
    if v_session is null then raise exception 'session.not_open'; end if;
  end if;

  if p_payment_method not in ('cash','card','split','complimentary') then
    raise exception 'payment.invalid_method';
  end if;

  -- Cortesía: siempre exige el PIN de supervisor (en un dispositivo
  -- compartido el rol de la cuenta no identifica a quien está cobrando).
  -- Un PIN de supervisor incorrecto devuelve null (no lanza) para que el
  -- intento fallido quede registrado.
  if p_payment_method = 'complimentary' and not pos._check_supervisor_pin(v_reg.org_id, p_supervisor_pin) then
    return null;
  end if;

  -- Montos: nunca negativos, y coherentes con el método de pago elegido.
  if coalesce(p_cash, 0) < 0 or coalesce(p_card, 0) < 0 then
    raise exception 'payment.negative_amount';
  end if;
  if (p_payment_method = 'cash' and coalesce(p_card, 0) <> 0)
     or (p_payment_method = 'card' and coalesce(p_cash, 0) <> 0)
     or (p_payment_method = 'split' and (coalesce(p_cash, 0) <= 0 or coalesce(p_card, 0) <= 0))
     or (p_payment_method = 'complimentary' and (coalesce(p_cash, 0) <> 0 or coalesce(p_card, 0) <> 0)) then
    raise exception 'payment.amounts_mismatch_method' using detail = json_build_object('method', p_payment_method)::text;
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'order.no_items';
  end if;

  -- =====================================================================
  -- PRECIO Y SUBTOTAL SIEMPRE LOS CALCULA EL SERVIDOR. Del navegador solo
  -- se usa "qué producto" y "cuánta cantidad". Se agrega la cantidad por
  -- producto primero, así la promoción se calcula sobre el total real sin
  -- importar cómo venga partido el carrito.
  -- =====================================================================
  for v_agg in
    select (elem->>'id')::uuid as item_id, sum(coalesce((elem->>'qty')::numeric, 0)) as qty
    from jsonb_array_elements(p_items) elem
    where elem ? 'id'
    group by (elem->>'id')::uuid
  loop
    if v_agg.qty is null or v_agg.qty <= 0 then
      raise exception 'order.invalid_qty';
    end if;
    if v_agg.qty <> trunc(v_agg.qty) then
      raise exception 'order.qty_not_integer';
    end if;
    if v_agg.qty > v_max_qty_per_line then
      raise exception 'order.qty_too_large' using detail = json_build_object('max', v_max_qty_per_line)::text;
    end if;

    select * into v_menu_item from pos.menu_items
      where id = v_agg.item_id and register_id = v_reg.id and active = true;
    if v_menu_item.id is null then
      raise exception 'product.not_found' using detail = json_build_object('id', v_agg.item_id)::text;
    end if;

    select * into v_promo from pos.promotions
      where menu_item_id = v_agg.item_id and register_id = v_reg.id and active = true
        and (starts_at is null or starts_at <= now())
        and (ends_at is null or ends_at >= now())
      order by created_at desc limit 1;

    if v_promo.id is not null and v_promo.bundle_qty > 0 then
      v_bundles := floor(v_agg.qty / v_promo.bundle_qty);
      v_remainder := v_agg.qty - (v_bundles * v_promo.bundle_qty);
      v_line_subtotal := v_bundles * v_promo.bundle_price + v_remainder * v_menu_item.price;
    else
      v_line_subtotal := v_agg.qty * v_menu_item.price;
    end if;

    v_total := v_total + v_line_subtotal;
    v_resolved_items := v_resolved_items || jsonb_build_object(
      'id', v_menu_item.id, 'name', v_menu_item.name, 'qty', v_agg.qty,
      'price', v_menu_item.price, 'subtotal', v_line_subtotal,
      -- La estación queda en la foto de la venta: cambiarla después no mueve
      -- pedidos ya hechos. "none" = no requiere preparación (se entrega al cobrar).
      'delivered', (v_reg.type = 'ticket' or v_menu_item.station = 'none'),
      'station', v_menu_item.station
    );
  end loop;

  if jsonb_array_length(v_resolved_items) = 0 then
    raise exception 'order.no_items';
  end if;

  if p_payment_method <> 'complimentary' and v_total <= 0 then
    raise exception 'order.total_zero';
  end if;

  -- Exacto al centavo (antes se aceptaba hasta $1 de diferencia, herencia
  -- de pesos chilenos sin decimales — en NZD eso es plata real).
  v_total := round(v_total, 2);
  -- GST incluido en el precio: impuesto = total × tasa / (1 + tasa). Se
  -- guarda con la venta (un cambio de tasa posterior no altera el pasado).
  select tax_rate into v_tax_rate from pos.organizations where id = v_reg.org_id;
  v_tax := case when p_payment_method = 'complimentary' or v_tax_rate = 0 then 0
                else round(v_total * v_tax_rate / (1 + v_tax_rate), 2) end;
  if p_payment_method <> 'complimentary' and round(coalesce(p_cash,0) + coalesce(p_card,0), 2) <> v_total then
    raise exception 'payment.total_mismatch' using detail = json_build_object('paid', round(coalesce(p_cash,0) + coalesce(p_card,0), 2), 'total', v_total)::text;
  end if;

  -- Numeración por caja + evento. La FK compuesta (event_id, org_id)
  -- rechaza un evento de otra organización.
  if p_event_id is not null then
    insert into pos.ticket_counters (org_id, register_id, event_id, next_ticket)
      values (v_reg.org_id, v_reg.id, p_event_id, 2)
      on conflict (register_id, event_id) do update set next_ticket = pos.ticket_counters.next_ticket + 1
      returning next_ticket - 1 into v_ticket_num;
  else
    raise exception 'order.event_required';
  end if;

  if v_reg.type = 'ticket' then
    v_status := 'delivered';
    v_delivered_at := now();
  else
    v_status := 'pending_delivery';
  end if;

  -- Foto de consumo de insumos, guardada con el pedido: anular después
  -- devuelve exactamente lo que se descontó hoy, aunque la receta cambie.
  for v_item in select * from jsonb_array_elements(v_resolved_items) loop
    v_sold_qty := (v_item->>'qty')::numeric;
    for v_recipe_line in
      select ri.ingredient_id, ri.qty_per_unit from pos.recipe_items ri
      where ri.menu_item_id = (v_item->>'id')::uuid and ri.register_id = v_reg.id
    loop
      v_consumption := v_consumption || jsonb_build_object('ingredient_id', v_recipe_line.ingredient_id, 'qty', v_recipe_line.qty_per_unit * v_sold_qty, 'menu_item_id', (v_item->>'id')::uuid);
    end loop;
  end loop;

  begin
    insert into pos.orders (
      org_id, register_id, event_id, ticket_num, items, total, payment_method,
      cash_amount, card_amount, customer_name, attended_by, sold_by_user, status, obs, delivered_at,
      ingredient_consumption, is_test, client_transaction_id, session_id, tax_rate, tax_amount
    ) values (
      v_reg.org_id, v_reg.id, p_event_id, v_ticket_num, v_resolved_items, v_total, p_payment_method,
      coalesce(p_cash,0), coalesce(p_card,0), p_customer_name, p_attended_by, auth.uid(), v_status, p_obs, v_delivered_at,
      v_consumption, coalesce(p_is_test, false), p_client_transaction_id, v_session, v_tax_rate, v_tax
    ) returning * into v_order;
  exception
    when unique_violation then
      -- Otra petición con el mismo identificador ganó la carrera: devolver
      -- esa venta (de ESTA caja) en vez de crear otra o descontar dos veces.
      select * into v_order from pos.orders
        where client_transaction_id = p_client_transaction_id and register_id = v_reg.id;
      if v_order.id is null then raise exception 'order.invalid_transaction'; end if;
      return v_order;
  end;

  -- Libro de pagos: una fila por medio de pago aprobado (las cortesías no
  -- tienen pago). Los caminos de idempotencia de arriba retornan antes de
  -- llegar acá, así un reintento nunca duplica pagos.
  if coalesce(p_cash, 0) > 0 then
    insert into pos.payments (org_id, register_id, order_id, kind, method, amount, status, is_test, client_transaction_id, operator_name, created_by_user, session_id)
      values (v_reg.org_id, v_reg.id, v_order.id, 'payment', 'cash', p_cash, 'approved', v_order.is_test, p_client_transaction_id, p_attended_by, auth.uid(), v_session);
  end if;
  if coalesce(p_card, 0) > 0 then
    insert into pos.payments (org_id, register_id, order_id, kind, method, amount, status, is_test, client_transaction_id, operator_name, created_by_user, session_id)
      values (v_reg.org_id, v_reg.id, v_order.id, 'payment', 'card', p_card, 'approved', v_order.is_test, p_client_transaction_id, p_attended_by, auth.uid(), v_session);
  end if;

  -- Modo prueba: el pedido se crea (para probar impresión y Entrega) pero
  -- no toca inventario real.
  if not coalesce(p_is_test, false) then

    -- Política de sobreventa (decisión del negocio): el stock SÍ puede
    -- quedar negativo, a propósito, para que el historial cuadre siempre
    -- y se pueda reconciliar después. El aviso se hace en el navegador.
    -- Solo toca stock_qty, nunca initial_stock (base del % restante).
    for v_item in select * from jsonb_array_elements(v_resolved_items) loop
      v_sold_qty := (v_item->>'qty')::numeric;

      update pos.menu_items
        set stock_qty = stock_qty - v_sold_qty
        where id = (v_item->>'id')::uuid and register_id = v_reg.id
          and track_stock = true and stock_qty is not null
        returning stock_qty into v_stock_after;

      if found then
        insert into pos.stock_movements (org_id, register_id, menu_item_id, event_id, type, qty_change, qty_after, created_by, created_by_user)
          values (v_reg.org_id, v_reg.id, (v_item->>'id')::uuid, p_event_id, 'sale', -v_sold_qty, v_stock_after, p_attended_by, auth.uid());
      end if;
    end loop;

    for v_item in select * from jsonb_array_elements(v_consumption) loop
      update pos.ingredients
        set stock_qty = coalesce(stock_qty, 0) - (v_item->>'qty')::numeric
        where id = (v_item->>'ingredient_id')::uuid and register_id = v_reg.id
        returning stock_qty into v_ingredient_after;

      if found then
        insert into pos.stock_movements (org_id, register_id, ingredient_id, event_id, type, qty_change, qty_after, created_by, created_by_user)
          values (v_reg.org_id, v_reg.id, (v_item->>'ingredient_id')::uuid, p_event_id, 'sale',
                  -(v_item->>'qty')::numeric, v_ingredient_after, p_attended_by, auth.uid());
      end if;
    end loop;

  end if; -- not is_test

  return v_order;
end;
$$;

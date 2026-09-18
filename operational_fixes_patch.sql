-- =====================================================================
-- Parche: mejoras operacionales y correcciones de workflow
--  1) Confirmación de pago con tarjeta (solo cambios de UI, sin SQL)
--  2) Foto de consumo real de insumos (para que anular sea exacto)
--  3) Editar insumos + bloqueo de cambio de unidad con stock cargado
--  4) Numeración de tickets por caja+evento (antes era por caja completa)
--  5) Test Mode (pedidos de prueba que no tocan stock ni reportes)
--
-- IMPORTANTE: create_order cambia de firma (se le agregó p_is_test).
-- Hay que borrar la función vieja primero o quedan dos versiones
-- compitiendo y Supabase no sabe cuál usar.
-- =====================================================================

alter table pos.orders add column if not exists ingredient_consumption jsonb;
alter table pos.orders add column if not exists is_test boolean not null default false;

do $$
declare v_conname text;
begin
  select conname into v_conname
  from pg_constraint
  where conrelid = 'pos.orders'::regclass
    and contype = 'u'
    and array_length(conkey,1) = 2
    and conkey = (select array_agg(attnum order by attnum) from pg_attribute
                  where attrelid = 'pos.orders'::regclass and attname in ('register_id','ticket_num'));
  if v_conname is not null then
    execute format('alter table pos.orders drop constraint %I', v_conname);
  end if;
end $$;

alter table pos.orders add constraint orders_register_event_ticket_num_key unique (register_id, event_id, ticket_num);

create table if not exists pos.ticket_counters (
  register_id uuid not null references pos.registers(id),
  event_id uuid not null references pos.events(id),
  next_ticket int not null default 1,
  primary key (register_id, event_id)
);
grant select on pos.ticket_counters to anon, authenticated;
revoke insert, update, delete on pos.ticket_counters from anon, authenticated;

drop function if exists pos.create_order(uuid, text, uuid, jsonb, text, numeric, numeric, text, text, text, text);

create or replace function pos.upsert_ingredient(
  p_register_id uuid, p_pin text, p_ingredient_id uuid, p_name text, p_unit text,
  p_container_size numeric, p_container_label text
) returns pos.ingredients language plpgsql security definer set search_path = pos as $$
declare v_row pos.ingredients; v_current pos.ingredients;
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  if p_ingredient_id is null then
    insert into pos.ingredients (register_id, name, unit, container_size, container_label)
      values (p_register_id, p_name, p_unit, p_container_size, p_container_label)
      returning * into v_row;
  else
    select * into v_current from pos.ingredients where id = p_ingredient_id and register_id = p_register_id;
    if v_current is null then raise exception 'Insumo no encontrado'; end if;
    -- No se puede cambiar la unidad si ya hay stock cargado en la unidad
    -- anterior: el número guardado (ej. 9500) quedaría mal interpretado en
    -- la unidad nueva (9500 "L" en vez de 9500 "ml"). Hay que reiniciar el
    -- stock a propósito después de cambiar la unidad, no que quede
    -- reinterpretado en silencio.
    if p_unit is not null and p_unit <> v_current.unit and v_current.stock_qty is not null then
      raise exception 'No se puede cambiar la unidad con stock cargado (%). Usa "Reiniciar a" con la unidad nueva primero.', v_current.unit;
    end if;
    update pos.ingredients set
      name = coalesce(p_name, name), unit = coalesce(p_unit, unit),
      container_size = p_container_size, container_label = p_container_label
    where id = p_ingredient_id and register_id = p_register_id
    returning * into v_row;
  end if;
  return v_row;
end;
$$;
grant execute on function pos.upsert_ingredient(uuid, text, uuid, text, text, numeric, text) to anon, authenticated;

create or replace function pos.reset_ticket_numbering(p_admin_pin text, p_register_id uuid, p_event_id uuid, p_start_at int default 1)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_admin_pin(p_admin_pin) then raise exception 'PIN de administrador incorrecto'; end if;
  insert into pos.ticket_counters (register_id, event_id, next_ticket) values (p_register_id, p_event_id, p_start_at)
    on conflict (register_id, event_id) do update set next_ticket = p_start_at;
  return true;
end;
$$;
grant execute on function pos.reset_ticket_numbering(text, uuid, uuid, int) to anon, authenticated;

create or replace function pos.create_order(
  p_register_id uuid, p_pin text, p_event_id uuid, p_items jsonb,
  p_payment_method text, p_cash numeric, p_card numeric,
  p_customer_name text, p_obs text, p_attended_by text,
  p_admin_pin text default null, p_is_test boolean default false
) returns pos.orders language plpgsql security definer set search_path = pos as $$
declare
  v_register pos.registers;
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
begin
  select * into v_register from pos.registers where id = p_register_id;
  if v_register is null or v_register.pin <> p_pin then
    raise exception 'PIN incorrecto';
  end if;

  if p_payment_method = 'cortesia' then
    if p_admin_pin is null or not pos.verify_admin_pin(p_admin_pin) then
      raise exception 'Cortesía requiere PIN de administrador válido';
    end if;
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_total := v_total + coalesce((v_item->>'subtotal')::numeric, 0);
  end loop;

  if jsonb_array_length(p_items) = 0 then
    raise exception 'El pedido no tiene productos';
  end if;
  if p_payment_method <> 'cortesia' and v_total <= 0 then
    raise exception 'El total del pedido debe ser mayor a cero';
  end if;

  if p_payment_method <> 'cortesia' and abs((coalesce(p_cash,0) + coalesce(p_card,0)) - v_total) > 1 then
    raise exception 'El efectivo + tarjeta no coincide con el total';
  end if;

  insert into pos.ticket_counters (register_id, event_id, next_ticket) values (p_register_id, p_event_id, 2)
    on conflict (register_id, event_id) do update set next_ticket = pos.ticket_counters.next_ticket + 1
    returning next_ticket - 1 into v_ticket_num;

  if v_register.type = 'ticket' then
    v_status := 'entregado';
    v_delivered_at := now();
  else
    v_status := 'pendiente_entrega';
  end if;

  -- Calcular la foto de consumo de insumos ANTES de insertar el pedido, y
  -- guardarla junto con él. Esto es lo que permite que anular (más adelante,
  -- incluso después de editar la receta) devuelva exactamente lo que se
  -- descontó en este momento — nunca lo que la receta diga en el futuro.
  for v_item in select * from jsonb_array_elements(p_items) loop
    if v_item ? 'id' then
      v_sold_qty := coalesce((v_item->>'qty')::numeric, 0);
      for v_recipe_line in
        select ri.ingredient_id, ri.qty_per_unit from pos.recipe_items ri where ri.menu_item_id = (v_item->>'id')::uuid
      loop
        v_consumption := v_consumption || jsonb_build_object('ingredient_id', v_recipe_line.ingredient_id, 'qty', v_recipe_line.qty_per_unit * v_sold_qty);
      end loop;
    end if;
  end loop;

  insert into pos.orders (
    register_id, event_id, ticket_num, items, total, payment_method,
    cash_amount, card_amount, customer_name, attended_by, status, obs, delivered_at,
    ingredient_consumption, is_test
  ) values (
    p_register_id, p_event_id, v_ticket_num, p_items, v_total, p_payment_method,
    coalesce(p_cash,0), coalesce(p_card,0), p_customer_name, p_attended_by, v_status, p_obs, v_delivered_at,
    v_consumption, coalesce(p_is_test, false)
  ) returning * into v_order;

  -- En modo prueba no se toca inventario real: el pedido igual queda
  -- creado (para poder imprimir y probar el flujo de Entrega completo),
  -- pero el stock de productos e insumos no se descuenta.
  if not coalesce(p_is_test, false) then

  -- Descontar stock de los productos vendidos que lo tengan activado.
  -- IMPORTANTE: solo toca stock_qty, nunca initial_stock (esa es la base
  -- del % restante — reiniciarla en cada venta es el bug que hacía que
  -- siempre marcara 100%).
  for v_item in select * from jsonb_array_elements(p_items) loop
    if v_item ? 'id' then
      v_sold_qty := coalesce((v_item->>'qty')::numeric, 0);

      update pos.menu_items
        set stock_qty = greatest(0, stock_qty - v_sold_qty)
        where id = (v_item->>'id')::uuid
          and register_id = p_register_id
          and track_stock = true
          and stock_qty is not null
        returning stock_qty into v_stock_after;

      if found then
        insert into pos.stock_movements (menu_item_id, register_id, event_id, type, qty_change, qty_after, created_by)
          values ((v_item->>'id')::uuid, p_register_id, p_event_id, 'venta', -v_sold_qty, v_stock_after, p_attended_by);
      end if;
    end if;
  end loop;

  -- Descontar insumos usando exactamente la foto de consumo calculada arriba.
  for v_item in select * from jsonb_array_elements(v_consumption) loop
    update pos.ingredients
      set stock_qty = greatest(0, coalesce(stock_qty,0) - (v_item->>'qty')::numeric)
      where id = (v_item->>'ingredient_id')::uuid
      returning stock_qty into v_ingredient_after;

    insert into pos.stock_movements (ingredient_id, register_id, event_id, type, qty_change, qty_after, created_by)
      values ((v_item->>'ingredient_id')::uuid, p_register_id, p_event_id, 'venta',
              -(v_item->>'qty')::numeric, v_ingredient_after, p_attended_by);
  end loop;

  end if; -- not is_test

  return v_order;
end;
$$;
grant execute on function pos.create_order(uuid, text, uuid, jsonb, text, numeric, numeric, text, text, text, text, boolean) to anon, authenticated;

create or replace function pos.void_order(p_register_id uuid, p_pin text, p_order_id uuid)
returns boolean language plpgsql security definer set search_path = pos as $$
declare
  v_order pos.orders;
  v_item jsonb;
  v_sold_qty numeric;
  v_stock_after numeric;
  v_ingredient_after numeric;
begin
  if not (pos.verify_register_pin(p_register_id, p_pin) or pos.verify_despacho_pin(p_register_id, p_pin)) then
    raise exception 'PIN incorrecto';
  end if;

  select * into v_order from pos.orders where id = p_order_id and register_id = p_register_id;
  if v_order is null then raise exception 'Pedido no encontrado'; end if;
  if v_order.status = 'anulado' then return true; end if; -- ya estaba anulado: no repetir la reposición

  update pos.orders set status = 'anulado' where id = p_order_id and register_id = p_register_id;

  -- Reponer el stock de productos e insumos que create_order() había
  -- descontado al vender — antes esto no se hacía y anular un pedido
  -- dejaba el inventario permanentemente más bajo de lo real.
  for v_item in select * from jsonb_array_elements(v_order.items) loop
    if v_item ? 'id' then
      v_sold_qty := coalesce((v_item->>'qty')::numeric, 0);

      update pos.menu_items
        set stock_qty = stock_qty + v_sold_qty
        where id = (v_item->>'id')::uuid and register_id = p_register_id
          and track_stock = true and stock_qty is not null
        returning stock_qty into v_stock_after;
      if found then
        insert into pos.stock_movements (menu_item_id, register_id, event_id, type, qty_change, qty_after, note, created_by)
          values ((v_item->>'id')::uuid, p_register_id, v_order.event_id, 'ajuste', v_sold_qty, v_stock_after,
                  'Repuesto por anular ticket #' || v_order.ticket_num, null);
      end if;
    end if;
  end loop;

  -- Reponer insumos usando la FOTO de consumo guardada al momento de la
  -- venta (columna ingredient_consumption) — nunca la receta actual. Así,
  -- si la receta cambió después de esta venta, anular sigue devolviendo
  -- exactamente lo que se descontó ese día, no lo que la receta dice hoy.
  if v_order.ingredient_consumption is not null then
    for v_item in select * from jsonb_array_elements(v_order.ingredient_consumption) loop
      update pos.ingredients
        set stock_qty = coalesce(stock_qty,0) + (v_item->>'qty')::numeric
        where id = (v_item->>'ingredient_id')::uuid
        returning stock_qty into v_ingredient_after;
      insert into pos.stock_movements (ingredient_id, register_id, event_id, type, qty_change, qty_after, note, created_by)
        values ((v_item->>'ingredient_id')::uuid, p_register_id, v_order.event_id, 'ajuste',
                (v_item->>'qty')::numeric, v_ingredient_after,
                'Repuesto por anular ticket #' || v_order.ticket_num, null);
    end loop;
  end if;

  return true;
end;
$$;
grant execute on function pos.void_order(uuid, text, uuid) to anon, authenticated;

create or replace function pos.reopen_order(p_register_id uuid, p_pin text, p_order_id uuid)
returns boolean language plpgsql security definer set search_path = pos as $$
declare
  v_order pos.orders;
  v_item jsonb;
  v_sold_qty numeric;
  v_stock_after numeric;
  v_ingredient_after numeric;
begin
  if not (pos.verify_register_pin(p_register_id, p_pin) or pos.verify_despacho_pin(p_register_id, p_pin)) then
    raise exception 'PIN incorrecto';
  end if;

  select * into v_order from pos.orders where id = p_order_id and register_id = p_register_id;
  if v_order is null then raise exception 'Pedido no encontrado'; end if;

  update pos.orders set status = 'pendiente_entrega', delivered_at = null where id = p_order_id and register_id = p_register_id;

  -- Si el pedido que se reabre estaba ANULADO, hay que volver a descontar
  -- el stock/insumos (void_order se los había devuelto) — usando la misma
  -- foto de consumo original, no la receta actual — si no, el producto
  -- queda contado dos veces: una vez como repuesto y otra como vendido.
  if v_order.status = 'anulado' then
    for v_item in select * from jsonb_array_elements(v_order.items) loop
      if v_item ? 'id' then
        v_sold_qty := coalesce((v_item->>'qty')::numeric, 0);

        update pos.menu_items
          set stock_qty = greatest(0, stock_qty - v_sold_qty)
          where id = (v_item->>'id')::uuid and register_id = p_register_id
            and track_stock = true and stock_qty is not null
          returning stock_qty into v_stock_after;
        if found then
          insert into pos.stock_movements (menu_item_id, register_id, event_id, type, qty_change, qty_after, note, created_by)
            values ((v_item->>'id')::uuid, p_register_id, v_order.event_id, 'ajuste', -v_sold_qty, v_stock_after,
                    'Descontado de nuevo al reabrir ticket #' || v_order.ticket_num, null);
        end if;
      end if;
    end loop;

    if v_order.ingredient_consumption is not null then
      for v_item in select * from jsonb_array_elements(v_order.ingredient_consumption) loop
        update pos.ingredients
          set stock_qty = greatest(0, coalesce(stock_qty,0) - (v_item->>'qty')::numeric)
          where id = (v_item->>'ingredient_id')::uuid
          returning stock_qty into v_ingredient_after;
        insert into pos.stock_movements (ingredient_id, register_id, event_id, type, qty_change, qty_after, note, created_by)
          values ((v_item->>'ingredient_id')::uuid, p_register_id, v_order.event_id, 'ajuste',
                  -(v_item->>'qty')::numeric, v_ingredient_after,
                  'Descontado de nuevo al reabrir ticket #' || v_order.ticket_num, null);
      end loop;
    end if;
  end if;

  return true;
end;
$$;
grant execute on function pos.reopen_order(uuid, text, uuid) to anon, authenticated;

create or replace function pos.despacho_toggle_item(p_register_id uuid, p_despacho_pin text, p_order_id uuid, p_item_index int)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_despacho_pin(p_register_id, p_despacho_pin) then raise exception 'PIN incorrecto'; end if;
  -- Todo en un solo UPDATE (en vez de leer y luego escribir por separado):
  -- así, si dos personas tocan la pantalla de Entrega al mismo tiempo,
  -- Postgres serializa los cambios en vez de que uno pise el del otro.
  update pos.orders
    set items = jsonb_set(
      items, array[p_item_index::text, 'delivered'],
      to_jsonb(not coalesce((items->p_item_index->>'delivered')::boolean, false))
    )
    where id = p_order_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.despacho_toggle_item(uuid, text, uuid, int) to anon, authenticated;

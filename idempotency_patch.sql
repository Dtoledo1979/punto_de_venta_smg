-- =====================================================================
-- PROMPT 2 (auditoría externa, P0) — idempotencia de ventas: un
-- reintento tras un corte de red (o dos clics casi simultáneos en
-- "Pago confirmado") ya no puede crear una segunda venta ni descontar
-- stock dos veces.
--
-- create_order() cambia de firma (se le agregó p_client_transaction_id),
-- así que hay que borrar la versión anterior antes de crear la nueva o
-- quedan dos compitiendo.
-- =====================================================================

alter table pos.orders add column if not exists client_transaction_id uuid;

create unique index if not exists orders_client_transaction_id_key
  on pos.orders (client_transaction_id) where client_transaction_id is not null;

drop function if exists pos.create_order(uuid, text, uuid, jsonb, text, numeric, numeric, text, text, text, text, boolean);

create or replace function pos.create_order(
  p_register_id uuid, p_pin text, p_event_id uuid, p_items jsonb,
  p_payment_method text, p_cash numeric, p_card numeric,
  p_customer_name text, p_obs text, p_attended_by text,
  p_admin_pin text default null, p_is_test boolean default false,
  p_client_transaction_id uuid default null
) returns pos.orders language plpgsql security definer set search_path = pos as $$
declare
  v_register pos.registers;
  v_total numeric := 0;
  v_ticket_num int;
  v_status text;
  v_delivered_at timestamptz := null;
  v_order pos.orders;
  v_existing pos.orders;
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
  v_max_qty_per_line constant numeric := 500; -- tope de cordura por línea, no una regla de negocio real
begin
  -- Idempotencia: si ya existe un pedido con este identificador de intento
  -- de cobro (generado una sola vez en el navegador por cada venta),
  -- devolverlo tal cual en vez de crear uno nuevo. Esto cubre el caso de
  -- un reintento después de que la respuesta se perdió por un corte de
  -- red, pero el servidor ya había confirmado la venta la primera vez.
  if p_client_transaction_id is not null then
    select * into v_existing from pos.orders where client_transaction_id = p_client_transaction_id;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  select * into v_register from pos.registers where id = p_register_id;
  if v_register is null or v_register.pin <> p_pin then
    raise exception 'PIN incorrecto';
  end if;

  if p_payment_method = 'cortesia' then
    if p_admin_pin is null or not pos.verify_admin_pin(p_admin_pin) then
      raise exception 'Cortesía requiere PIN de administrador válido';
    end if;
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'El pedido no tiene productos';
  end if;

  -- =====================================================================
  -- PRECIO Y SUBTOTAL SIEMPRE LOS CALCULA EL SERVIDOR.
  -- El navegador solo puede decir "qué producto" y "cuánta cantidad" — el
  -- precio, si hay promoción vigente, y el subtotal de cada línea se
  -- recalculan acá adentro desde pos.menu_items/pos.promotions, sin
  -- confiar en ningún price/subtotal/name que venga en p_items. Antes de
  -- este cambio, alguien con las herramientas de desarrollador del
  -- navegador podía modificar el subtotal enviado y el sistema lo
  -- aceptaba tal cual.
  --
  -- Primero se agrega la cantidad por producto (por si el mismo id
  -- aparece más de una vez en el carrito recibido), y recién con esa
  -- cantidad total por producto se calcula el precio/promoción — así no
  -- importa cómo venga partido el pedido, el cálculo de la promoción es
  -- siempre sobre la cantidad real.
  -- =====================================================================
  for v_agg in
    select (elem->>'id')::uuid as item_id, sum(coalesce((elem->>'qty')::numeric, 0)) as qty
    from jsonb_array_elements(p_items) elem
    where elem ? 'id'
    group by (elem->>'id')::uuid
  loop
    if v_agg.qty is null or v_agg.qty <= 0 then
      raise exception 'Cantidad inválida para un producto del pedido';
    end if;
    if v_agg.qty > v_max_qty_per_line then
      raise exception 'Cantidad no razonable para un producto del pedido (máx %)', v_max_qty_per_line;
    end if;

    select * into v_menu_item from pos.menu_items
      where id = v_agg.item_id and register_id = p_register_id and active = true;
    if v_menu_item is null then
      raise exception 'Producto no encontrado en esta caja (id %)', v_agg.item_id;
    end if;

    select * into v_promo from pos.promotions
      where menu_item_id = v_agg.item_id and active = true
        and (starts_at is null or starts_at <= now())
        and (ends_at is null or ends_at >= now())
      order by created_at desc limit 1;

    if v_promo is not null and v_promo.bundle_qty > 0 then
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
      'delivered', (v_register.type = 'ticket')
    );
  end loop;

  if jsonb_array_length(v_resolved_items) = 0 then
    raise exception 'Ningún producto del pedido pudo resolverse — revisa que los ids sean válidos';
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
  -- Usa v_resolved_items (ya validado/agregado), no el p_items original.
  for v_item in select * from jsonb_array_elements(v_resolved_items) loop
    v_sold_qty := (v_item->>'qty')::numeric;
    for v_recipe_line in
      select ri.ingredient_id, ri.qty_per_unit from pos.recipe_items ri where ri.menu_item_id = (v_item->>'id')::uuid
    loop
      v_consumption := v_consumption || jsonb_build_object('ingredient_id', v_recipe_line.ingredient_id, 'qty', v_recipe_line.qty_per_unit * v_sold_qty);
    end loop;
  end loop;

  begin
    insert into pos.orders (
      register_id, event_id, ticket_num, items, total, payment_method,
      cash_amount, card_amount, customer_name, attended_by, status, obs, delivered_at,
      ingredient_consumption, is_test, client_transaction_id
    ) values (
      p_register_id, p_event_id, v_ticket_num, v_resolved_items, v_total, p_payment_method,
      coalesce(p_cash,0), coalesce(p_card,0), p_customer_name, p_attended_by, v_status, p_obs, v_delivered_at,
      v_consumption, coalesce(p_is_test, false), p_client_transaction_id
    ) returning * into v_order;
  exception
    when unique_violation then
      -- Dos peticiones con el mismo identificador llegaron casi al mismo
      -- tiempo y la otra ganó la carrera — devolvemos esa venta ya creada
      -- en vez de crear una segunda o descontar stock dos veces. El N° de
      -- ticket que se le había asignado a este intento perdedor queda sin
      -- usar (un salto en la numeración), lo cual es preferible a cobrar
      -- dos veces por la misma venta.
      select * into v_order from pos.orders where client_transaction_id = p_client_transaction_id;
      return v_order;
  end;

  -- En modo prueba no se toca inventario real: el pedido igual queda
  -- creado (para poder imprimir y probar el flujo de Entrega completo),
  -- pero el stock de productos e insumos no se descuenta.
  if not coalesce(p_is_test, false) then

  -- Descontar stock de los productos vendidos que lo tengan activado.
  -- IMPORTANTE: solo toca stock_qty, nunca initial_stock (esa es la base
  -- del % restante — reiniciarla en cada venta es el bug que hacía que
  -- siempre marcara 100%).
  for v_item in select * from jsonb_array_elements(v_resolved_items) loop
    v_sold_qty := (v_item->>'qty')::numeric;

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
grant execute on function pos.create_order(uuid, text, uuid, jsonb, text, numeric, numeric, text, text, text, text, boolean, uuid) to anon, authenticated;

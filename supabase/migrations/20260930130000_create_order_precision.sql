-- =====================================================================
-- Precisión de dinero en create_order.
--
-- 1. Efectivo + tarjeta tiene que coincidir con el total AL CENTAVO. Antes
--    se aceptaba $1 de diferencia (pensado para pesos chilenos sin
--    decimales); en NZD eso permitía cobrar $0.99 menos o más sin error.
-- 2. Los montos tienen que ser coherentes con el método: efectivo sin
--    tarjeta, tarjeta sin efectivo, mixto con ambos, cortesía en cero.
--    Así los reportes de efectivo/tarjeta cuadran siempre.
-- 3. Cantidades enteras por producto (no se venden 1.5 Piscolas).
-- =====================================================================

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
begin
  -- Autorización PRIMERO (antes, la búsqueda por idempotencia iba antes
  -- del PIN: cualquiera que conociera un client_transaction_id podía leer
  -- ese pedido sin PIN).
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;

  -- Idempotencia: si este intento de cobro ya se registró en esta caja,
  -- devolver esa misma venta en vez de crear otra.
  if p_client_transaction_id is not null then
    select * into v_order from pos.orders
      where client_transaction_id = p_client_transaction_id and register_id = v_reg.id;
    if v_order.id is not null then return v_order; end if;
  end if;

  if p_payment_method not in ('efectivo','tarjeta','mixto','cortesia') then
    raise exception 'Método de pago inválido';
  end if;

  -- Cortesía: siempre exige el PIN de supervisor (en un dispositivo
  -- compartido el rol de la cuenta no identifica a quien está cobrando).
  -- Un PIN de supervisor incorrecto devuelve null (no lanza) para que el
  -- intento fallido quede registrado.
  if p_payment_method = 'cortesia' and not pos._check_supervisor_pin(v_reg.org_id, p_supervisor_pin) then
    return null;
  end if;

  -- Montos: nunca negativos, y coherentes con el método de pago elegido.
  if coalesce(p_cash, 0) < 0 or coalesce(p_card, 0) < 0 then
    raise exception 'Los montos de pago no pueden ser negativos';
  end if;
  if (p_payment_method = 'efectivo' and coalesce(p_card, 0) <> 0)
     or (p_payment_method = 'tarjeta' and coalesce(p_cash, 0) <> 0)
     or (p_payment_method = 'mixto' and (coalesce(p_cash, 0) <= 0 or coalesce(p_card, 0) <= 0))
     or (p_payment_method = 'cortesia' and (coalesce(p_cash, 0) <> 0 or coalesce(p_card, 0) <> 0)) then
    raise exception 'Los montos no coinciden con el método de pago (%)', p_payment_method;
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El pedido no tiene productos';
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
      raise exception 'Cantidad inválida para un producto del pedido';
    end if;
    if v_agg.qty <> trunc(v_agg.qty) then
      raise exception 'La cantidad de un producto tiene que ser un número entero';
    end if;
    if v_agg.qty > v_max_qty_per_line then
      raise exception 'Cantidad no razonable para un producto del pedido (máx %)', v_max_qty_per_line;
    end if;

    select * into v_menu_item from pos.menu_items
      where id = v_agg.item_id and register_id = v_reg.id and active = true;
    if v_menu_item.id is null then
      raise exception 'Producto no encontrado en esta caja (id %)', v_agg.item_id;
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
      'delivered', (v_reg.type = 'ticket')
    );
  end loop;

  if jsonb_array_length(v_resolved_items) = 0 then
    raise exception 'Ningún producto del pedido pudo resolverse — revisa que los ids sean válidos';
  end if;

  if p_payment_method <> 'cortesia' and v_total <= 0 then
    raise exception 'El total del pedido debe ser mayor a cero';
  end if;

  -- Exacto al centavo (antes se aceptaba hasta $1 de diferencia, herencia
  -- de pesos chilenos sin decimales — en NZD eso es plata real).
  v_total := round(v_total, 2);
  if p_payment_method <> 'cortesia' and round(coalesce(p_cash,0) + coalesce(p_card,0), 2) <> v_total then
    raise exception 'El efectivo + tarjeta (%) no coincide con el total (%)', round(coalesce(p_cash,0) + coalesce(p_card,0), 2), v_total;
  end if;

  -- Numeración por caja + evento. La FK compuesta (event_id, org_id)
  -- rechaza un evento de otra organización.
  if p_event_id is not null then
    insert into pos.ticket_counters (org_id, register_id, event_id, next_ticket)
      values (v_reg.org_id, v_reg.id, p_event_id, 2)
      on conflict (register_id, event_id) do update set next_ticket = pos.ticket_counters.next_ticket + 1
      returning next_ticket - 1 into v_ticket_num;
  else
    raise exception 'El pedido tiene que pertenecer a un evento';
  end if;

  if v_reg.type = 'ticket' then
    v_status := 'entregado';
    v_delivered_at := now();
  else
    v_status := 'pendiente_entrega';
  end if;

  -- Foto de consumo de insumos, guardada con el pedido: anular después
  -- devuelve exactamente lo que se descontó hoy, aunque la receta cambie.
  for v_item in select * from jsonb_array_elements(v_resolved_items) loop
    v_sold_qty := (v_item->>'qty')::numeric;
    for v_recipe_line in
      select ri.ingredient_id, ri.qty_per_unit from pos.recipe_items ri
      where ri.menu_item_id = (v_item->>'id')::uuid and ri.register_id = v_reg.id
    loop
      v_consumption := v_consumption || jsonb_build_object('ingredient_id', v_recipe_line.ingredient_id, 'qty', v_recipe_line.qty_per_unit * v_sold_qty);
    end loop;
  end loop;

  begin
    insert into pos.orders (
      org_id, register_id, event_id, ticket_num, items, total, payment_method,
      cash_amount, card_amount, customer_name, attended_by, sold_by_user, status, obs, delivered_at,
      ingredient_consumption, is_test, client_transaction_id
    ) values (
      v_reg.org_id, v_reg.id, p_event_id, v_ticket_num, v_resolved_items, v_total, p_payment_method,
      coalesce(p_cash,0), coalesce(p_card,0), p_customer_name, p_attended_by, auth.uid(), v_status, p_obs, v_delivered_at,
      v_consumption, coalesce(p_is_test, false), p_client_transaction_id
    ) returning * into v_order;
  exception
    when unique_violation then
      -- Otra petición con el mismo identificador ganó la carrera: devolver
      -- esa venta (de ESTA caja) en vez de crear otra o descontar dos veces.
      select * into v_order from pos.orders
        where client_transaction_id = p_client_transaction_id and register_id = v_reg.id;
      if v_order.id is null then raise exception 'Identificador de transacción inválido'; end if;
      return v_order;
  end;

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
          values (v_reg.org_id, v_reg.id, (v_item->>'id')::uuid, p_event_id, 'venta', -v_sold_qty, v_stock_after, p_attended_by, auth.uid());
      end if;
    end loop;

    for v_item in select * from jsonb_array_elements(v_consumption) loop
      update pos.ingredients
        set stock_qty = coalesce(stock_qty, 0) - (v_item->>'qty')::numeric
        where id = (v_item->>'ingredient_id')::uuid and register_id = v_reg.id
        returning stock_qty into v_ingredient_after;

      if found then
        insert into pos.stock_movements (org_id, register_id, ingredient_id, event_id, type, qty_change, qty_after, created_by, created_by_user)
          values (v_reg.org_id, v_reg.id, (v_item->>'ingredient_id')::uuid, p_event_id, 'venta',
                  -(v_item->>'qty')::numeric, v_ingredient_after, p_attended_by, auth.uid());
      end if;
    end loop;

  end if; -- not is_test

  return v_order;
end;
$$;

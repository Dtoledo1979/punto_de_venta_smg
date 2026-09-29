-- =====================================================================
-- Fase 2 — Pagos, reembolsos y auditoría.
--
-- 1. pos.payments: libro de pagos. Cada cobro aprobado (efectivo y/o
--    tarjeta), cada intento de tarjeta RECHAZADO o CANCELADO (sin pedido:
--    nunca genera venta, stock ni boleta) y cada devolución de dinero.
-- 2. pos.refunds: reembolsos totales o parciales por línea, con motivo y
--    opcionalmente devolviendo el stock. Exigen PIN de supervisor.
-- 3. pos.audit_log: registro de acciones sensibles, escrito por TRIGGERS
--    (no depende de que cada función se acuerde de registrar) e
--    inmutable (nadie puede editarlo ni borrarlo, ni siquiera por error
--    desde una función).
-- 4. Guardas en pos.orders: los datos financieros de una venta (total,
--    montos, líneas, precios) no se pueden modificar después de creada, y
--    solo se permiten las transiciones de estado válidas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Pedidos: total reembolsado y destino de FKs compuestas
-- ---------------------------------------------------------------------
alter table pos.orders
  add column refunded_total numeric(10,2) not null default 0 check (refunded_total >= 0),
  add constraint orders_refund_le_total check (refunded_total <= total),
  add constraint orders_id_org_key unique (id, org_id);

alter table pos.stock_movements drop constraint stock_movements_type_check;
alter table pos.stock_movements add constraint stock_movements_type_check
  check (type in ('opening_stock','purchase','sale','adjustment','void_return','reopen_sale','refund_return'));

-- ---------------------------------------------------------------------
-- Reembolsos
-- lines = [{"index": 0, "qty": 1, "amount": 12.50}, ...] (índice de la
-- línea dentro de orders.items). El monto de cada línea es proporcional a
-- su subtotal real (incluye promociones); la última unidad de una línea se
-- lleva el resto, así la suma de reembolsos nunca pasa del subtotal.
-- ---------------------------------------------------------------------
create table pos.refunds (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references pos.organizations(id) on delete cascade,
  register_id           uuid not null,
  order_id              uuid not null,
  amount                numeric(10,2) not null check (amount > 0),
  method                text not null check (method in ('cash','card')),
  reason                text not null check (reason in ('wrong_item','quality','changed_mind','overcharged','other')),
  note                  text,
  lines                 jsonb not null,
  restocked             boolean not null default false,
  is_test               boolean not null default false,
  client_transaction_id uuid unique,
  operator_name         text,
  created_by_user       uuid references auth.users(id) on delete set null,
  created_at            timestamptz not null default now(),
  unique (id, org_id),
  foreign key (register_id, org_id) references pos.registers(id, org_id),
  foreign key (order_id, org_id) references pos.orders(id, org_id)
);
create index refunds_order_idx on pos.refunds (order_id);
create index refunds_org_created_idx on pos.refunds (org_id, created_at);

-- ---------------------------------------------------------------------
-- Pagos
-- ---------------------------------------------------------------------
create table pos.payments (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references pos.organizations(id) on delete cascade,
  register_id           uuid not null,
  order_id              uuid,          -- null: intento rechazado/cancelado (nunca hubo venta)
  refund_id             uuid,          -- devoluciones
  kind                  text not null check (kind in ('payment','refund')),
  method                text not null check (method in ('cash','card')),
  amount                numeric(10,2) not null check (amount > 0),
  status                text not null check (status in ('approved','declined','cancelled','voided')),
  is_test               boolean not null default false,
  client_transaction_id uuid,
  operator_name         text,
  created_by_user       uuid references auth.users(id) on delete set null,
  created_at            timestamptz not null default now(),
  foreign key (register_id, org_id) references pos.registers(id, org_id),
  foreign key (order_id, org_id) references pos.orders(id, org_id),
  foreign key (refund_id, org_id) references pos.refunds(id, org_id),
  constraint payments_shape_chk check (
    (kind = 'payment' and refund_id is null and (order_id is not null or status in ('declined','cancelled'))) or
    (kind = 'refund'  and refund_id is not null and order_id is not null and status = 'approved')
  )
);
create index payments_order_idx on pos.payments (order_id);
create index payments_org_created_idx on pos.payments (org_id, created_at);

-- ---------------------------------------------------------------------
-- Auditoría
-- ---------------------------------------------------------------------
create table pos.audit_log (
  id            bigint generated always as identity primary key,
  org_id        uuid not null references pos.organizations(id) on delete cascade,
  register_id   uuid,
  action        text not null,
  entity_type   text not null,
  entity_id     uuid,
  details       jsonb not null default '{}'::jsonb,
  operator_name text,
  actor_user    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index audit_org_created_idx on pos.audit_log (org_id, created_at desc);

-- Inmutable: ni actualizar ni borrar filas, desde ningún rol. (Borrar la
-- organización completa sí elimina su auditoría, vía cascade.)
create function pos._audit_immutable() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from pos.organizations where id = old.org_id) then
    return old; -- cascade por borrado de la organización
  end if;
  raise exception 'audit.immutable';
end;
$$;
create trigger audit_log_immutable before update or delete on pos.audit_log
  for each row execute function pos._audit_immutable();

-- Registro. El nombre de quien opera la caja (texto libre, informativo) lo
-- dejan las funciones en la variable de sesión pos.operator.
create function pos._audit(p_org uuid, p_register uuid, p_action text, p_entity_type text, p_entity_id uuid, p_details jsonb)
returns void
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  insert into pos.audit_log (org_id, register_id, action, entity_type, entity_id, details, operator_name, actor_user)
  values (p_org, p_register, p_action, p_entity_type, p_entity_id, coalesce(p_details, '{}'::jsonb),
          nullif(current_setting('pos.operator', true), ''), auth.uid());
end;
$$;

-- ---------------------------------------------------------------------
-- Guardas de pedidos
-- ---------------------------------------------------------------------
create function pos._orders_guard() returns trigger
language plpgsql as $$
declare v_old_lines jsonb; v_new_lines jsonb;
begin
  -- Lo financiero de una venta no cambia nunca después de creada.
  if new.org_id <> old.org_id or new.register_id <> old.register_id or new.event_id is distinct from old.event_id
     or new.ticket_num <> old.ticket_num or new.total <> old.total or new.payment_method <> old.payment_method
     or new.cash_amount <> old.cash_amount or new.card_amount <> old.card_amount or new.is_test <> old.is_test
     or new.paid_at <> old.paid_at or new.client_transaction_id is distinct from old.client_transaction_id
     or new.ingredient_consumption is distinct from old.ingredient_consumption then
    raise exception 'order.immutable';
  end if;
  -- Las líneas solo pueden cambiar su marca de "entregado".
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
    if new.status = 'voided' and new.refunded_total > 0 then
      raise exception 'order.has_refunds';
    end if;
  end if;
  return new;
end;
$$;
create trigger orders_guard before update on pos.orders
  for each row execute function pos._orders_guard();

-- Pagos: solo cambia el estado de un pago aprobado al anular (voided) o
-- al reabrir (vuelve a approved). Nada más.
create function pos._payments_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if not exists (select 1 from pos.organizations where id = old.org_id) then return old; end if; -- cascade
    raise exception 'payment.immutable';
  end if;
  if (to_jsonb(new) - 'status') <> (to_jsonb(old) - 'status')
     or not ((old.status, new.status) in (('approved','voided'), ('voided','approved'))) or new.kind <> 'payment' then
    raise exception 'payment.immutable';
  end if;
  return new;
end;
$$;
create trigger payments_guard before update or delete on pos.payments
  for each row execute function pos._payments_guard();

create function pos._refunds_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from pos.organizations where id = old.org_id) then return old; end if; -- cascade
  raise exception 'refund.immutable';
end;
$$;
create trigger refunds_guard before update or delete on pos.refunds
  for each row execute function pos._refunds_guard();

-- ---------------------------------------------------------------------
-- Triggers de auditoría (security definer: pueden escribir en audit_log)
-- ---------------------------------------------------------------------
create function pos._audit_orders() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    if new.payment_method = 'complimentary' then
      perform pos._audit(new.org_id, new.register_id, 'order.complimentary', 'order', new.id,
        jsonb_build_object('ticket', new.ticket_num, 'reference_value', new.total, 'is_test', new.is_test));
    end if;
  elsif new.status <> old.status and (new.status = 'voided' or old.status = 'voided' or old.status = 'delivered' and new.status = 'pending_delivery') then
    perform pos._audit(new.org_id, new.register_id,
      case when new.status = 'voided' then 'order.void' else 'order.reopen' end, 'order', new.id,
      jsonb_build_object('ticket', new.ticket_num, 'total', new.total, 'from', old.status, 'to', new.status, 'is_test', new.is_test));
  end if;
  return null;
end;
$$;
create trigger orders_audit after insert or update on pos.orders
  for each row execute function pos._audit_orders();

create function pos._audit_refunds() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._audit(new.org_id, new.register_id, 'order.refund', 'order', new.order_id,
    jsonb_build_object('refund_id', new.id, 'amount', new.amount, 'method', new.method, 'reason', new.reason,
                       'restocked', new.restocked, 'lines', new.lines, 'is_test', new.is_test));
  return null;
end;
$$;
create trigger refunds_audit after insert on pos.refunds
  for each row execute function pos._audit_refunds();

create function pos._audit_payments() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if new.status in ('declined','cancelled') then
    perform pos._audit(new.org_id, new.register_id, 'payment.' || new.status, 'payment', new.id,
      jsonb_build_object('method', new.method, 'amount', new.amount, 'is_test', new.is_test));
  end if;
  return null;
end;
$$;
create trigger payments_audit after insert on pos.payments
  for each row execute function pos._audit_payments();

create function pos._audit_menu_items() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    perform pos._audit(new.org_id, new.register_id, 'menu.add', 'menu_item', new.id,
      jsonb_build_object('name', new.name, 'price', new.price));
  elsif new.active is distinct from old.active and not new.active then
    perform pos._audit(new.org_id, new.register_id, 'menu.remove', 'menu_item', new.id, jsonb_build_object('name', new.name));
  elsif new.price is distinct from old.price or new.name is distinct from old.name then
    perform pos._audit(new.org_id, new.register_id, 'menu.update', 'menu_item', new.id,
      jsonb_build_object('old_name', old.name, 'new_name', new.name, 'old_price', old.price, 'new_price', new.price));
  end if;
  return null;
end;
$$;
create trigger menu_items_audit after insert or update on pos.menu_items
  for each row execute function pos._audit_menu_items();

-- Receta: un registro por sentencia (set_recipe reemplaza la receta entera).
create function pos._audit_recipe() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_row record;
begin
  for v_row in select distinct org_id, register_id, menu_item_id from changed_rows loop
    perform pos._audit(v_row.org_id, v_row.register_id, 'recipe.change', 'menu_item', v_row.menu_item_id,
      jsonb_build_object('recipe', coalesce((select jsonb_agg(jsonb_build_object('ingredient_id', ri.ingredient_id, 'qty_per_unit', ri.qty_per_unit))
                                            from pos.recipe_items ri where ri.menu_item_id = v_row.menu_item_id), '[]'::jsonb)));
  end loop;
  return null;
end;
$$;
create trigger recipe_items_audit_ins after insert on pos.recipe_items
  referencing new table as changed_rows for each statement execute function pos._audit_recipe();
create trigger recipe_items_audit_del after delete on pos.recipe_items
  referencing old table as changed_rows for each statement execute function pos._audit_recipe();

-- Stock: cargas, reposiciones y ajustes manuales (las ventas y devoluciones
-- automáticas ya quedan en stock_movements ligadas al pedido).
create function pos._audit_stock() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if new.type in ('opening_stock','purchase','adjustment') then
    perform pos._audit(new.org_id, new.register_id, 'stock.' || new.type,
      case when new.menu_item_id is not null then 'menu_item' else 'ingredient' end,
      coalesce(new.menu_item_id, new.ingredient_id),
      jsonb_build_object('qty_change', new.qty_change, 'qty_after', new.qty_after));
  end if;
  return null;
end;
$$;
create trigger stock_movements_audit after insert on pos.stock_movements
  for each row execute function pos._audit_stock();

create function pos._audit_registers() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    perform pos._audit(new.org_id, new.id, 'register.create', 'register', new.id,
      jsonb_build_object('name', new.name, 'type', new.type, 'location_id', new.location_id));
  else
    perform pos._audit(new.org_id, new.id, 'register.update', 'register', new.id,
      jsonb_build_object('old_name', old.name, 'new_name', new.name,
                         'pin_changed', new.pin_hash <> old.pin_hash,
                         'delivery_pin_changed', new.despacho_pin_hash <> old.despacho_pin_hash,
                         'active', new.active));
  end if;
  return null;
end;
$$;
create trigger registers_audit after insert or update on pos.registers
  for each row execute function pos._audit_registers();

create function pos._audit_org_secrets() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if tg_op = 'UPDATE' then
    perform pos._audit(new.org_id, null, 'supervisor_pin.change', 'organization', new.org_id, '{}'::jsonb);
  end if;
  return null;
end;
$$;
create trigger org_secrets_audit after update on pos.org_secrets
  for each row execute function pos._audit_org_secrets();

create function pos._audit_memberships() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    perform pos._audit(new.org_id, null, 'member.add', 'user', new.user_id, jsonb_build_object('role', new.role));
  elsif new.role <> old.role or new.status <> old.status then
    perform pos._audit(new.org_id, null, 'member.update', 'user', new.user_id,
      jsonb_build_object('old_role', old.role, 'new_role', new.role, 'old_status', old.status, 'new_status', new.status));
  end if;
  return null;
end;
$$;
create trigger memberships_audit after insert or update on pos.memberships
  for each row execute function pos._audit_memberships();

create function pos._audit_events() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if new.active is distinct from old.active then
    perform pos._audit(new.org_id, null, case when new.active then 'event.reopen' else 'event.close' end, 'event', new.id,
      jsonb_build_object('name', new.name));
  end if;
  return null;
end;
$$;
create trigger events_audit after update on pos.events
  for each row execute function pos._audit_events();

create function pos._audit_organizations() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._audit(new.id, null, 'org.update', 'organization', new.id,
    jsonb_build_object('old', jsonb_build_object('name', old.name, 'language', old.language, 'locale', old.locale, 'status', old.status),
                       'new', jsonb_build_object('name', new.name, 'language', new.language, 'locale', new.locale, 'status', new.status)));
  return null;
end;
$$;
create trigger organizations_audit after update on pos.organizations
  for each row when (old.* is distinct from new.*) execute function pos._audit_organizations();

create function pos._audit_promotions() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_row pos.promotions;
begin
  v_row := case when tg_op = 'DELETE' then old else new end;
  perform pos._audit(v_row.org_id, v_row.register_id, 'promotion.' || lower(tg_op), 'menu_item', v_row.menu_item_id,
    jsonb_build_object('bundle_qty', v_row.bundle_qty, 'bundle_price', v_row.bundle_price, 'active', v_row.active));
  return null;
end;
$$;
create trigger promotions_audit after insert or update or delete on pos.promotions
  for each row execute function pos._audit_promotions();

-- ---------------------------------------------------------------------
-- Funciones existentes que cambian (misma firma: conservan sus permisos)
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
      'delivered', (v_reg.type = 'ticket')
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
      if v_order.id is null then raise exception 'order.invalid_transaction'; end if;
      return v_order;
  end;

  -- Libro de pagos: una fila por medio de pago aprobado (las cortesías no
  -- tienen pago). Los caminos de idempotencia de arriba retornan antes de
  -- llegar acá, así un reintento nunca duplica pagos.
  if coalesce(p_cash, 0) > 0 then
    insert into pos.payments (org_id, register_id, order_id, kind, method, amount, status, is_test, client_transaction_id, operator_name, created_by_user)
      values (v_reg.org_id, v_reg.id, v_order.id, 'payment', 'cash', p_cash, 'approved', v_order.is_test, p_client_transaction_id, p_attended_by, auth.uid());
  end if;
  if coalesce(p_card, 0) > 0 then
    insert into pos.payments (org_id, register_id, order_id, kind, method, amount, status, is_test, client_transaction_id, operator_name, created_by_user)
      values (v_reg.org_id, v_reg.id, v_order.id, 'payment', 'card', p_card, 'approved', v_order.is_test, p_client_transaction_id, p_attended_by, auth.uid());
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

create or replace function pos.void_order(p_register_id uuid, p_pin text, p_order_id uuid)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_order pos.orders;
begin
  v_reg := pos._register_with_any_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;

  -- Transición atómica: solo tiene efecto si el pedido NO estaba anulado.
  -- Si dos dispositivos anulan a la vez, solo uno repone stock.
  update pos.orders set status = 'voided'
    where id = p_order_id and register_id = v_reg.id and status <> 'voided'
    returning * into v_order;

  if not found then
    if not exists (select 1 from pos.orders where id = p_order_id and register_id = v_reg.id) then
      raise exception 'order.not_found';
    end if;
    return true; -- ya estaba anulado
  end if;

  -- Los pedidos de prueba nunca descontaron stock real: no se repone nada.
  if not v_order.is_test then
    perform pos._apply_order_stock(v_order, 1, 'void_return');
  end if;
  update pos.payments set status = 'voided' where order_id = v_order.id and kind = 'payment' and status = 'approved';
  return true;
end;
$$;

create or replace function pos.reopen_order(p_register_id uuid, p_pin text, p_order_id uuid)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_order pos.orders;
begin
  v_reg := pos._register_with_any_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;

  -- Transición atómica anulado -> reabierto: solo la llamada que la gana
  -- vuelve a descontar stock (protege contra un doble descuento).
  update pos.orders set status = 'pending_delivery', delivered_at = null
    where id = p_order_id and register_id = v_reg.id and status = 'voided'
    returning * into v_order;

  if not found then
    -- No estaba anulado (ej. "entregado" que se reabre para corregir):
    -- no hay stock que mover, solo cambia el estado.
    update pos.orders set status = 'pending_delivery', delivered_at = null
      where id = p_order_id and register_id = v_reg.id;
    if not found then raise exception 'order.not_found'; end if;
    return true;
  end if;

  if not v_order.is_test then
    perform pos._apply_order_stock(v_order, -1, 'reopen_sale');
  end if;
  update pos.payments set status = 'approved' where order_id = v_order.id and kind = 'payment' and status = 'voided';
  return true;
end;
$$;

create or replace function pos.restock_item(
  p_register_id uuid, p_pin text, p_item_id uuid, p_mode text, p_qty numeric,
  p_note text default null, p_by text default null
) returns pos.menu_items
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_reg pos.registers;
  v_item pos.menu_items;
  v_new_stock numeric;
  v_new_initial numeric;
  v_type text;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);

  select * into v_item from pos.menu_items where id = p_item_id and register_id = v_reg.id for update;
  if v_item.id is null then raise exception 'product.not_found'; end if;

  if p_mode = 'reset' then
    v_new_stock := p_qty; v_new_initial := p_qty; v_type := 'opening_stock';
  elsif p_mode = 'add' then
    v_new_stock := coalesce(v_item.stock_qty, 0) + p_qty;
    v_new_initial := coalesce(v_item.initial_stock, 0) + p_qty;
    v_type := 'purchase';
  else
    raise exception 'stock.invalid_mode';
  end if;

  update pos.menu_items set track_stock = true, stock_qty = v_new_stock, initial_stock = v_new_initial
    where id = p_item_id and register_id = v_reg.id returning * into v_item;

  insert into pos.stock_movements (org_id, register_id, menu_item_id, type, qty_change, qty_after, note, created_by, created_by_user)
    values (v_reg.org_id, v_reg.id, p_item_id, v_type, p_qty, v_new_stock, p_note, p_by, auth.uid());

  return v_item;
end;
$$;

create or replace function pos.restock_ingredient(
  p_register_id uuid, p_pin text, p_ingredient_id uuid, p_mode text, p_qty numeric, p_by text default null
) returns pos.ingredients
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_reg pos.registers;
  v_row pos.ingredients;
  v_new_stock numeric;
  v_new_initial numeric;
  v_type text;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);

  select * into v_row from pos.ingredients where id = p_ingredient_id and register_id = v_reg.id for update;
  if v_row.id is null then raise exception 'ingredient.not_found'; end if;

  if p_mode = 'reset' then
    v_new_stock := p_qty; v_new_initial := p_qty; v_type := 'opening_stock';
  elsif p_mode = 'add' then
    v_new_stock := coalesce(v_row.stock_qty, 0) + p_qty;
    v_new_initial := coalesce(v_row.initial_stock, 0) + p_qty;
    v_type := 'purchase';
  else
    raise exception 'stock.invalid_mode';
  end if;

  update pos.ingredients set stock_qty = v_new_stock, initial_stock = v_new_initial
    where id = p_ingredient_id and register_id = v_reg.id returning * into v_row;

  insert into pos.stock_movements (org_id, register_id, ingredient_id, type, qty_change, qty_after, created_by, created_by_user)
    values (v_reg.org_id, v_reg.id, p_ingredient_id, v_type, p_qty, v_new_stock, p_by, auth.uid());

  return v_row;
end;
$$;

create or replace function pos.despacho_confirm_all(p_register_id uuid, p_despacho_pin text, p_order_id uuid, p_delivered_by text)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_despacho_pin(p_register_id, p_despacho_pin);
  if v_reg.id is null then return false; end if;
  perform set_config('pos.operator', coalesce(p_delivered_by, ''), true);
  -- Un solo UPDATE (antes era leer + escribir por separado).
  update pos.orders set
    items = (select jsonb_agg(elem || '{"delivered":true}'::jsonb) from jsonb_array_elements(items) elem),
    status = 'delivered', delivered_at = now(), delivered_by = p_delivered_by
  where id = p_order_id and register_id = v_reg.id and status = 'pending_delivery';
  return true;
end;
$$;

create or replace function pos.reset_ticket_numbering(p_register_id uuid, p_event_id uuid, p_start_at int default 1)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  select * into v_reg from pos.registers where id = p_register_id;
  if v_reg.id is null then raise exception 'register.not_found'; end if;
  perform pos._require_org_role(v_reg.org_id, array['owner','admin']);
  if p_start_at is null or p_start_at < 1 then raise exception 'ticket.invalid_start'; end if;
  -- La FK compuesta (event_id, org_id) rechaza un evento de otra organización.
  insert into pos.ticket_counters (org_id, register_id, event_id, next_ticket)
    values (v_reg.org_id, p_register_id, p_event_id, p_start_at)
    on conflict (register_id, event_id) do update set next_ticket = p_start_at;
  perform pos._audit(v_reg.org_id, v_reg.id, 'ticket.reset_numbering', 'event', p_event_id, jsonb_build_object('start_at', p_start_at));
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Intento de pago con tarjeta rechazado o cancelado: queda registrado
-- (auditoría, conciliación con el terminal) pero NO crea pedido, NO toca
-- stock, NO suma ventas y NO imprime nada.
-- ---------------------------------------------------------------------
create function pos.record_payment_attempt(
  p_register_id uuid, p_pin text, p_amount numeric, p_status text,
  p_operator text default null, p_is_test boolean default false, p_client_transaction_id uuid default null
) returns uuid
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_id uuid;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  if p_status not in ('declined','cancelled') then raise exception 'payment.invalid_attempt'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'payment.invalid_attempt'; end if;
  perform set_config('pos.operator', coalesce(p_operator, ''), true);
  insert into pos.payments (org_id, register_id, order_id, kind, method, amount, status, is_test, client_transaction_id, operator_name, created_by_user)
    values (v_reg.org_id, v_reg.id, null, 'payment', 'card', round(p_amount, 2), p_status, coalesce(p_is_test, false), p_client_transaction_id, p_operator, auth.uid())
    returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Reembolso total o parcial.
--   p_lines = [{"index": 0, "qty": 1}, ...]  (índice en orders.items)
-- Reglas:
--   * PIN de caja/Entrega + PIN de supervisor (PIN incorrecto → null).
--   * Idempotente por p_client_transaction_id.
--   * Nunca más unidades que las vendidas (sumando reembolsos previos).
--   * Monto por línea proporcional a su subtotal real (con promociones);
--     la última unidad se lleva el resto → la suma nunca pasa del subtotal.
--   * Nunca más dinero por un medio (efectivo/tarjeta) que lo cobrado por
--     ese medio.
--   * p_restock = true devuelve el stock (producto y, si el pedido guardó
--     la foto por producto, sus insumos). Por defecto NO: lo normal es que
--     lo reembolsado se haya consumido o tirado.
-- ---------------------------------------------------------------------
create function pos.refund_order(
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
  v_paid_method numeric; v_refunded_method numeric; v_after numeric; v_cons jsonb; v_ing_qty numeric;
  v_restock boolean;
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

  -- Bloquea el pedido: dos reembolsos simultáneos se serializan.
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

  v_restock := coalesce(p_restock, false) and not v_order.is_test;
  begin
    insert into pos.refunds (org_id, register_id, order_id, amount, method, reason, note, lines, restocked,
                             is_test, client_transaction_id, operator_name, created_by_user)
      values (v_reg.org_id, v_reg.id, v_order.id, v_total, p_method, p_reason, p_note, v_lines, v_restock,
              v_order.is_test, p_client_transaction_id, p_operator, auth.uid())
      returning * into v_ref;
  exception when unique_violation then
    select * into v_ref from pos.refunds where client_transaction_id = p_client_transaction_id and register_id = v_reg.id;
    if v_ref.id is null then raise exception 'order.invalid_transaction'; end if;
    return v_ref;
  end;

  insert into pos.payments (org_id, register_id, order_id, refund_id, kind, method, amount, status, is_test, client_transaction_id, operator_name, created_by_user)
    values (v_reg.org_id, v_reg.id, v_order.id, v_ref.id, 'refund', p_method, v_total, 'approved', v_order.is_test, p_client_transaction_id, p_operator, auth.uid());
  update pos.orders set refunded_total = refunded_total + v_total where id = v_order.id;

  if v_restock then
    for v_line in select * from jsonb_array_elements(v_lines) loop
      update pos.menu_items set stock_qty = stock_qty + (v_line->>'qty')::numeric
        where id = (v_line->>'id')::uuid and register_id = v_reg.id and track_stock = true and stock_qty is not null
        returning stock_qty into v_after;
      if found then
        insert into pos.stock_movements (org_id, register_id, menu_item_id, event_id, type, qty_change, qty_after, created_by, created_by_user)
          values (v_reg.org_id, v_reg.id, (v_line->>'id')::uuid, v_order.event_id, 'refund_return', (v_line->>'qty')::numeric, v_after, p_operator, auth.uid());
      end if;
      -- Insumos: proporcional a la foto de consumo de ESA línea.
      for v_cons in
        select c from jsonb_array_elements(coalesce(v_order.ingredient_consumption, '[]'::jsonb)) c
        where c->>'menu_item_id' = v_line->>'id'
      loop
        v_ing_qty := round((v_cons->>'qty')::numeric * (v_line->>'qty')::numeric / (v_line->>'item_qty')::numeric, 3);
        update pos.ingredients set stock_qty = coalesce(stock_qty, 0) + v_ing_qty
          where id = (v_cons->>'ingredient_id')::uuid and register_id = v_reg.id
          returning stock_qty into v_after;
        if found then
          insert into pos.stock_movements (org_id, register_id, ingredient_id, event_id, type, qty_change, qty_after, created_by, created_by_user)
            values (v_reg.org_id, v_reg.id, (v_cons->>'ingredient_id')::uuid, v_order.event_id, 'refund_return', v_ing_qty, v_after, p_operator, auth.uid());
        end if;
      end loop;
    end loop;
  end if;

  return v_ref;
end;
$$;

-- ---------------------------------------------------------------------
-- RLS y permisos de las tablas nuevas
-- ---------------------------------------------------------------------
alter table pos.payments  enable row level security;
alter table pos.refunds   enable row level security;
alter table pos.audit_log enable row level security;

create policy tenant_select on pos.payments for select to authenticated using (org_id in (select pos.user_org_ids()));
create policy tenant_select on pos.refunds  for select to authenticated using (org_id in (select pos.user_org_ids()));
-- La auditoría solo la ven quienes administran.
create policy audit_select on pos.audit_log for select to authenticated
  using (pos.has_org_role(org_id, array['owner','admin','manager']));

revoke all on pos.payments, pos.refunds, pos.audit_log from anon, authenticated, public;
grant select on pos.payments, pos.refunds, pos.audit_log to authenticated;
grant all on pos.payments, pos.refunds, pos.audit_log to service_role;

revoke execute on function pos._audit(uuid, uuid, text, text, uuid, jsonb) from public, anon, authenticated;
grant execute on function pos.record_payment_attempt(uuid, text, numeric, text, text, boolean, uuid) to authenticated;
grant execute on function pos.refund_order(uuid, text, uuid, jsonb, text, text, text, boolean, text, text, uuid) to authenticated;
grant execute on all functions in schema pos to service_role;

-- Realtime: el panel de pedidos también se entera de reembolsos.

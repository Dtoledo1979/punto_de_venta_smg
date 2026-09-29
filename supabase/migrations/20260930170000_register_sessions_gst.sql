-- =====================================================================
-- Fase 4 — Sesiones de caja (apertura/cierre con arqueo) y GST.
--
-- Sesión de caja: se abre con un fondo inicial, registra entradas/salidas
-- de efectivo, y al cerrar se cuenta el efectivo real. El sistema calcula
-- el efectivo esperado (fondo + ventas en efectivo − reembolsos en
-- efectivo + entradas − salidas) y guarda la diferencia. Cada pago y
-- reembolso queda ligado a la sesión en que ocurrió.
--   * Vender (fuera de modo prueba) exige una sesión abierta en esa caja.
--   * Una venta de una sesión YA CERRADA no se anula ni reabre: se
--     reembolsa (así no se altera un arqueo que ya se cerró).
--   * Cerrar con pedidos pendientes de entrega exige confirmación.
--
-- GST: tasa por organización (NZ: 15%), precios CON impuesto incluido. Cada
-- venta guarda su tasa y su monto de impuesto al momento de la venta
-- (cambiar la tasa después no altera ventas pasadas). Los reembolsos
-- guardan su parte de impuesto.
-- =====================================================================

-- ---------------------------------------------------------------------
-- GST por organización
-- ---------------------------------------------------------------------
alter table pos.organizations
  add column tax_rate numeric(6,4) not null default 0.15 check (tax_rate >= 0 and tax_rate < 1),
  add column tax_name text not null default 'GST',
  add column tax_number text;   -- número de GST, se imprime en la boleta

-- ---------------------------------------------------------------------
-- Sesiones de caja
-- ---------------------------------------------------------------------
create table pos.register_sessions (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references pos.organizations(id) on delete cascade,
  register_id     uuid not null,
  status          text not null default 'open' check (status in ('open','closed')),
  opening_float   numeric(10,2) not null check (opening_float >= 0),
  opened_at       timestamptz not null default now(),
  opened_by_name  text,
  opened_by_user  uuid references auth.users(id) on delete set null,
  closed_at       timestamptz,
  closed_by_name  text,
  closed_by_user  uuid references auth.users(id) on delete set null,
  counted_cash    numeric(10,2),
  expected_cash   numeric(10,2),
  cash_variance   numeric(10,2),
  totals          jsonb,           -- foto del reporte Z al cerrar
  close_note      text,
  unique (id, org_id),
  foreign key (register_id, org_id) references pos.registers(id, org_id),
  constraint register_sessions_closed_chk check (
    status = 'open' or (closed_at is not null and counted_cash is not null and expected_cash is not null and cash_variance is not null)
  )
);
-- Una sola sesión abierta por caja.
create unique index register_sessions_one_open on pos.register_sessions (register_id) where status = 'open';
create index register_sessions_register_idx on pos.register_sessions (register_id, opened_at desc);

create table pos.cash_movements (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references pos.organizations(id) on delete cascade,
  register_id     uuid not null,
  session_id      uuid not null,
  type            text not null check (type in ('cash_in','cash_out')),
  amount          numeric(10,2) not null check (amount > 0),
  reason          text not null,
  operator_name   text,
  created_by_user uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  foreign key (register_id, org_id) references pos.registers(id, org_id),
  foreign key (session_id, org_id) references pos.register_sessions(id, org_id)
);
create index cash_movements_session_idx on pos.cash_movements (session_id);

-- Pedidos, pagos y reembolsos ligados a la sesión; impuesto por venta.
alter table pos.orders
  add column session_id uuid,
  add column tax_rate   numeric(6,4) not null default 0,
  add column tax_amount numeric(10,2) not null default 0 check (tax_amount >= 0),
  add constraint orders_session_fk foreign key (session_id, org_id) references pos.register_sessions(id, org_id);
alter table pos.payments
  add column session_id uuid,
  add constraint payments_session_fk foreign key (session_id, org_id) references pos.register_sessions(id, org_id);
alter table pos.refunds
  add column session_id uuid,
  add column tax_amount numeric(10,2) not null default 0,
  add constraint refunds_session_fk foreign key (session_id, org_id) references pos.register_sessions(id, org_id);
create index orders_session_idx on pos.orders (session_id);
create index payments_session_idx on pos.payments (session_id);
create index refunds_session_idx on pos.refunds (session_id);

-- Ventas existentes: GST incluido al 15% (el guarda de inmutabilidad se
-- suspende solo para este relleno inicial).
alter table pos.orders disable trigger orders_guard;
update pos.orders set tax_rate = 0.15,
  tax_amount = case when payment_method = 'complimentary' then 0 else round(total * 0.15 / 1.15, 2) end;
alter table pos.orders enable trigger orders_guard;
alter table pos.refunds disable trigger refunds_guard;
update pos.refunds set tax_amount = round(amount * 0.15 / 1.15, 2);
alter table pos.refunds enable trigger refunds_guard;

-- Guarda de pedidos: también el impuesto y la sesión son inmutables.
create or replace function pos._orders_guard() returns trigger
language plpgsql as $$
declare v_old_lines jsonb; v_new_lines jsonb;
begin
  if new.org_id <> old.org_id or new.register_id <> old.register_id or new.event_id is distinct from old.event_id
     or new.ticket_num <> old.ticket_num or new.total <> old.total or new.payment_method <> old.payment_method
     or new.cash_amount <> old.cash_amount or new.card_amount <> old.card_amount or new.is_test <> old.is_test
     or new.paid_at <> old.paid_at or new.client_transaction_id is distinct from old.client_transaction_id
     or new.ingredient_consumption is distinct from old.ingredient_consumption
     or new.tax_rate <> old.tax_rate or new.tax_amount <> old.tax_amount or new.session_id is distinct from old.session_id then
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

-- Sesión: una vez cerrada no cambia; abierta solo puede pasar a cerrada.
create function pos._sessions_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if not exists (select 1 from pos.organizations where id = old.org_id) then return old; end if;
    raise exception 'session.immutable';
  end if;
  if old.status = 'closed' or new.status <> 'closed' or new.opening_float <> old.opening_float
     or new.opened_at <> old.opened_at or new.register_id <> old.register_id then
    raise exception 'session.immutable';
  end if;
  return new;
end;
$$;
create trigger register_sessions_guard before update or delete on pos.register_sessions
  for each row execute function pos._sessions_guard();

create function pos._cash_movements_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from pos.organizations where id = old.org_id) then return old; end if;
  raise exception 'session.immutable';
end;
$$;
create trigger cash_movements_guard before update or delete on pos.cash_movements
  for each row execute function pos._cash_movements_guard();

-- Auditoría
create function pos._audit_sessions() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    perform pos._audit(new.org_id, new.register_id, 'session.open', 'register_session', new.id,
      jsonb_build_object('opening_float', new.opening_float));
  elsif new.status = 'closed' and old.status = 'open' then
    perform pos._audit(new.org_id, new.register_id, 'session.close', 'register_session', new.id,
      jsonb_build_object('expected_cash', new.expected_cash, 'counted_cash', new.counted_cash, 'cash_variance', new.cash_variance));
  end if;
  return null;
end;
$$;
create trigger register_sessions_audit after insert or update on pos.register_sessions
  for each row execute function pos._audit_sessions();

create function pos._audit_cash_movements() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._audit(new.org_id, new.register_id, 'cash.' || new.type, 'register_session', new.session_id,
    jsonb_build_object('amount', new.amount, 'reason', new.reason));
  return null;
end;
$$;
create trigger cash_movements_audit after insert on pos.cash_movements
  for each row execute function pos._audit_cash_movements();

-- RLS y permisos
alter table pos.register_sessions enable row level security;
alter table pos.cash_movements enable row level security;
create policy tenant_select on pos.register_sessions for select to authenticated using (org_id in (select pos.user_org_ids()));
create policy tenant_select on pos.cash_movements for select to authenticated using (org_id in (select pos.user_org_ids()));
revoke all on pos.register_sessions, pos.cash_movements from anon, authenticated, public;
grant select on pos.register_sessions, pos.cash_movements to authenticated;
grant all on pos.register_sessions, pos.cash_movements to service_role;

-- ---------------------------------------------------------------------
-- Totales de una sesión (fuente única para la pantalla y para el cierre).
--   efectivo esperado = fondo + ventas en efectivo − reembolsos en efectivo
--                       + entradas − salidas
-- ---------------------------------------------------------------------
create function pos._session_totals(p_session_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
declare v_s pos.register_sessions; r jsonb;
begin
  select * into v_s from pos.register_sessions where id = p_session_id;
  select jsonb_build_object(
    'opening_float', v_s.opening_float,
    'cash_sales',   coalesce(sum(amount) filter (where kind = 'payment' and method = 'cash' and status = 'approved'), 0),
    'card_sales',   coalesce(sum(amount) filter (where kind = 'payment' and method = 'card' and status = 'approved'), 0),
    'cash_refunds', coalesce(sum(amount) filter (where kind = 'refund' and method = 'cash'), 0),
    'card_refunds', coalesce(sum(amount) filter (where kind = 'refund' and method = 'card'), 0),
    'declined_card_attempts', count(*) filter (where status = 'declined')
  ) into r from pos.payments where session_id = p_session_id;

  r := r || (select jsonb_build_object(
      'cash_in',  coalesce(sum(amount) filter (where type = 'cash_in'), 0),
      'cash_out', coalesce(sum(amount) filter (where type = 'cash_out'), 0))
    from pos.cash_movements where session_id = p_session_id);

  r := r || (select jsonb_build_object(
      'orders',          count(*) filter (where status <> 'voided' and payment_method <> 'complimentary'),
      'voided_orders',   count(*) filter (where status = 'voided'),
      'complimentary',   count(*) filter (where status <> 'voided' and payment_method = 'complimentary'),
      'complimentary_value', coalesce(sum(total) filter (where status <> 'voided' and payment_method = 'complimentary'), 0),
      'gross_sales',     coalesce(sum(total) filter (where status <> 'voided' and payment_method <> 'complimentary'), 0),
      'tax_sales',       coalesce(sum(tax_amount) filter (where status <> 'voided'), 0))
    from pos.orders where session_id = p_session_id);

  r := r || (select jsonb_build_object('refunds_total', coalesce(sum(amount), 0), 'tax_refunds', coalesce(sum(tax_amount), 0), 'refunds_count', count(*))
    from pos.refunds where session_id = p_session_id);

  r := r || jsonb_build_object(
    'net_sales', (r->>'gross_sales')::numeric - (r->>'refunds_total')::numeric,
    'tax_net',   (r->>'tax_sales')::numeric - (r->>'tax_refunds')::numeric,
    'expected_cash', (r->>'opening_float')::numeric + (r->>'cash_sales')::numeric - (r->>'cash_refunds')::numeric
                     + (r->>'cash_in')::numeric - (r->>'cash_out')::numeric);
  return r;
end;
$$;

-- Pantalla: sesión abierta de la caja + sus totales en vivo.
create function pos.get_open_session(p_register_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_s pos.register_sessions;
begin
  v_reg := pos._register_for_member(p_register_id);
  select * into v_s from pos.register_sessions where register_id = v_reg.id and status = 'open';
  if v_s.id is null then return null; end if;
  return to_jsonb(v_s) || jsonb_build_object('live', pos._session_totals(v_s.id));
end;
$$;

create function pos.open_register_session(p_register_id uuid, p_pin text, p_opening_float numeric, p_by text default null)
returns pos.register_sessions
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_s pos.register_sessions;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);
  if p_opening_float is null or p_opening_float < 0 then raise exception 'session.invalid_amount'; end if;
  begin
    insert into pos.register_sessions (org_id, register_id, opening_float, opened_by_name, opened_by_user)
      values (v_reg.org_id, v_reg.id, round(p_opening_float, 2), p_by, auth.uid())
      returning * into v_s;
  exception when unique_violation then
    raise exception 'session.already_open';
  end;
  return v_s;
end;
$$;

create function pos.record_cash_movement(p_register_id uuid, p_pin text, p_type text, p_amount numeric, p_reason text, p_by text default null)
returns pos.cash_movements
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_s pos.register_sessions; v_m pos.cash_movements;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);
  if p_type not in ('cash_in','cash_out') then raise exception 'session.invalid_movement'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'session.invalid_amount'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'session.reason_required'; end if;
  select * into v_s from pos.register_sessions where register_id = v_reg.id and status = 'open' for update;
  if v_s.id is null then raise exception 'session.not_open'; end if;
  insert into pos.cash_movements (org_id, register_id, session_id, type, amount, reason, operator_name, created_by_user)
    values (v_reg.org_id, v_reg.id, v_s.id, p_type, round(p_amount, 2), trim(p_reason), p_by, auth.uid())
    returning * into v_m;
  return v_m;
end;
$$;

-- Cierre con arqueo. Con pedidos pendientes de entrega hay que confirmar
-- (p_force) — no se cierra "en silencio" con trabajo sin terminar.
create function pos.close_register_session(
  p_register_id uuid, p_pin text, p_counted_cash numeric, p_note text default null,
  p_by text default null, p_force boolean default false
) returns pos.register_sessions
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_s pos.register_sessions; v_totals jsonb; v_pending int; v_expected numeric;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);
  if p_counted_cash is null or p_counted_cash < 0 then raise exception 'session.invalid_amount'; end if;
  select * into v_s from pos.register_sessions where register_id = v_reg.id and status = 'open' for update;
  if v_s.id is null then raise exception 'session.not_open'; end if;

  select count(*) into v_pending from pos.orders
    where register_id = v_reg.id and status = 'pending_delivery' and is_test = false and session_id = v_s.id;
  if v_pending > 0 and not coalesce(p_force, false) then
    raise exception 'session.pending_orders' using detail = json_build_object('n', v_pending)::text;
  end if;

  v_totals := pos._session_totals(v_s.id) || jsonb_build_object('pending_orders_at_close', v_pending);
  v_expected := (v_totals->>'expected_cash')::numeric;
  update pos.register_sessions set
    status = 'closed', closed_at = now(), closed_by_name = p_by, closed_by_user = auth.uid(),
    counted_cash = round(p_counted_cash, 2), expected_cash = v_expected,
    cash_variance = round(p_counted_cash, 2) - v_expected, totals = v_totals, close_note = p_note
  where id = v_s.id
  returning * into v_s;
  return v_s;
end;
$$;

grant execute on function pos.get_open_session(uuid) to authenticated;
grant execute on function pos.open_register_session(uuid, text, numeric, text) to authenticated;
grant execute on function pos.record_cash_movement(uuid, text, text, numeric, text, text) to authenticated;
grant execute on function pos.close_register_session(uuid, text, numeric, text, text, boolean) to authenticated;

-- Organización: GST (tasa, nombre, número) editable por owner/admin.
create function pos.update_organization_tax(p_org_id uuid, p_tax_rate numeric default null, p_tax_number text default null, p_tax_name text default null)
returns pos.organizations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_org pos.organizations;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin']);
  if p_tax_rate is not null and (p_tax_rate < 0 or p_tax_rate >= 1) then raise exception 'org.invalid_tax_rate'; end if;
  update pos.organizations set
    tax_rate = coalesce(p_tax_rate, tax_rate),
    tax_number = coalesce(nullif(trim(p_tax_number), ''), tax_number),
    tax_name = coalesce(nullif(trim(p_tax_name), ''), tax_name)
  where id = p_org_id returning * into v_org;
  return v_org;
end;
$$;
grant execute on function pos.update_organization_tax(uuid, numeric, text, text) to authenticated;

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

create or replace function pos.void_order(p_register_id uuid, p_pin text, p_order_id uuid)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_order pos.orders;
begin
  v_reg := pos._register_with_any_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  if exists (select 1 from pos.orders o join pos.register_sessions s on s.id = o.session_id
             where o.id = p_order_id and o.register_id = v_reg.id and s.status = 'closed') then
    raise exception 'order.session_closed';
  end if;

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
  if exists (select 1 from pos.orders o join pos.register_sessions s on s.id = o.session_id
             where o.id = p_order_id and o.register_id = v_reg.id and s.status = 'closed') then
    raise exception 'order.session_closed';
  end if;

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
  v_paid_method numeric; v_refunded_method numeric; v_after numeric; v_cons jsonb; v_ing_qty numeric;
  v_restock boolean;
  v_session uuid;
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

  -- Un reembolso en efectivo sale del cajón: exige sesión abierta.
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

create or replace function pos.record_payment_attempt(
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
  insert into pos.payments (org_id, register_id, order_id, kind, method, amount, status, is_test, client_transaction_id, operator_name, created_by_user, session_id)
    values (v_reg.org_id, v_reg.id, null, 'payment', 'card', round(p_amount, 2), p_status, coalesce(p_is_test, false), p_client_transaction_id, p_operator, auth.uid(),
            case when coalesce(p_is_test, false) then null else (select id from pos.register_sessions where register_id = v_reg.id and status = 'open') end)
    returning id into v_id;
  return v_id;
end;
$$;

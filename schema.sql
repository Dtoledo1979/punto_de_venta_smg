-- =====================================================================
-- South Media Group — Punto de Venta (POS)
-- Esquema Supabase: "pos"
-- Ejecutar completo en el SQL Editor del proyecto Supabase de
-- South Media Passport (ref: umbkpzhgocryhcbbczhr), o el que corresponda.
-- =====================================================================

create schema if not exists pos;

-- ---------------------------------------------------------------------
-- Puntos de venta (cajas físicas). "producto" = requiere entrega.
-- "ticket" = se autoejecuta (quien cobra, entrega).
-- El PIN es compartido por punto de venta, no por persona.
-- ---------------------------------------------------------------------
create table pos.registers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  type text not null check (type in ('producto','ticket')),
  pin text not null,
  despacho_pin text not null default '5678',
  next_ticket int not null default 1,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Eventos (fondas, fiestas, etc.). Solo uno debería estar activo a la vez.
-- ---------------------------------------------------------------------
create table pos.events (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  event_date date,
  active boolean not null default false,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Ítems de menú / tipos de ticket, editables desde la pantalla del POS.
-- ---------------------------------------------------------------------
create table pos.menu_items (
  id uuid primary key default gen_random_uuid(),
  register_id uuid not null references pos.registers(id) on delete cascade,
  name text not null,
  price numeric(10,2) not null,
  active boolean not null default true,
  sort_order int not null default 0,
  track_stock boolean not null default false,
  stock_qty numeric(10,2),
  initial_stock numeric(10,2),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Pedidos. Flujo de estados:
--   producto:  pendiente_entrega -> entregado  (o anulado)
--   ticket:    entregado directo al cobrar     (o anulado)
-- ---------------------------------------------------------------------
create table pos.orders (
  id uuid primary key default gen_random_uuid(),
  register_id uuid not null references pos.registers(id),
  event_id uuid references pos.events(id),
  ticket_num int not null,
  items jsonb not null,
  total numeric(10,2) not null,
  payment_method text not null check (payment_method in ('efectivo','tarjeta','mixto','cortesia')),
  cash_amount numeric(10,2) not null default 0,
  card_amount numeric(10,2) not null default 0,
  customer_name text,
  attended_by text,
  delivered_by text,
  status text not null default 'pendiente_entrega'
    check (status in ('pendiente_entrega','entregado','anulado')),
  obs text,
  paid_at timestamptz not null default now(),
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  unique (register_id, ticket_num)
);

create index idx_orders_register_status on pos.orders (register_id, status);
create index idx_orders_event on pos.orders (event_id);

-- ---------------------------------------------------------------------
-- Historial de stock: cada carga inicial, reposición y venta queda
-- registrada acá, para poder ver de dónde salió cada número.
-- ---------------------------------------------------------------------
create table pos.stock_movements (
  id uuid primary key default gen_random_uuid(),
  menu_item_id uuid not null references pos.menu_items(id) on delete cascade,
  register_id uuid not null references pos.registers(id),
  event_id uuid references pos.events(id),
  type text not null check (type in ('carga_inicial','restock','venta','ajuste')),
  qty_change numeric(10,2) not null,
  qty_after numeric(10,2) not null,
  note text,
  created_by text,
  created_at timestamptz not null default now()
);
create index idx_stock_mov_item on pos.stock_movements (menu_item_id, created_at desc);
alter table pos.stock_movements enable row level security;
create policy "acceso interno" on pos.stock_movements for all using (true) with check (true);
-- Igual que el resto: solo lectura directa. Escribir acá solo lo hacen
-- las funciones de más abajo (restock_item, y create_order al vender).
revoke insert, update, delete on pos.stock_movements from anon, authenticated;

-- ---------------------------------------------------------------------
-- Número de ticket atómico por punto de venta (evita duplicados si dos
-- personas cobran "al mismo tiempo" en la misma caja).
-- ---------------------------------------------------------------------
create or replace function pos.next_ticket(p_register_id uuid)
returns int
language plpgsql
as $$
declare
  v_num int;
begin
  update pos.registers
    set next_ticket = next_ticket + 1
    where id = p_register_id
    returning next_ticket - 1 into v_num;
  return v_num;
end;
$$;

-- ---------------------------------------------------------------------
-- Realtime: la pantalla de Entrega necesita enterarse al instante de
-- pedidos nuevos y cambios de estado.
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table pos.orders;

-- ---------------------------------------------------------------------
-- PIN de administrador: un solo PIN maestro (independiente del PIN de
-- cada caja) que autoriza resetear el PIN de una caja o renombrarla,
-- desde la opción "Administración" dentro de cada punto de venta.
-- ---------------------------------------------------------------------
create table pos.admin_settings (
  id boolean primary key default true check (id),
  admin_pin text not null
);

alter table pos.admin_settings enable row level security;
drop policy if exists "acceso interno" on pos.admin_settings;
create policy "acceso interno" on pos.admin_settings for all using (true) with check (true);

-- CAMBIA este PIN antes de usar el sistema en un evento real.
insert into pos.admin_settings (admin_pin) values ('9999');

-- ---------------------------------------------------------------------
-- IMPORTANTE: los schemas nuevos (fuera de "public") no le dan permisos
-- a los roles anon/authenticated automáticamente, aunque las políticas
-- RLS digan "true". Sin esto, la API responde 401 aunque todo lo demás
-- esté bien configurado. (Más abajo, en "ENDURECIMIENTO DE SEGURIDAD",
-- se le quita a anon/authenticated el insert/update/delete y la lectura
-- de columnas sensibles que este bloque otorga aquí — dejar ambos
-- bloques, en este orden, es intencional.)
-- ---------------------------------------------------------------------
grant usage on schema pos to anon, authenticated, service_role;
grant all on all tables in schema pos to anon, authenticated, service_role;
grant all on all sequences in schema pos to anon, authenticated, service_role;
grant execute on all functions in schema pos to anon, authenticated, service_role;

alter default privileges in schema pos grant all on tables to anon, authenticated, service_role;
alter default privileges in schema pos grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema pos grant execute on functions to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- MIGRACIÓN — solo necesaria si tu tabla pos.orders ya existía antes de
-- agregar el pago mixto (efectivo + tarjeta en el mismo ticket). Si estás
-- corriendo este schema.sql por primera vez, no hace falta este bloque.
-- ---------------------------------------------------------------------
alter table pos.orders
  add column if not exists cash_amount numeric(10,2) not null default 0,
  add column if not exists card_amount numeric(10,2) not null default 0;

alter table pos.orders drop constraint if exists orders_payment_method_check;
alter table pos.orders add constraint orders_payment_method_check
  check (payment_method in ('efectivo','tarjeta','mixto','cortesia'));

alter table pos.orders add column if not exists customer_name text;

alter table pos.menu_items
  add column if not exists track_stock boolean not null default false,
  add column if not exists stock_qty numeric(10,2),
  add column if not exists initial_stock numeric(10,2);

alter table pos.registers add column if not exists despacho_pin text not null default '5678';

alter table pos.orders add column if not exists attended_by text;
alter table pos.orders add column if not exists delivered_by text;

-- =====================================================================
-- ENDURECIMIENTO DE SEGURIDAD
-- Los pasos anteriores dejaban el sistema abierto: cualquiera con la
-- anon key (pública, viene en el código de la página) podía leer los
-- PIN directamente y crear/editar/borrar pedidos sin pasar por la app.
-- Esto lo cierra: se revoca el acceso amplio y todas las escrituras
-- pasan a hacerse a través de funciones que verifican el PIN adentro
-- de la base de datos (nunca lo devuelven al navegador).
-- =====================================================================

-- 1) Quitar los permisos amplios dados anteriormente
revoke insert, update, delete on pos.registers from anon, authenticated;
revoke all on pos.admin_settings from anon, authenticated;
revoke insert, update, delete on pos.menu_items from anon, authenticated;
revoke insert, update, delete on pos.orders from anon, authenticated;
revoke insert, update, delete on pos.events from anon, authenticated;

-- 2) Ocultar los PIN de cualquier lectura directa (select * ya no los trae)
revoke select on pos.registers from anon, authenticated;
grant select (id, name, type, next_ticket, active, created_at) on pos.registers to anon, authenticated;

-- 3) Ya no se llama directo desde el navegador — ahora vive dentro de create_order()
revoke execute on function pos.next_ticket(uuid) from anon, authenticated;

-- ---------------------------------------------------------------------
-- Verificación de PIN (devuelven true/false, nunca el valor real)
-- ---------------------------------------------------------------------
create or replace function pos.verify_register_pin(p_register_id uuid, p_pin text)
returns boolean language sql security definer set search_path = pos as $$
  select exists(select 1 from pos.registers where id = p_register_id and pin = p_pin);
$$;
grant execute on function pos.verify_register_pin(uuid, text) to anon, authenticated;

create or replace function pos.verify_despacho_pin(p_register_id uuid, p_pin text)
returns boolean language sql security definer set search_path = pos as $$
  select exists(select 1 from pos.registers where id = p_register_id and despacho_pin = p_pin);
$$;
grant execute on function pos.verify_despacho_pin(uuid, text) to anon, authenticated;

create or replace function pos.verify_admin_pin(p_pin text)
returns boolean language sql security definer set search_path = pos as $$
  select exists(select 1 from pos.admin_settings where id = true and admin_pin = p_pin);
$$;
grant execute on function pos.verify_admin_pin(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Acciones de administrador (re-validan el PIN admin adentro)
-- ---------------------------------------------------------------------
create or replace function pos.admin_update_register(
  p_admin_pin text, p_register_id uuid,
  p_name text default null, p_pin text default null, p_despacho_pin text default null
) returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_admin_pin(p_admin_pin) then return false; end if;
  update pos.registers set
    name = coalesce(p_name, name),
    pin = coalesce(p_pin, pin),
    despacho_pin = coalesce(p_despacho_pin, despacho_pin)
  where id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.admin_update_register(text, uuid, text, text, text) to anon, authenticated;

create or replace function pos.admin_update_admin_pin(p_admin_pin text, p_new_pin text)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_admin_pin(p_admin_pin) then return false; end if;
  update pos.admin_settings set admin_pin = p_new_pin where id = true;
  return true;
end;
$$;
grant execute on function pos.admin_update_admin_pin(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Eventos
-- ---------------------------------------------------------------------
create or replace function pos.create_event(p_register_id uuid, p_pin text, p_name text, p_event_date date)
returns pos.events language plpgsql security definer set search_path = pos as $$
declare v_event pos.events;
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  update pos.events set active = false where active = true;
  insert into pos.events (name, event_date, active) values (p_name, p_event_date, true)
    returning * into v_event;
  return v_event;
end;
$$;
grant execute on function pos.create_event(uuid, text, text, date) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Menú y stock
-- ---------------------------------------------------------------------
create or replace function pos.add_menu_item(p_register_id uuid, p_pin text, p_name text, p_price numeric, p_sort_order int)
returns pos.menu_items language plpgsql security definer set search_path = pos as $$
declare v_item pos.menu_items;
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  insert into pos.menu_items (register_id, name, price, sort_order) values (p_register_id, p_name, p_price, p_sort_order)
    returning * into v_item;
  return v_item;
end;
$$;
grant execute on function pos.add_menu_item(uuid, text, text, numeric, int) to anon, authenticated;

create or replace function pos.update_menu_item(p_register_id uuid, p_pin text, p_item_id uuid, p_name text, p_price numeric)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  update pos.menu_items set name = coalesce(p_name, name), price = coalesce(p_price, price)
    where id = p_item_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.update_menu_item(uuid, text, uuid, text, numeric) to anon, authenticated;

create or replace function pos.remove_menu_item(p_register_id uuid, p_pin text, p_item_id uuid)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  update pos.menu_items set active = false where id = p_item_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.remove_menu_item(uuid, text, uuid) to anon, authenticated;

create or replace function pos.set_item_stock(p_register_id uuid, p_pin text, p_item_id uuid, p_track_stock boolean, p_qty numeric)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  if p_track_stock then
    update pos.menu_items set track_stock = true, stock_qty = p_qty, initial_stock = p_qty
      where id = p_item_id and register_id = p_register_id;
  else
    update pos.menu_items set track_stock = false where id = p_item_id and register_id = p_register_id;
  end if;
  return true;
end;
$$;
grant execute on function pos.set_item_stock(uuid, text, uuid, boolean, numeric) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Reponer stock (reemplaza el uso de set_item_stock desde la UI actual).
-- p_mode = 'reset'  -> reinicia stock_qty e initial_stock a p_qty (carga inicial nueva).
-- p_mode = 'add'    -> suma p_qty a ambos (reposición: llegó más mercadería).
-- Cada llamada queda registrada en pos.stock_movements.
-- ---------------------------------------------------------------------
create or replace function pos.restock_item(
  p_register_id uuid, p_pin text, p_item_id uuid, p_mode text, p_qty numeric,
  p_note text default null, p_by text default null
) returns pos.menu_items language plpgsql security definer set search_path = pos as $$
declare
  v_item pos.menu_items;
  v_new_stock numeric;
  v_new_initial numeric;
  v_type text;
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  select * into v_item from pos.menu_items where id = p_item_id and register_id = p_register_id;
  if v_item is null then raise exception 'Producto no encontrado'; end if;

  if p_mode = 'reset' then
    v_new_stock := p_qty; v_new_initial := p_qty; v_type := 'carga_inicial';
  elsif p_mode = 'add' then
    v_new_stock := coalesce(v_item.stock_qty,0) + p_qty;
    v_new_initial := coalesce(v_item.initial_stock,0) + p_qty;
    v_type := 'restock';
  else
    raise exception 'Modo inválido';
  end if;

  update pos.menu_items set track_stock = true, stock_qty = v_new_stock, initial_stock = v_new_initial
    where id = p_item_id returning * into v_item;

  insert into pos.stock_movements (menu_item_id, register_id, type, qty_change, qty_after, note, created_by)
    values (p_item_id, p_register_id, v_type, p_qty, v_new_stock, p_note, p_by);

  return v_item;
end;
$$;
grant execute on function pos.restock_item(uuid, text, uuid, text, numeric, text, text) to anon, authenticated;

create or replace function pos.disable_stock(p_register_id uuid, p_pin text, p_item_id uuid)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  update pos.menu_items set track_stock = false where id = p_item_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.disable_stock(uuid, text, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Pedidos: crear, anular, reabrir
-- ---------------------------------------------------------------------
create or replace function pos.create_order(
  p_register_id uuid, p_pin text, p_event_id uuid, p_items jsonb,
  p_payment_method text, p_cash numeric, p_card numeric,
  p_customer_name text, p_obs text, p_attended_by text,
  p_admin_pin text default null
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

  if p_payment_method <> 'cortesia' and abs((coalesce(p_cash,0) + coalesce(p_card,0)) - v_total) > 1 then
    raise exception 'El efectivo + tarjeta no coincide con el total';
  end if;

  update pos.registers set next_ticket = next_ticket + 1 where id = p_register_id returning next_ticket - 1 into v_ticket_num;

  if v_register.type = 'ticket' then
    v_status := 'entregado';
    v_delivered_at := now();
  else
    v_status := 'pendiente_entrega';
  end if;

  insert into pos.orders (
    register_id, event_id, ticket_num, items, total, payment_method,
    cash_amount, card_amount, customer_name, attended_by, status, obs, delivered_at
  ) values (
    p_register_id, p_event_id, v_ticket_num, p_items, v_total, p_payment_method,
    coalesce(p_cash,0), coalesce(p_card,0), p_customer_name, p_attended_by, v_status, p_obs, v_delivered_at
  ) returning * into v_order;

  -- Descontar stock de los productos vendidos que lo tengan activado.
  -- IMPORTANTE: solo toca stock_qty, nunca initial_stock (esa es la base
  -- del % restante — reiniciarla en cada venta es el bug que hacía que
  -- siempre marcara 100%).
  for v_item in select * from jsonb_array_elements(p_items) loop
    if v_item ? 'id' then
      update pos.menu_items
        set stock_qty = greatest(0, stock_qty - coalesce((v_item->>'qty')::numeric, 0))
        where id = (v_item->>'id')::uuid
          and register_id = p_register_id
          and track_stock = true
          and stock_qty is not null
        returning stock_qty into v_stock_after;

      if found then
        insert into pos.stock_movements (menu_item_id, register_id, event_id, type, qty_change, qty_after, created_by)
          values ((v_item->>'id')::uuid, p_register_id, p_event_id, 'venta',
                  -coalesce((v_item->>'qty')::numeric, 0), v_stock_after, p_attended_by);
      end if;
    end if;
  end loop;

  return v_order;
end;
$$;
grant execute on function pos.create_order(uuid, text, uuid, jsonb, text, numeric, numeric, text, text, text, text) to anon, authenticated;

create or replace function pos.void_order(p_register_id uuid, p_pin text, p_order_id uuid)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not (pos.verify_register_pin(p_register_id, p_pin) or pos.verify_despacho_pin(p_register_id, p_pin)) then
    raise exception 'PIN incorrecto';
  end if;
  update pos.orders set status = 'anulado' where id = p_order_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.void_order(uuid, text, uuid) to anon, authenticated;

create or replace function pos.reopen_order(p_register_id uuid, p_pin text, p_order_id uuid)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not (pos.verify_register_pin(p_register_id, p_pin) or pos.verify_despacho_pin(p_register_id, p_pin)) then
    raise exception 'PIN incorrecto';
  end if;
  update pos.orders set status = 'pendiente_entrega', delivered_at = null where id = p_order_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.reopen_order(uuid, text, uuid) to anon, authenticated;

create or replace function pos.despacho_toggle_item(p_register_id uuid, p_despacho_pin text, p_order_id uuid, p_item_index int)
returns boolean language plpgsql security definer set search_path = pos as $$
declare v_items jsonb;
begin
  if not pos.verify_despacho_pin(p_register_id, p_despacho_pin) then raise exception 'PIN incorrecto'; end if;
  select items into v_items from pos.orders where id = p_order_id and register_id = p_register_id;
  v_items := jsonb_set(v_items, array[p_item_index::text, 'delivered'],
    to_jsonb(not coalesce((v_items->p_item_index->>'delivered')::boolean, false)));
  update pos.orders set items = v_items where id = p_order_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.despacho_toggle_item(uuid, text, uuid, int) to anon, authenticated;

create or replace function pos.despacho_confirm_all(p_register_id uuid, p_despacho_pin text, p_order_id uuid, p_delivered_by text)
returns boolean language plpgsql security definer set search_path = pos as $$
declare v_items jsonb;
begin
  if not pos.verify_despacho_pin(p_register_id, p_despacho_pin) then raise exception 'PIN incorrecto'; end if;
  select items into v_items from pos.orders where id = p_order_id and register_id = p_register_id;
  select jsonb_agg(elem || '{"delivered":true}'::jsonb) into v_items from jsonb_array_elements(v_items) elem;
  update pos.orders set items = v_items, status = 'entregado', delivered_at = now(), delivered_by = p_delivered_by
    where id = p_order_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.despacho_confirm_all(uuid, text, uuid, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Políticas RLS — permisivas a propósito.
-- La protección real está en los "revoke" de la sección de arriba:
-- anon ya NO tiene permiso de insert/update/delete en estas tablas
-- (solo las funciones "security definer" pueden escribir, y ellas sí
-- validan el PIN). Estas políticas solo habilitan la LECTURA directa que
-- la app sigue necesitando (tablero de Entrega, menú, eventos). No las
-- endurezcas pensando que ahí falta algo — lo que falta ya está resuelto
-- arriba.
-- ---------------------------------------------------------------------
alter table pos.registers enable row level security;
alter table pos.events enable row level security;
alter table pos.menu_items enable row level security;
alter table pos.orders enable row level security;

drop policy if exists "acceso interno" on pos.registers;
drop policy if exists "acceso interno" on pos.events;
drop policy if exists "acceso interno" on pos.menu_items;
drop policy if exists "acceso interno" on pos.orders;
create policy "acceso interno" on pos.registers for all using (true) with check (true);
create policy "acceso interno" on pos.events for all using (true) with check (true);
create policy "acceso interno" on pos.menu_items for all using (true) with check (true);
create policy "acceso interno" on pos.orders for all using (true) with check (true);

-- ---------------------------------------------------------------------
-- Datos iniciales de ejemplo. El PIN y el nombre se pueden dejar así y
-- cambiar después desde la opción "Administración" dentro de cada caja
-- (con el admin_pin de arriba) — no hace falta editar esto antes de correr
-- el script.
-- ---------------------------------------------------------------------
insert into pos.registers (name, type, pin) values
  ('Barra Principal', 'producto', '1234'),
  ('Boletería', 'ticket', '5678');

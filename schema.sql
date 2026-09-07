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
  payment_method text not null check (payment_method in ('efectivo','tarjeta','cortesia')),
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
-- Seguridad (RLS)
-- IMPORTANTE: esto deja las tablas abiertas a cualquiera que tenga la
-- anon key del proyecto. Es aceptable para una herramienta interna que
-- no se enlaza desde el sitio público, pero si más adelante se expone
-- de forma pública hay que reemplazar estas políticas por unas que
-- validen el PIN en el servidor (por ejemplo, vía una función RPC con
-- "security definer" en vez de acceso directo a las tablas).
-- ---------------------------------------------------------------------
alter table pos.registers enable row level security;
alter table pos.events enable row level security;
alter table pos.menu_items enable row level security;
alter table pos.orders enable row level security;

create policy "acceso interno" on pos.registers for all using (true) with check (true);
create policy "acceso interno" on pos.events for all using (true) with check (true);
create policy "acceso interno" on pos.menu_items for all using (true) with check (true);
create policy "acceso interno" on pos.orders for all using (true) with check (true);

-- ---------------------------------------------------------------------
-- Datos iniciales de ejemplo — AJUSTA nombres y PIN antes de usar.
-- ---------------------------------------------------------------------
insert into pos.registers (name, type, pin) values
  ('Barra Principal', 'producto', '1234'),
  ('Boletería', 'ticket', '5678');

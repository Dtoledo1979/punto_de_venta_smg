-- =====================================================================
-- Fase 1 — Tablas del POS, ahora multi-tenant.
--
-- Cada tabla lleva org_id (la RLS queda como un filtro simple, sin joins)
-- y FKs compuestas que hacen imposible, a nivel de base de datos, mezclar
-- datos de dos organizaciones o de dos cajas distintas — aunque falle una
-- función. Es la versión estructural del arreglo P1 de set_recipe /
-- upsert_promotion.
--
-- Todas las FKs compuestas son MATCH SIMPLE: si una columna es null (ej.
-- event_id en un pedido sin evento) la FK no se verifica, a propósito.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Cajas físicas. "producto" = requiere entrega; "ticket" = se autoejecuta.
-- Los PIN se guardan con bcrypt y nunca son legibles desde la API.
-- (next_ticket ya no existe: la numeración vive en ticket_counters.)
-- ---------------------------------------------------------------------
create table pos.registers (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references pos.organizations(id) on delete cascade,
  location_id       uuid not null,
  name              text not null,
  type              text not null check (type in ('producto','ticket')),
  pin_hash          text not null,
  despacho_pin_hash text not null,
  active            boolean not null default true,
  created_at        timestamptz not null default now(),
  unique (id, org_id),
  foreign key (location_id, org_id) references pos.locations(id, org_id) on delete cascade
);
create index registers_org_idx on pos.registers (org_id);
create index registers_location_idx on pos.registers (location_id, org_id);

-- ---------------------------------------------------------------------
-- Eventos: de toda la organización, o de una sola ubicación si
-- location_id no es null.
-- ---------------------------------------------------------------------
create table pos.events (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references pos.organizations(id) on delete cascade,
  location_id uuid,
  name        text not null,
  event_date  date,
  active      boolean not null default false,
  created_at  timestamptz not null default now(),
  unique (id, org_id),
  foreign key (location_id, org_id) references pos.locations(id, org_id) on delete cascade
);
create index events_org_idx on pos.events (org_id, active);

-- ---------------------------------------------------------------------
-- Menú / tipos de ticket, por caja.
-- ---------------------------------------------------------------------
create table pos.menu_items (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references pos.organizations(id) on delete cascade,
  register_id   uuid not null,
  name          text not null,
  price         numeric(10,2) not null check (price >= 0),
  active        boolean not null default true,
  sort_order    int not null default 0,
  color         text,
  track_stock   boolean not null default false,
  stock_qty     numeric(10,2),
  initial_stock numeric(10,2),
  created_at    timestamptz not null default now(),
  unique (id, register_id),
  foreign key (register_id, org_id) references pos.registers(id, org_id) on delete cascade
);
create index menu_items_register_idx on pos.menu_items (register_id, sort_order);

-- ---------------------------------------------------------------------
-- Insumos: ingredientes con su propia unidad y stock (ml, gr, un).
-- ---------------------------------------------------------------------
create table pos.ingredients (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references pos.organizations(id) on delete cascade,
  register_id     uuid not null,
  name            text not null,
  unit            text not null,
  stock_qty       numeric(12,2),
  initial_stock   numeric(12,2),
  container_size  numeric(12,2),
  container_label text,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (id, register_id),
  foreign key (register_id, org_id) references pos.registers(id, org_id) on delete cascade
);
create index ingredients_register_idx on pos.ingredients (register_id);

-- ---------------------------------------------------------------------
-- Receta: cuánto de cada insumo lleva un producto, por unidad vendida.
-- register_id + las dos FKs compuestas garantizan que producto e insumo
-- son siempre de la MISMA caja.
-- ---------------------------------------------------------------------
create table pos.recipe_items (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references pos.organizations(id) on delete cascade,
  register_id   uuid not null,
  menu_item_id  uuid not null,
  ingredient_id uuid not null,
  qty_per_unit  numeric(12,3) not null check (qty_per_unit > 0),
  unique (menu_item_id, ingredient_id),
  foreign key (register_id, org_id) references pos.registers(id, org_id) on delete cascade,
  foreign key (menu_item_id, register_id) references pos.menu_items(id, register_id) on delete cascade,
  foreign key (ingredient_id, register_id) references pos.ingredients(id, register_id) on delete cascade
);

-- ---------------------------------------------------------------------
-- Promociones: "cada N unidades de este producto, por $X en total".
-- ---------------------------------------------------------------------
create table pos.promotions (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references pos.organizations(id) on delete cascade,
  register_id  uuid not null,
  menu_item_id uuid not null,
  name         text,
  bundle_qty   int not null check (bundle_qty >= 2),
  bundle_price numeric(10,2) not null check (bundle_price >= 0),
  active       boolean not null default true,
  starts_at    timestamptz,
  ends_at      timestamptz,
  created_at   timestamptz not null default now(),
  foreign key (register_id, org_id) references pos.registers(id, org_id) on delete cascade,
  foreign key (menu_item_id, register_id) references pos.menu_items(id, register_id) on delete cascade
);
create index promotions_item_idx on pos.promotions (menu_item_id);
create index promotions_register_idx on pos.promotions (register_id);

-- ---------------------------------------------------------------------
-- Pedidos. Flujo de estados:
--   producto:  pendiente_entrega -> entregado  (o anulado)
--   ticket:    entregado directo al cobrar     (o anulado)
-- attended_by / delivered_by = nombre escrito por quien opera (informativo).
-- sold_by_user = cuenta de Auth desde la que se cobró (auditoría real).
-- ---------------------------------------------------------------------
create table pos.orders (
  id                     uuid primary key default gen_random_uuid(),
  org_id                 uuid not null references pos.organizations(id) on delete cascade,
  register_id            uuid not null,
  event_id               uuid,
  ticket_num             int not null,
  items                  jsonb not null,
  total                  numeric(10,2) not null,
  payment_method         text not null check (payment_method in ('efectivo','tarjeta','mixto','cortesia')),
  cash_amount            numeric(10,2) not null default 0,
  card_amount            numeric(10,2) not null default 0,
  customer_name          text,
  attended_by            text,
  delivered_by           text,
  sold_by_user           uuid references auth.users(id) on delete set null,
  ingredient_consumption jsonb,
  is_test                boolean not null default false,
  client_transaction_id  uuid,
  status                 text not null default 'pendiente_entrega'
                           check (status in ('pendiente_entrega','entregado','anulado')),
  obs                    text,
  paid_at                timestamptz not null default now(),
  delivered_at           timestamptz,
  created_at             timestamptz not null default now(),
  unique (register_id, event_id, ticket_num),
  foreign key (register_id, org_id) references pos.registers(id, org_id),
  foreign key (event_id, org_id) references pos.events(id, org_id)
);
-- Idempotencia: el mismo intento de cobro nunca crea dos ventas.
create unique index orders_client_transaction_id_key
  on pos.orders (client_transaction_id) where client_transaction_id is not null;
create index orders_register_status_idx on pos.orders (org_id, register_id, status, paid_at);
create index orders_event_idx on pos.orders (org_id, event_id);

-- ---------------------------------------------------------------------
-- Numeración de tickets por caja + evento (cada evento empieza en #1).
-- ---------------------------------------------------------------------
create table pos.ticket_counters (
  org_id      uuid not null references pos.organizations(id) on delete cascade,
  register_id uuid not null,
  event_id    uuid not null,
  next_ticket int not null default 1,
  primary key (register_id, event_id),
  foreign key (register_id, org_id) references pos.registers(id, org_id) on delete cascade,
  foreign key (event_id, org_id) references pos.events(id, org_id) on delete cascade
);

-- ---------------------------------------------------------------------
-- Historial de stock: cada carga, reposición, venta y ajuste.
-- ---------------------------------------------------------------------
create table pos.stock_movements (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references pos.organizations(id) on delete cascade,
  register_id     uuid not null,
  menu_item_id    uuid,
  ingredient_id   uuid,
  event_id        uuid,
  type            text not null check (type in ('carga_inicial','restock','venta','ajuste')),
  qty_change      numeric(12,2) not null,
  qty_after       numeric(12,2) not null,
  note            text,
  created_by      text,
  created_by_user uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  constraint stock_movements_target_chk check (
    (menu_item_id is not null and ingredient_id is null) or
    (menu_item_id is null and ingredient_id is not null)
  ),
  foreign key (register_id, org_id) references pos.registers(id, org_id) on delete cascade,
  foreign key (menu_item_id, register_id) references pos.menu_items(id, register_id) on delete cascade,
  foreign key (ingredient_id, register_id) references pos.ingredients(id, register_id) on delete cascade,
  foreign key (event_id, org_id) references pos.events(id, org_id)
);
create index stock_mov_item_idx on pos.stock_movements (menu_item_id, created_at desc);
create index stock_mov_ingredient_idx on pos.stock_movements (ingredient_id, created_at desc);

-- ---------------------------------------------------------------------
-- Límite de intentos de PIN. scope_id = register_id para 'register' y
-- 'despacho', org_id para 'supervisor'. Nunca accesible desde la API.
-- ---------------------------------------------------------------------
create table pos.pin_attempts (
  scope        text not null check (scope in ('register','despacho','supervisor')),
  scope_id     uuid not null,
  fail_count   int not null default 0,
  locked_until timestamptz,
  updated_at   timestamptz not null default now(),
  primary key (scope, scope_id)
);

-- =====================================================================
-- RLS — solo políticas de LECTURA, y solo para usuarios autenticados.
-- No existe ninguna política de insert/update/delete: junto con los
-- grants de abajo, cualquier escritura directa por la API falla dos
-- veces. Las escrituras las hacen solo las funciones security definer.
--
-- (select pos.user_org_ids()) entre paréntesis: Postgres lo evalúa una
-- vez por consulta, no una vez por fila.
-- =====================================================================
alter table pos.organizations   enable row level security;
alter table pos.locations       enable row level security;
alter table pos.memberships     enable row level security;
alter table pos.org_secrets     enable row level security;  -- sin políticas: inaccesible
alter table pos.registers       enable row level security;
alter table pos.events          enable row level security;
alter table pos.menu_items      enable row level security;
alter table pos.ingredients     enable row level security;
alter table pos.recipe_items    enable row level security;
alter table pos.promotions      enable row level security;
alter table pos.orders          enable row level security;
alter table pos.ticket_counters enable row level security;
alter table pos.stock_movements enable row level security;
alter table pos.pin_attempts    enable row level security;  -- sin políticas: inaccesible

create policy org_select on pos.organizations for select to authenticated
  using (id in (select pos.user_org_ids()));

create policy memberships_select on pos.memberships for select to authenticated
  using (user_id = (select auth.uid())
         or pos.has_org_role(org_id, array['owner','admin']));

create policy tenant_select on pos.locations       for select to authenticated using (org_id in (select pos.user_org_ids()));
create policy tenant_select on pos.registers       for select to authenticated using (org_id in (select pos.user_org_ids()));
create policy tenant_select on pos.events          for select to authenticated using (org_id in (select pos.user_org_ids()));
create policy tenant_select on pos.menu_items      for select to authenticated using (org_id in (select pos.user_org_ids()));
create policy tenant_select on pos.ingredients     for select to authenticated using (org_id in (select pos.user_org_ids()));
create policy tenant_select on pos.recipe_items    for select to authenticated using (org_id in (select pos.user_org_ids()));
create policy tenant_select on pos.promotions      for select to authenticated using (org_id in (select pos.user_org_ids()));
create policy tenant_select on pos.orders          for select to authenticated using (org_id in (select pos.user_org_ids()));
create policy tenant_select on pos.ticket_counters for select to authenticated using (org_id in (select pos.user_org_ids()));
create policy tenant_select on pos.stock_movements for select to authenticated using (org_id in (select pos.user_org_ids()));

-- =====================================================================
-- Grants. anon: nada. authenticated: solo SELECT (filtrado por la RLS).
-- =====================================================================
revoke all on all tables in schema pos from anon, authenticated, public;
revoke usage on schema pos from anon, public;
grant usage on schema pos to authenticated, service_role;

grant select on
  pos.organizations, pos.locations, pos.memberships, pos.events,
  pos.menu_items, pos.ingredients, pos.recipe_items, pos.promotions,
  pos.orders, pos.ticket_counters, pos.stock_movements
to authenticated;

-- Los hash de PIN nunca son legibles, ni siquiera para la propia org.
grant select (id, org_id, location_id, name, type, active, created_at)
  on pos.registers to authenticated;

grant all on all tables in schema pos to service_role;

-- ---------------------------------------------------------------------
-- Realtime: Entrega y "Órdenes activas" escuchan cambios en pedidos.
-- Postgres Changes respeta la RLS de arriba: un tenant nunca recibe
-- eventos de otro.
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table pos.orders;

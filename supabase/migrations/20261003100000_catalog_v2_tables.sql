-- =====================================================================
-- Fase B (1/3) — Catálogo del NEGOCIO, no de cada caja.
--
-- Antes: cada caja tenía su menú, sus insumos y su stock. Un dueño con 3
-- cafés cargaba el mismo flat white 3 veces y dos cajas del mismo local
-- tenían stocks distintos del mismo refrigerador.
--
-- Ahora:
--   categories, products, modifier_groups/modifiers  → del negocio
--   product_locations   → por local: disponible, precio propio, agotado,
--                         stock del producto (si se controla)
--   stock_items / stock_levels → insumos del negocio, stock por local
--   product_recipes / modifier_recipes → recetas (ej. "Avena" suma 200 ml
--                         de leche de avena y resta 200 ml de leche entera)
--   product_promotions  → promos del negocio, opcionalmente de un local
--   inventory_movements / stock_counts → libro de stock y conteos por local
--   organizations.business_type → café, restaurante, bar, food truck,
--                         heladería, eventos u otro
--
-- Migración: los registros existentes conservan su id (products.id =
-- menu_items.id, stock_items.id = ingredients.id), así los pedidos,
-- devoluciones y auditoría anteriores siguen apuntando a lo mismo.
-- Las tablas por caja se eliminan en la parte 3/3.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tipo de negocio y funciones visibles
-- ---------------------------------------------------------------------
alter table pos.organizations
  add column business_type text not null default 'cafe'
    check (business_type in ('cafe','restaurant','bar','food_truck','gelato','events','other')),
  add column features jsonb not null default '{}'::jsonb;

update pos.organizations o set business_type = 'events'
  where exists (select 1 from pos.events e where e.org_id = o.id)
     or exists (select 1 from pos.registers r where r.org_id = o.id and r.type = 'ticket');

-- ---------------------------------------------------------------------
-- Categorías
-- ---------------------------------------------------------------------
create table pos.categories (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references pos.organizations(id) on delete cascade,
  name       text not null check (length(trim(name)) between 1 and 60),
  color      text check (color is null or color ~ '^#[0-9A-Fa-f]{6}$'),
  sort_order int not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, org_id)
);
create unique index categories_unique_active_name on pos.categories (org_id, lower(trim(name))) where active;

-- ---------------------------------------------------------------------
-- Productos (y tipos de ticket: kind = 'ticket')
-- ---------------------------------------------------------------------
create table pos.products (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references pos.organizations(id) on delete cascade,
  category_id uuid,
  name        text not null check (length(trim(name)) between 1 and 80),
  price       numeric(10,2) not null check (price >= 0),
  color       text check (color is null or color ~ '^#[0-9A-Fa-f]{6}$'),
  station     text not null default 'none' check (station in ('bar','kitchen','coffee','collection','none')),
  kind        text not null default 'product' check (kind in ('product','ticket')),
  track_stock boolean not null default false,
  sort_order  int not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (id, org_id),
  foreign key (category_id, org_id) references pos.categories(id, org_id)
);
create index products_org_idx on pos.products (org_id, kind, sort_order);

create table pos.product_locations (
  org_id        uuid not null references pos.organizations(id) on delete cascade,
  product_id    uuid not null,
  location_id   uuid not null,
  available     boolean not null default true,
  price         numeric(10,2) check (price is null or price >= 0),
  sold_out      boolean not null default false,
  stock_qty     numeric(14,3),
  initial_stock numeric(14,3),
  primary key (product_id, location_id),
  foreign key (product_id, org_id) references pos.products(id, org_id) on delete cascade,
  foreign key (location_id, org_id) references pos.locations(id, org_id) on delete cascade
);

-- ---------------------------------------------------------------------
-- Opciones (modificadores): Tamaño, Leche, Sabores…
--   min_select = 1 → obligatorio; max_select = 1 → se elige uno;
--   max_select > 1 → hasta N (ej. 3 sabores).
-- ---------------------------------------------------------------------
create table pos.modifier_groups (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references pos.organizations(id) on delete cascade,
  name       text not null check (length(trim(name)) between 1 and 60),
  min_select int not null default 0 check (min_select >= 0),
  max_select int not null default 1 check (max_select >= 1),
  sort_order int not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, org_id),
  check (min_select <= max_select)
);
create unique index modifier_groups_unique_active_name on pos.modifier_groups (org_id, lower(trim(name))) where active;

create table pos.modifiers (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references pos.organizations(id) on delete cascade,
  group_id    uuid not null,
  name        text not null check (length(trim(name)) between 1 and 60),
  price_delta numeric(10,2) not null default 0 check (price_delta between -10000 and 10000),
  is_default  boolean not null default false,
  sort_order  int not null default 0,
  active      boolean not null default true,
  unique (id, org_id),
  foreign key (group_id, org_id) references pos.modifier_groups(id, org_id) on delete cascade
);
create unique index modifiers_unique_active_name on pos.modifiers (group_id, lower(trim(name))) where active;

create table pos.product_modifier_groups (
  org_id     uuid not null references pos.organizations(id) on delete cascade,
  product_id uuid not null,
  group_id   uuid not null,
  sort_order int not null default 0,
  primary key (product_id, group_id),
  foreign key (product_id, org_id) references pos.products(id, org_id) on delete cascade,
  foreign key (group_id, org_id) references pos.modifier_groups(id, org_id) on delete cascade
);

-- ---------------------------------------------------------------------
-- Insumos del negocio y su stock por local
-- ---------------------------------------------------------------------
create table pos.stock_items (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references pos.organizations(id) on delete cascade,
  name            text not null check (length(trim(name)) between 1 and 80),
  unit            text not null check (length(trim(unit)) between 1 and 20),
  container_size  numeric(14,3) check (container_size is null or container_size > 0),
  container_label text,
  unit_cost       numeric(12,4) check (unit_cost is null or unit_cost >= 0),
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (id, org_id)
);
create unique index stock_items_unique_active_name on pos.stock_items (org_id, lower(trim(name))) where active;

create table pos.stock_levels (
  org_id        uuid not null references pos.organizations(id) on delete cascade,
  stock_item_id uuid not null,
  location_id   uuid not null,
  qty           numeric(14,3) not null default 0,
  initial_qty   numeric(14,3),
  primary key (stock_item_id, location_id),
  foreign key (stock_item_id, org_id) references pos.stock_items(id, org_id) on delete cascade,
  foreign key (location_id, org_id) references pos.locations(id, org_id) on delete cascade
);

create table pos.product_recipes (
  org_id        uuid not null references pos.organizations(id) on delete cascade,
  product_id    uuid not null,
  stock_item_id uuid not null,
  qty_per_unit  numeric(14,3) not null check (qty_per_unit > 0),
  primary key (product_id, stock_item_id),
  foreign key (product_id, org_id) references pos.products(id, org_id) on delete cascade,
  foreign key (stock_item_id, org_id) references pos.stock_items(id, org_id) on delete cascade
);

-- Una opción puede sumar insumo (shot extra) o reemplazar otro (avena en
-- vez de leche entera → +200 ml avena, −200 ml leche): por eso admite
-- cantidades negativas.
create table pos.modifier_recipes (
  org_id        uuid not null references pos.organizations(id) on delete cascade,
  modifier_id   uuid not null,
  stock_item_id uuid not null,
  qty_per_unit  numeric(14,3) not null check (qty_per_unit <> 0),
  primary key (modifier_id, stock_item_id),
  foreign key (modifier_id, org_id) references pos.modifiers(id, org_id) on delete cascade,
  foreign key (stock_item_id, org_id) references pos.stock_items(id, org_id) on delete cascade
);

-- ---------------------------------------------------------------------
-- Promociones "N por $X" del negocio (o de un local)
-- ---------------------------------------------------------------------
create table pos.product_promotions (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references pos.organizations(id) on delete cascade,
  product_id   uuid not null,
  location_id  uuid,
  name         text,
  bundle_qty   int not null check (bundle_qty >= 2),
  bundle_price numeric(10,2) not null check (bundle_price >= 0),
  active       boolean not null default true,
  starts_at    timestamptz,
  ends_at      timestamptz,
  created_at   timestamptz not null default now(),
  foreign key (product_id, org_id) references pos.products(id, org_id) on delete cascade,
  foreign key (location_id, org_id) references pos.locations(id, org_id) on delete cascade
);
create index product_promotions_product_idx on pos.product_promotions (product_id);

-- ---------------------------------------------------------------------
-- Conteos de inventario por local (inmutables)
-- lines = [{"kind":"product|item","id","name","unit","expected","counted","variance"}]
-- ---------------------------------------------------------------------
create table pos.stock_counts (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references pos.organizations(id) on delete cascade,
  location_id           uuid not null,
  name                  text,
  lines                 jsonb not null,
  items_counted         int not null,
  items_with_variance   int not null,
  note                  text,
  client_transaction_id uuid unique,
  operator_name         text,
  created_by_user       uuid references auth.users(id) on delete set null,
  created_at            timestamptz not null default now(),
  unique (id, org_id),
  foreign key (location_id, org_id) references pos.locations(id, org_id)
);
create index stock_counts_location_idx on pos.stock_counts (location_id, created_at desc);

-- ---------------------------------------------------------------------
-- Libro de stock por local (inmutable). Exactamente uno de product_id /
-- stock_item_id.
-- ---------------------------------------------------------------------
create table pos.inventory_movements (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references pos.organizations(id) on delete cascade,
  location_id     uuid not null,
  product_id      uuid,
  stock_item_id   uuid,
  type            text not null check (type in ('opening_stock','purchase','sale','adjustment','void_return','reopen_sale','refund_return','waste','stocktake')),
  reason          text,
  qty_change      numeric(14,3) not null,
  qty_after       numeric(14,3) not null,
  expected_qty    numeric(14,3),
  count_id        uuid,
  order_id        uuid,
  register_id     uuid,
  event_id        uuid,
  note            text,
  created_by      text,
  created_by_user uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  constraint inventory_movements_target_chk check ((product_id is null) <> (stock_item_id is null)),
  constraint inventory_movements_waste_reason_chk check (type <> 'waste' or reason in ('spillage','breakage','expired','staff','prep_error','other')),
  foreign key (location_id, org_id) references pos.locations(id, org_id),
  foreign key (product_id, org_id) references pos.products(id, org_id),
  foreign key (stock_item_id, org_id) references pos.stock_items(id, org_id),
  -- Diferida: el conteo escribe sus movimientos y al final su propia fila.
  foreign key (count_id, org_id) references pos.stock_counts(id, org_id) deferrable initially deferred
);
create index inventory_movements_location_idx on pos.inventory_movements (location_id, created_at desc);
create index inventory_movements_product_idx on pos.inventory_movements (product_id, created_at desc) where product_id is not null;
create index inventory_movements_item_idx on pos.inventory_movements (stock_item_id, created_at desc) where stock_item_id is not null;

create trigger inventory_movements_immutable before update or delete on pos.inventory_movements
  for each row execute function pos._audit_immutable();
create trigger stock_counts_immutable before update or delete on pos.stock_counts
  for each row execute function pos._audit_immutable();

-- ---------------------------------------------------------------------
-- Pedidos: para servir / para llevar / delivery, mesa, y numeración
-- diaria por caja cuando el negocio no trabaja con eventos.
-- ---------------------------------------------------------------------
alter table pos.orders
  add column order_type  text check (order_type in ('here','takeaway','delivery')),
  add column table_label text check (table_label is null or length(table_label) <= 20);

create table pos.order_counters (
  org_id      uuid not null references pos.organizations(id) on delete cascade,
  register_id uuid not null,
  day         date not null,
  next_number int not null default 1,
  primary key (register_id, day),
  foreign key (register_id, org_id) references pos.registers(id, org_id) on delete cascade
);

-- =====================================================================
-- Migración de datos (conservando ids)
-- =====================================================================
-- Productos: uno por producto de caja. Si dos cajas del mismo negocio
-- tenían un producto con el mismo nombre, el segundo lleva el nombre de
-- su caja entre paréntesis (se pueden unir después a mano).
insert into pos.products (id, org_id, name, price, color, station, kind, track_stock, sort_order, active, created_at)
select m.id, m.org_id,
       case when m.active and row_number() over (partition by m.org_id, r.type, lower(trim(m.name)), m.active order by m.created_at, m.id) > 1
            then left(trim(m.name), 60) || ' (' || left(r.name, 16) || ')' else trim(m.name) end,
       m.price, case when m.color ~ '^#[0-9A-Fa-f]{6}$' then m.color end, m.station, r.type, m.track_stock, m.sort_order, m.active, m.created_at
from pos.menu_items m join pos.registers r on r.id = m.register_id;

-- Disponibilidad: el producto queda en el local de su caja (con su stock)
-- y no disponible en los demás locales del negocio.
insert into pos.product_locations (org_id, product_id, location_id, available, stock_qty, initial_stock)
select m.org_id, m.id, r.location_id, true, case when m.track_stock then m.stock_qty end, case when m.track_stock then m.initial_stock end
from pos.menu_items m join pos.registers r on r.id = m.register_id;
insert into pos.product_locations (org_id, product_id, location_id, available)
select m.org_id, m.id, l.id, false
from pos.menu_items m join pos.registers r on r.id = m.register_id
join pos.locations l on l.org_id = m.org_id and l.id <> r.location_id
on conflict do nothing;

insert into pos.stock_items (id, org_id, name, unit, container_size, container_label, active, created_at)
select i.id, i.org_id,
       case when i.active and row_number() over (partition by i.org_id, lower(trim(i.name)), i.active order by i.created_at, i.id) > 1
            then left(trim(i.name), 60) || ' (' || left(r.name, 16) || ')' else trim(i.name) end,
       i.unit, i.container_size, i.container_label, i.active, i.created_at
from pos.ingredients i join pos.registers r on r.id = i.register_id;

insert into pos.stock_levels (org_id, stock_item_id, location_id, qty, initial_qty)
select i.org_id, i.id, r.location_id, coalesce(i.stock_qty, 0), i.initial_stock
from pos.ingredients i join pos.registers r on r.id = i.register_id
where i.stock_qty is not null;

insert into pos.product_recipes (org_id, product_id, stock_item_id, qty_per_unit)
select org_id, menu_item_id, ingredient_id, qty_per_unit from pos.recipe_items;

insert into pos.product_promotions (id, org_id, product_id, location_id, name, bundle_qty, bundle_price, active, starts_at, ends_at, created_at)
select p.id, p.org_id, p.menu_item_id, r.location_id, p.name, p.bundle_qty, p.bundle_price, p.active, p.starts_at, p.ends_at, p.created_at
from pos.promotions p join pos.registers r on r.id = p.register_id;

insert into pos.stock_counts (id, org_id, location_id, lines, items_counted, items_with_variance, note, client_transaction_id, operator_name, created_by_user, created_at)
select s.id, s.org_id, r.location_id,
       (select coalesce(jsonb_agg(case when l->>'kind' = 'menu_item' then jsonb_set(l, '{kind}', '"product"') else jsonb_set(l, '{kind}', '"item"') end), '[]'::jsonb)
          from jsonb_array_elements(s.lines) l),
       s.items_counted, s.items_with_variance, s.note, s.client_transaction_id, s.operator_name, s.created_by_user, s.created_at
from pos.stocktakes s join pos.registers r on r.id = s.register_id;

insert into pos.inventory_movements (id, org_id, location_id, product_id, stock_item_id, type, reason, qty_change, qty_after,
                                     expected_qty, count_id, register_id, event_id, note, created_by, created_by_user, created_at)
select s.id, s.org_id, r.location_id, s.menu_item_id, s.ingredient_id, s.type, s.reason, s.qty_change, s.qty_after,
       s.expected_qty, s.stocktake_id, s.register_id, s.event_id, s.note, s.created_by, s.created_by_user, s.created_at
from pos.stock_movements s join pos.registers r on r.id = s.register_id;

-- Validar ya las referencias diferidas (si no, los ALTER TABLE de abajo
-- fallan por eventos pendientes).
set constraints all immediate;

-- Unicidad de nombres activos (después de migrar).
create unique index products_unique_active_name on pos.products (org_id, kind, lower(trim(name))) where active;

-- =====================================================================
-- Seguridad: lectura para los miembros del negocio; escritura solo por
-- funciones (security definer).
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['categories','products','product_locations','modifier_groups','modifiers','product_modifier_groups',
                           'stock_items','stock_levels','product_recipes','modifier_recipes','product_promotions',
                           'stock_counts','inventory_movements','order_counters']
  loop
    execute format('alter table pos.%I enable row level security', t);
    execute format('create policy tenant_select on pos.%I for select to authenticated using (org_id in (select pos.user_org_ids()))', t);
    execute format('revoke all on pos.%I from anon, authenticated, public', t);
    execute format('grant select on pos.%I to authenticated', t);
    execute format('grant all on pos.%I to service_role', t);
  end loop;
end $$;
-- Los contadores no son información útil para el navegador.
revoke select on pos.order_counters from authenticated;

-- =====================================================================
-- Auditoría del catálogo
-- =====================================================================
create function pos._audit_products() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    perform pos._audit(new.org_id, null, 'menu.add', 'product', new.id, jsonb_build_object('name', new.name, 'price', new.price));
  elsif new.active is distinct from old.active and not new.active then
    perform pos._audit(new.org_id, null, 'menu.remove', 'product', new.id, jsonb_build_object('name', new.name));
  elsif new.price is distinct from old.price or new.name is distinct from old.name or new.station is distinct from old.station
        or new.category_id is distinct from old.category_id then
    perform pos._audit(new.org_id, null, 'menu.update', 'product', new.id,
      jsonb_build_object('old_name', old.name, 'new_name', new.name, 'old_price', old.price, 'new_price', new.price,
                         'old_station', old.station, 'new_station', new.station));
  end if;
  return null;
end;
$$;
create trigger products_audit after insert or update on pos.products
  for each row execute function pos._audit_products();

create function pos._audit_product_locations() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if tg_op = 'INSERT' or new.price is distinct from old.price or new.available is distinct from old.available then
    perform pos._audit(new.org_id, null, 'menu.location', 'product', new.product_id,
      jsonb_build_object('location_id', new.location_id, 'available', new.available, 'price', new.price));
  end if;
  return null;
end;
$$;
create trigger product_locations_audit after insert or update on pos.product_locations
  for each row execute function pos._audit_product_locations();

create function pos._audit_product_recipes() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare r record;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  perform pos._audit(r.org_id, null, 'recipe.change', 'product', r.product_id,
    jsonb_build_object('op', lower(tg_op), 'stock_item_id', r.stock_item_id, 'qty_per_unit', r.qty_per_unit));
  return null;
end;
$$;
create trigger product_recipes_audit after insert or update or delete on pos.product_recipes
  for each row execute function pos._audit_product_recipes();

create function pos._audit_product_promotions() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare r record;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  perform pos._audit(r.org_id, null, 'promotion.' || lower(tg_op), 'promotion', r.id,
    jsonb_build_object('product_id', r.product_id, 'bundle_qty', r.bundle_qty, 'bundle_price', r.bundle_price, 'active', r.active));
  return null;
end;
$$;
create trigger product_promotions_audit after insert or update or delete on pos.product_promotions
  for each row execute function pos._audit_product_promotions();

create function pos._audit_inventory() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if new.type in ('opening_stock','purchase','adjustment','waste') then
    perform pos._audit(new.org_id, new.register_id, 'stock.' || new.type,
      case when new.product_id is not null then 'product' else 'stock_item' end,
      coalesce(new.product_id, new.stock_item_id),
      jsonb_build_object('qty_change', new.qty_change, 'qty_after', new.qty_after, 'reason', new.reason, 'location_id', new.location_id));
  end if;
  return null;
end;
$$;
create trigger inventory_movements_audit after insert on pos.inventory_movements
  for each row execute function pos._audit_inventory();

create function pos._audit_stock_counts() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._audit(new.org_id, null, 'stock.stocktake', 'stock_count', new.id,
    jsonb_build_object('location_id', new.location_id, 'items_counted', new.items_counted, 'items_with_variance', new.items_with_variance));
  return null;
end;
$$;
create trigger stock_counts_audit after insert on pos.stock_counts
  for each row execute function pos._audit_stock_counts();

-- Realtime: las cajas se enteran al instante de cambios de catálogo y de
-- "agotado".
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table pos.products, pos.product_locations;
  end if;
end $$;

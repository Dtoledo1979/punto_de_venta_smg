-- =====================================================================
-- Insumos, recetas y promociones — contenido nuevo, no toca nada
-- existente salvo extender stock_movements (agrega una columna) y
-- reemplazar create_order (misma firma, ahora también descuenta insumos).
-- =====================================================================

create table if not exists pos.ingredients (
  id uuid primary key default gen_random_uuid(),
  register_id uuid not null references pos.registers(id) on delete cascade,
  name text not null,
  unit text not null,
  stock_qty numeric(12,2),
  initial_stock numeric(12,2),
  container_size numeric(12,2),
  container_label text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists pos.recipe_items (
  id uuid primary key default gen_random_uuid(),
  menu_item_id uuid not null references pos.menu_items(id) on delete cascade,
  ingredient_id uuid not null references pos.ingredients(id) on delete cascade,
  qty_per_unit numeric(12,3) not null,
  unique (menu_item_id, ingredient_id)
);

create table if not exists pos.promotions (
  id uuid primary key default gen_random_uuid(),
  register_id uuid not null references pos.registers(id) on delete cascade,
  menu_item_id uuid not null references pos.menu_items(id) on delete cascade,
  name text,
  bundle_qty int not null check (bundle_qty >= 2),
  bundle_price numeric(10,2) not null,
  active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now()
);

-- stock_movements: permitir referenciar un insumo, no solo un producto
alter table pos.stock_movements alter column menu_item_id drop not null;
alter table pos.stock_movements add column if not exists ingredient_id uuid references pos.ingredients(id) on delete cascade;
alter table pos.stock_movements drop constraint if exists stock_movements_target_chk;
alter table pos.stock_movements add constraint stock_movements_target_chk check (
  (menu_item_id is not null and ingredient_id is null) or
  (menu_item_id is null and ingredient_id is not null)
);
create index if not exists idx_stock_mov_ingredient on pos.stock_movements (ingredient_id, created_at desc);

alter table pos.ingredients enable row level security;
drop policy if exists "acceso interno" on pos.ingredients;
create policy "acceso interno" on pos.ingredients for all using (true) with check (true);
revoke insert, update, delete on pos.ingredients from anon, authenticated;

alter table pos.recipe_items enable row level security;
drop policy if exists "acceso interno" on pos.recipe_items;
create policy "acceso interno" on pos.recipe_items for all using (true) with check (true);
revoke insert, update, delete on pos.recipe_items from anon, authenticated;

alter table pos.promotions enable row level security;
drop policy if exists "acceso interno" on pos.promotions;
create policy "acceso interno" on pos.promotions for all using (true) with check (true);
revoke insert, update, delete on pos.promotions from anon, authenticated;
create or replace function pos.upsert_ingredient(
  p_register_id uuid, p_pin text, p_ingredient_id uuid, p_name text, p_unit text,
  p_container_size numeric, p_container_label text
) returns pos.ingredients language plpgsql security definer set search_path = pos as $$
declare v_row pos.ingredients;
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  if p_ingredient_id is null then
    insert into pos.ingredients (register_id, name, unit, container_size, container_label)
      values (p_register_id, p_name, p_unit, p_container_size, p_container_label)
      returning * into v_row;
  else
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

create or replace function pos.remove_ingredient(p_register_id uuid, p_pin text, p_ingredient_id uuid)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  update pos.ingredients set active = false where id = p_ingredient_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.remove_ingredient(uuid, text, uuid) to anon, authenticated;

create or replace function pos.restock_ingredient(
  p_register_id uuid, p_pin text, p_ingredient_id uuid, p_mode text, p_qty numeric, p_by text default null
) returns pos.ingredients language plpgsql security definer set search_path = pos as $$
declare
  v_row pos.ingredients;
  v_new_stock numeric;
  v_new_initial numeric;
  v_type text;
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  select * into v_row from pos.ingredients where id = p_ingredient_id and register_id = p_register_id;
  if v_row is null then raise exception 'Insumo no encontrado'; end if;

  if p_mode = 'reset' then
    v_new_stock := p_qty; v_new_initial := p_qty; v_type := 'carga_inicial';
  elsif p_mode = 'add' then
    v_new_stock := coalesce(v_row.stock_qty,0) + p_qty;
    v_new_initial := coalesce(v_row.initial_stock,0) + p_qty;
    v_type := 'restock';
  else
    raise exception 'Modo inválido';
  end if;

  update pos.ingredients set stock_qty = v_new_stock, initial_stock = v_new_initial
    where id = p_ingredient_id returning * into v_row;

  insert into pos.stock_movements (ingredient_id, register_id, type, qty_change, qty_after, created_by)
    values (p_ingredient_id, p_register_id, v_type, p_qty, v_new_stock, p_by);

  return v_row;
end;
$$;
grant execute on function pos.restock_ingredient(uuid, text, uuid, text, numeric, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Receta de un producto — reemplaza la lista completa de una vez.
-- p_recipe = [{"ingredient_id": "...", "qty_per_unit": 100}, ...]
-- ---------------------------------------------------------------------
create or replace function pos.set_recipe(p_register_id uuid, p_pin text, p_menu_item_id uuid, p_recipe jsonb)
returns boolean language plpgsql security definer set search_path = pos as $$
declare v_line jsonb;
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  delete from pos.recipe_items where menu_item_id = p_menu_item_id;
  for v_line in select * from jsonb_array_elements(p_recipe) loop
    insert into pos.recipe_items (menu_item_id, ingredient_id, qty_per_unit)
      values (p_menu_item_id, (v_line->>'ingredient_id')::uuid, (v_line->>'qty_per_unit')::numeric);
  end loop;
  return true;
end;
$$;
grant execute on function pos.set_recipe(uuid, text, uuid, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Promociones
-- ---------------------------------------------------------------------
create or replace function pos.upsert_promotion(
  p_register_id uuid, p_pin text, p_promotion_id uuid, p_menu_item_id uuid, p_name text,
  p_bundle_qty int, p_bundle_price numeric, p_active boolean, p_starts_at timestamptz, p_ends_at timestamptz
) returns pos.promotions language plpgsql security definer set search_path = pos as $$
declare v_row pos.promotions;
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  if p_promotion_id is null then
    insert into pos.promotions (register_id, menu_item_id, name, bundle_qty, bundle_price, active, starts_at, ends_at)
      values (p_register_id, p_menu_item_id, p_name, p_bundle_qty, p_bundle_price, p_active, p_starts_at, p_ends_at)
      returning * into v_row;
  else
    update pos.promotions set
      name = p_name, bundle_qty = p_bundle_qty, bundle_price = p_bundle_price,
      active = p_active, starts_at = p_starts_at, ends_at = p_ends_at
    where id = p_promotion_id and register_id = p_register_id
    returning * into v_row;
  end if;
  return v_row;
end;
$$;
grant execute on function pos.upsert_promotion(uuid, text, uuid, uuid, text, int, numeric, boolean, timestamptz, timestamptz) to anon, authenticated;

create or replace function pos.delete_promotion(p_register_id uuid, p_pin text, p_promotion_id uuid)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  delete from pos.promotions where id = p_promotion_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.delete_promotion(uuid, text, uuid) to anon, authenticated;

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
  v_recipe_line record;
  v_ingredient_after numeric;
  v_sold_qty numeric;
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

      -- Descontar insumos según la receta del producto (independiente del
      -- stock del producto en sí — un producto puede tener receta, stock
      -- propio, ambos, o ninguno).
      for v_recipe_line in
        select ri.ingredient_id, ri.qty_per_unit
        from pos.recipe_items ri
        where ri.menu_item_id = (v_item->>'id')::uuid
      loop
        update pos.ingredients
          set stock_qty = greatest(0, coalesce(stock_qty,0) - (v_recipe_line.qty_per_unit * v_sold_qty))
          where id = v_recipe_line.ingredient_id
          returning stock_qty into v_ingredient_after;

        insert into pos.stock_movements (ingredient_id, register_id, event_id, type, qty_change, qty_after, created_by)
          values (v_recipe_line.ingredient_id, p_register_id, p_event_id, 'venta',
                  -(v_recipe_line.qty_per_unit * v_sold_qty), v_ingredient_after, p_attended_by);
      end loop;
    end if;
  end loop;

  return v_order;
end;
$$;
grant execute on function pos.create_order(uuid, text, uuid, jsonb, text, numeric, numeric, text, text, text, text) to anon, authenticated;

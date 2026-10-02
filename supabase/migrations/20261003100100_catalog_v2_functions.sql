-- =====================================================================
-- Fase B (2/3) — Funciones del catálogo y del inventario.
--
-- La oficina edita el catálogo por ROL (owner/admin/manager), sin PIN de
-- caja: el catálogo es del negocio, no de una caja.
-- La caja (staff con PIN) solo marca "agotado" y registra mermas.
-- Todas las escrituras pasan por estas funciones (security definer).
-- =====================================================================

create function pos._require_catalog_role(p_org_id uuid) returns void
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._require_org_role(p_org_id, array['owner','admin','manager']);
end;
$$;

create function pos._valid_color(p_color text) returns text
language sql immutable as $$
  select case when p_color is null or trim(p_color) = '' then null
              when p_color ~ '^#[0-9A-Fa-f]{6}$' then upper(p_color)
              else null end
$$;

-- ---------------------------------------------------------------------
-- Categorías
-- ---------------------------------------------------------------------
create function pos.catalog_save_category(p_org_id uuid, p_id uuid, p_name text, p_color text default null, p_sort_order int default null)
returns pos.categories
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_row pos.categories;
begin
  perform pos._require_catalog_role(p_org_id);
  if coalesce(trim(p_name), '') = '' then raise exception 'validation.name_required'; end if;
  begin
    if p_id is null then
      insert into pos.categories (org_id, name, color, sort_order)
        values (p_org_id, trim(p_name), pos._valid_color(p_color),
                coalesce(p_sort_order, (select coalesce(max(sort_order), 0) + 1 from pos.categories where org_id = p_org_id)))
        returning * into v_row;
    else
      update pos.categories set name = trim(p_name), color = pos._valid_color(p_color), sort_order = coalesce(p_sort_order, sort_order)
        where id = p_id and org_id = p_org_id and active returning * into v_row;
      if v_row.id is null then raise exception 'category.not_found'; end if;
    end if;
  exception when unique_violation then
    raise exception 'category.duplicate_name' using detail = json_build_object('name', trim(p_name))::text;
  end;
  return v_row;
end;
$$;

create function pos.catalog_remove_category(p_org_id uuid, p_id uuid) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._require_catalog_role(p_org_id);
  update pos.categories set active = false where id = p_id and org_id = p_org_id and active;
  if not found then raise exception 'category.not_found'; end if;
  update pos.products set category_id = null where category_id = p_id and org_id = p_org_id;
  return true;
end;
$$;

create function pos.catalog_reorder(p_org_id uuid, p_what text, p_ids uuid[]) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._require_catalog_role(p_org_id);
  if p_what = 'categories' then
    update pos.categories c set sort_order = x.ord from unnest(p_ids) with ordinality x(id, ord) where c.id = x.id and c.org_id = p_org_id;
  elsif p_what = 'products' then
    update pos.products p set sort_order = x.ord from unnest(p_ids) with ordinality x(id, ord) where p.id = x.id and p.org_id = p_org_id;
  elsif p_what = 'modifier_groups' then
    update pos.modifier_groups g set sort_order = x.ord from unnest(p_ids) with ordinality x(id, ord) where g.id = x.id and g.org_id = p_org_id;
  else
    raise exception 'validation.invalid_option';
  end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Productos
-- ---------------------------------------------------------------------
create function pos.catalog_save_product(
  p_org_id uuid, p_id uuid, p_name text, p_price numeric, p_category_id uuid default null,
  p_color text default null, p_station text default 'none', p_kind text default 'product',
  p_track_stock boolean default false, p_modifier_group_ids uuid[] default '{}'
) returns pos.products
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_row pos.products; v_gid uuid; v_i int := 0;
begin
  perform pos._require_catalog_role(p_org_id);
  if coalesce(trim(p_name), '') = '' then raise exception 'validation.name_required'; end if;
  if p_price is null or p_price < 0 or p_price <> round(p_price, 2) then raise exception 'product.invalid_price'; end if;
  if p_station not in ('bar','kitchen','coffee','collection','none') then raise exception 'station.invalid'; end if;
  if p_kind not in ('product','ticket') then raise exception 'validation.invalid_option'; end if;
  if p_category_id is not null and not exists (select 1 from pos.categories where id = p_category_id and org_id = p_org_id and active) then
    raise exception 'category.not_found';
  end if;
  begin
    if p_id is null then
      insert into pos.products (org_id, category_id, name, price, color, station, kind, track_stock, sort_order)
        values (p_org_id, p_category_id, trim(p_name), p_price, pos._valid_color(p_color), p_station, p_kind, coalesce(p_track_stock, false),
                (select coalesce(max(sort_order), 0) + 1 from pos.products where org_id = p_org_id))
        returning * into v_row;
    else
      update pos.products set category_id = p_category_id, name = trim(p_name), price = p_price, color = pos._valid_color(p_color),
                              station = p_station, track_stock = coalesce(p_track_stock, track_stock)
        where id = p_id and org_id = p_org_id and active returning * into v_row;
      if v_row.id is null then raise exception 'product.not_found'; end if;
    end if;
  exception when unique_violation then
    raise exception 'menu.duplicate_name' using detail = json_build_object('name', trim(p_name))::text;
  end;

  -- Opciones del producto: se reemplaza el conjunto, en el orden recibido.
  delete from pos.product_modifier_groups where product_id = v_row.id;
  foreach v_gid in array coalesce(p_modifier_group_ids, '{}') loop
    v_i := v_i + 1;
    if not exists (select 1 from pos.modifier_groups where id = v_gid and org_id = p_org_id and active) then
      raise exception 'modifier.not_found';
    end if;
    insert into pos.product_modifier_groups (org_id, product_id, group_id, sort_order) values (p_org_id, v_row.id, v_gid, v_i)
      on conflict do nothing;
  end loop;
  -- Dejar de controlar stock borra los saldos por local (el historial queda).
  if not v_row.track_stock then
    update pos.product_locations set stock_qty = null, initial_stock = null where product_id = v_row.id and stock_qty is not null;
  end if;
  return v_row;
end;
$$;

create function pos.catalog_remove_product(p_org_id uuid, p_id uuid) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._require_catalog_role(p_org_id);
  update pos.products set active = false where id = p_id and org_id = p_org_id and active;
  if not found then raise exception 'product.not_found'; end if;
  return true;
end;
$$;

-- Disponibilidad y precio propio de un producto en un local.
-- p_price null = usar el precio general.
create function pos.catalog_set_product_location(
  p_org_id uuid, p_product_id uuid, p_location_id uuid, p_available boolean, p_price numeric default null
) returns pos.product_locations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_row pos.product_locations;
begin
  perform pos._require_catalog_role(p_org_id);
  if not exists (select 1 from pos.products where id = p_product_id and org_id = p_org_id and active) then raise exception 'product.not_found'; end if;
  if not exists (select 1 from pos.locations where id = p_location_id and org_id = p_org_id) then raise exception 'location.not_found'; end if;
  if p_price is not null and (p_price < 0 or p_price <> round(p_price, 2)) then raise exception 'product.invalid_price'; end if;
  insert into pos.product_locations (org_id, product_id, location_id, available, price)
    values (p_org_id, p_product_id, p_location_id, coalesce(p_available, true), p_price)
    on conflict (product_id, location_id) do update set available = coalesce(p_available, pos.product_locations.available), price = p_price
    returning * into v_row;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- Grupos de opciones
--   p_options = [{"id": uuid|null, "name": "Avena", "price_delta": 0.8, "is_default": false}, ...]
--   Las opciones que no vienen se desactivan (el historial las conserva).
-- ---------------------------------------------------------------------
create function pos.catalog_save_modifier_group(
  p_org_id uuid, p_id uuid, p_name text, p_min_select int, p_max_select int, p_options jsonb
) returns pos.modifier_groups
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_row pos.modifier_groups; v_opt jsonb; v_keep uuid[] := '{}'; v_oid uuid; v_i int := 0; v_delta numeric;
begin
  perform pos._require_catalog_role(p_org_id);
  if coalesce(trim(p_name), '') = '' then raise exception 'validation.name_required'; end if;
  if p_options is null or jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) = 0 then raise exception 'modifier.no_options'; end if;
  if coalesce(p_min_select, 0) < 0 or coalesce(p_max_select, 1) < 1 or coalesce(p_min_select, 0) > coalesce(p_max_select, 1)
     or coalesce(p_min_select, 0) > jsonb_array_length(p_options) then
    raise exception 'modifier.invalid_limits';
  end if;
  begin
    if p_id is null then
      insert into pos.modifier_groups (org_id, name, min_select, max_select, sort_order)
        values (p_org_id, trim(p_name), coalesce(p_min_select, 0), coalesce(p_max_select, 1),
                (select coalesce(max(sort_order), 0) + 1 from pos.modifier_groups where org_id = p_org_id))
        returning * into v_row;
    else
      update pos.modifier_groups set name = trim(p_name), min_select = coalesce(p_min_select, 0), max_select = coalesce(p_max_select, 1)
        where id = p_id and org_id = p_org_id and active returning * into v_row;
      if v_row.id is null then raise exception 'modifier.not_found'; end if;
    end if;

    for v_opt in select * from jsonb_array_elements(p_options) loop
      v_i := v_i + 1;
      if coalesce(trim(v_opt->>'name'), '') = '' then raise exception 'validation.name_required'; end if;
      v_delta := coalesce((v_opt->>'price_delta')::numeric, 0);
      if v_delta <> round(v_delta, 2) then raise exception 'product.invalid_price'; end if;
      v_oid := nullif(v_opt->>'id', '')::uuid;
      if v_oid is not null then
        update pos.modifiers set name = trim(v_opt->>'name'), price_delta = v_delta,
                                 is_default = coalesce((v_opt->>'is_default')::boolean, false), sort_order = v_i, active = true
          where id = v_oid and group_id = v_row.id;
        if not found then v_oid := null; end if;
      end if;
      if v_oid is null then
        insert into pos.modifiers (org_id, group_id, name, price_delta, is_default, sort_order)
          values (p_org_id, v_row.id, trim(v_opt->>'name'), v_delta, coalesce((v_opt->>'is_default')::boolean, false), v_i)
          returning id into v_oid;
      end if;
      v_keep := v_keep || v_oid;
    end loop;
  exception when unique_violation then
    raise exception 'modifier.duplicate_name' using detail = json_build_object('name', trim(p_name))::text;
  end;
  update pos.modifiers set active = false where group_id = v_row.id and active and not (id = any (v_keep));
  -- Con "elegir uno", a lo más una opción por defecto.
  if v_row.max_select = 1 and (select count(*) from pos.modifiers where group_id = v_row.id and active and is_default) > 1 then
    raise exception 'modifier.too_many_defaults';
  end if;
  return v_row;
end;
$$;

create function pos.catalog_remove_modifier_group(p_org_id uuid, p_id uuid) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._require_catalog_role(p_org_id);
  update pos.modifier_groups set active = false where id = p_id and org_id = p_org_id and active;
  if not found then raise exception 'modifier.not_found'; end if;
  delete from pos.product_modifier_groups where group_id = p_id;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Recetas
--   p_lines = [{"stock_item_id": uuid, "qty": 200}, ...]  (reemplaza la receta)
-- ---------------------------------------------------------------------
create function pos.catalog_set_recipe(p_org_id uuid, p_product_id uuid, p_lines jsonb) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_line jsonb; v_qty numeric;
begin
  perform pos._require_catalog_role(p_org_id);
  if not exists (select 1 from pos.products where id = p_product_id and org_id = p_org_id) then raise exception 'product.not_found'; end if;
  delete from pos.product_recipes where product_id = p_product_id;
  for v_line in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    v_qty := (v_line->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'recipe.invalid_qty'; end if;
    if not exists (select 1 from pos.stock_items where id = (v_line->>'stock_item_id')::uuid and org_id = p_org_id and active) then
      raise exception 'ingredient.not_found';
    end if;
    insert into pos.product_recipes (org_id, product_id, stock_item_id, qty_per_unit)
      values (p_org_id, p_product_id, (v_line->>'stock_item_id')::uuid, round(v_qty, 3))
      on conflict (product_id, stock_item_id) do update set qty_per_unit = pos.product_recipes.qty_per_unit + excluded.qty_per_unit;
  end loop;
  return true;
end;
$$;

create function pos.catalog_set_modifier_recipe(p_org_id uuid, p_modifier_id uuid, p_lines jsonb) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_line jsonb; v_qty numeric;
begin
  perform pos._require_catalog_role(p_org_id);
  if not exists (select 1 from pos.modifiers where id = p_modifier_id and org_id = p_org_id) then raise exception 'modifier.not_found'; end if;
  delete from pos.modifier_recipes where modifier_id = p_modifier_id;
  for v_line in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    v_qty := (v_line->>'qty')::numeric;
    if v_qty is null or v_qty = 0 then raise exception 'recipe.invalid_qty'; end if;
    if not exists (select 1 from pos.stock_items where id = (v_line->>'stock_item_id')::uuid and org_id = p_org_id and active) then
      raise exception 'ingredient.not_found';
    end if;
    insert into pos.modifier_recipes (org_id, modifier_id, stock_item_id, qty_per_unit)
      values (p_org_id, p_modifier_id, (v_line->>'stock_item_id')::uuid, round(v_qty, 3))
      on conflict (modifier_id, stock_item_id) do update set qty_per_unit = excluded.qty_per_unit;
  end loop;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Promociones "N por $X"
-- ---------------------------------------------------------------------
create function pos.catalog_save_promotion(
  p_org_id uuid, p_id uuid, p_product_id uuid, p_bundle_qty int, p_bundle_price numeric,
  p_name text default null, p_location_id uuid default null,
  p_starts_at timestamptz default null, p_ends_at timestamptz default null, p_active boolean default true
) returns pos.product_promotions
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_row pos.product_promotions; v_price numeric;
begin
  perform pos._require_catalog_role(p_org_id);
  select price into v_price from pos.products where id = p_product_id and org_id = p_org_id and active;
  if v_price is null then raise exception 'product.not_found'; end if;
  if p_bundle_qty is null or p_bundle_qty < 2 then raise exception 'promotion.invalid_qty'; end if;
  if p_bundle_price is null or p_bundle_price < 0 or p_bundle_price <> round(p_bundle_price, 2) then raise exception 'product.invalid_price'; end if;
  if p_bundle_price >= v_price * p_bundle_qty then raise exception 'promotion.not_a_discount'; end if;
  if p_starts_at is not null and p_ends_at is not null and p_ends_at <= p_starts_at then raise exception 'promotion.invalid_dates'; end if;
  if p_location_id is not null and not exists (select 1 from pos.locations where id = p_location_id and org_id = p_org_id) then
    raise exception 'location.not_found';
  end if;
  if p_id is null then
    insert into pos.product_promotions (org_id, product_id, location_id, name, bundle_qty, bundle_price, active, starts_at, ends_at)
      values (p_org_id, p_product_id, p_location_id, nullif(trim(p_name), ''), p_bundle_qty, p_bundle_price, coalesce(p_active, true), p_starts_at, p_ends_at)
      returning * into v_row;
  else
    update pos.product_promotions set product_id = p_product_id, location_id = p_location_id, name = nullif(trim(p_name), ''),
      bundle_qty = p_bundle_qty, bundle_price = p_bundle_price, active = coalesce(p_active, true), starts_at = p_starts_at, ends_at = p_ends_at
      where id = p_id and org_id = p_org_id returning * into v_row;
    if v_row.id is null then raise exception 'promotion.not_found'; end if;
  end if;
  return v_row;
end;
$$;

create function pos.catalog_remove_promotion(p_org_id uuid, p_id uuid) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._require_catalog_role(p_org_id);
  delete from pos.product_promotions where id = p_id and org_id = p_org_id;
  if not found then raise exception 'promotion.not_found'; end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Insumos
-- ---------------------------------------------------------------------
create function pos.inventory_save_item(
  p_org_id uuid, p_id uuid, p_name text, p_unit text,
  p_container_size numeric default null, p_container_label text default null, p_unit_cost numeric default null
) returns pos.stock_items
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_row pos.stock_items; v_cur pos.stock_items;
begin
  perform pos._require_catalog_role(p_org_id);
  if coalesce(trim(p_name), '') = '' then raise exception 'validation.name_required'; end if;
  if coalesce(trim(p_unit), '') = '' then raise exception 'ingredient.unit_required'; end if;
  if p_container_size is not null and p_container_size <= 0 then raise exception 'stock.invalid_qty'; end if;
  begin
    if p_id is null then
      insert into pos.stock_items (org_id, name, unit, container_size, container_label, unit_cost)
        values (p_org_id, trim(p_name), trim(p_unit), p_container_size, nullif(trim(p_container_label), ''), p_unit_cost)
        returning * into v_row;
    else
      select * into v_cur from pos.stock_items where id = p_id and org_id = p_org_id and active;
      if v_cur.id is null then raise exception 'ingredient.not_found'; end if;
      -- Con stock cargado no se cambia la unidad: 9500 ml no son 9500 l.
      if trim(p_unit) <> v_cur.unit and exists (select 1 from pos.stock_levels where stock_item_id = p_id) then
        raise exception 'ingredient.unit_locked' using detail = json_build_object('unit', v_cur.unit)::text;
      end if;
      update pos.stock_items set name = trim(p_name), unit = trim(p_unit), container_size = p_container_size,
                                 container_label = nullif(trim(p_container_label), ''), unit_cost = p_unit_cost
        where id = p_id returning * into v_row;
    end if;
  exception when unique_violation then
    raise exception 'ingredient.duplicate_name' using detail = json_build_object('name', trim(p_name))::text;
  end;
  return v_row;
end;
$$;

create function pos.inventory_remove_item(p_org_id uuid, p_id uuid) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._require_catalog_role(p_org_id);
  update pos.stock_items set active = false where id = p_id and org_id = p_org_id and active;
  if not found then raise exception 'ingredient.not_found'; end if;
  delete from pos.product_recipes where stock_item_id = p_id;
  delete from pos.modifier_recipes where stock_item_id = p_id;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Movimiento de stock (núcleo). Actualiza el saldo del local y deja la
-- fila en el libro. Devuelve el saldo resultante.
--   p_set_base: el saldo resultante pasa a ser la base del "% restante"
--   (al cargar stock inicial o reponer).
-- ---------------------------------------------------------------------
create function pos._stock_change(
  p_org_id uuid, p_location_id uuid, p_product_id uuid, p_stock_item_id uuid, p_delta numeric, p_type text,
  p_reason text default null, p_note text default null, p_by text default null, p_register_id uuid default null,
  p_order_id uuid default null, p_event_id uuid default null, p_count_id uuid default null, p_expected numeric default null,
  p_set_base boolean default false
) returns numeric
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_after numeric;
begin
  if p_product_id is not null then
    insert into pos.product_locations (org_id, product_id, location_id, stock_qty, initial_stock)
      values (p_org_id, p_product_id, p_location_id, round(p_delta, 3), case when p_set_base then round(p_delta, 3) end)
      on conflict (product_id, location_id) do update
        set stock_qty = coalesce(pos.product_locations.stock_qty, 0) + round(p_delta, 3),
            initial_stock = case when p_set_base then coalesce(pos.product_locations.stock_qty, 0) + round(p_delta, 3) else pos.product_locations.initial_stock end
      returning stock_qty into v_after;
  else
    insert into pos.stock_levels (org_id, stock_item_id, location_id, qty, initial_qty)
      values (p_org_id, p_stock_item_id, p_location_id, round(p_delta, 3), case when p_set_base then round(p_delta, 3) end)
      on conflict (stock_item_id, location_id) do update
        set qty = pos.stock_levels.qty + round(p_delta, 3),
            initial_qty = case when p_set_base then pos.stock_levels.qty + round(p_delta, 3) else pos.stock_levels.initial_qty end
      returning qty into v_after;
  end if;
  insert into pos.inventory_movements (org_id, location_id, product_id, stock_item_id, type, reason, qty_change, qty_after,
                                       expected_qty, count_id, order_id, register_id, event_id, note, created_by, created_by_user)
    values (p_org_id, p_location_id, p_product_id, p_stock_item_id, p_type, p_reason, round(p_delta, 3), v_after,
            p_expected, p_count_id, p_order_id, p_register_id, p_event_id, nullif(trim(p_note), ''), nullif(trim(p_by), ''), auth.uid());
  return v_after;
end;
$$;

-- Resuelve "qué" se mueve: producto con control de stock o insumo activo.
create function pos._stock_target(p_org_id uuid, p_kind text, p_id uuid, out o_product uuid, out o_item uuid)
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
begin
  if p_kind = 'product' then
    if not exists (select 1 from pos.products where id = p_id and org_id = p_org_id and active) then raise exception 'product.not_found'; end if;
    if not exists (select 1 from pos.products where id = p_id and track_stock) then raise exception 'stock.not_tracked'; end if;
    o_product := p_id;
  elsif p_kind = 'item' then
    if not exists (select 1 from pos.stock_items where id = p_id and org_id = p_org_id and active) then raise exception 'ingredient.not_found'; end if;
    o_item := p_id;
  else
    raise exception 'stock.invalid_target';
  end if;
end;
$$;

-- Reponer (sumar) o fijar el stock de un local.
--   p_mode = 'add' → compra/reposición (> 0); 'set' → carga inicial (≥ 0).
create function pos.inventory_receive(
  p_location_id uuid, p_kind text, p_id uuid, p_qty numeric, p_mode text default 'add', p_note text default null, p_by text default null
) returns numeric
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_org uuid; v_t record; v_current numeric;
begin
  select org_id into v_org from pos.locations where id = p_location_id;
  if v_org is null then raise exception 'location.not_found'; end if;
  perform pos._require_catalog_role(v_org);
  select * into v_t from pos._stock_target(v_org, p_kind, p_id);
  if p_mode = 'add' then
    if p_qty is null or p_qty <= 0 then raise exception 'stock.invalid_qty'; end if;
    return pos._stock_change(v_org, p_location_id, v_t.o_product, v_t.o_item, p_qty, 'purchase', null, p_note, p_by, p_set_base => true);
  elsif p_mode = 'set' then
    if p_qty is null or p_qty < 0 then raise exception 'stock.invalid_qty'; end if;
    if v_t.o_product is not null then
      select coalesce(stock_qty, 0) into v_current from pos.product_locations where product_id = v_t.o_product and location_id = p_location_id;
    else
      select qty into v_current from pos.stock_levels where stock_item_id = v_t.o_item and location_id = p_location_id;
    end if;
    return pos._stock_change(v_org, p_location_id, v_t.o_product, v_t.o_item, p_qty - coalesce(v_current, 0), 'opening_stock', null, p_note, p_by, p_set_base => true);
  end if;
  raise exception 'validation.invalid_option';
end;
$$;

-- Merma desde la oficina.
create function pos.inventory_waste(
  p_location_id uuid, p_kind text, p_id uuid, p_qty numeric, p_reason text, p_note text default null, p_by text default null
) returns numeric
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_org uuid; v_t record;
begin
  select org_id into v_org from pos.locations where id = p_location_id;
  if v_org is null then raise exception 'location.not_found'; end if;
  perform pos._require_catalog_role(v_org);
  if p_qty is null or p_qty <= 0 then raise exception 'stock.invalid_qty'; end if;
  if p_reason is null or p_reason not in ('spillage','breakage','expired','staff','prep_error','other') then raise exception 'stock.invalid_reason'; end if;
  select * into v_t from pos._stock_target(v_org, p_kind, p_id);
  return pos._stock_change(v_org, p_location_id, v_t.o_product, v_t.o_item, -p_qty, 'waste', p_reason, p_note, p_by);
end;
$$;

-- Merma desde la caja (staff, con PIN de caja).
create function pos.register_waste(
  p_register_id uuid, p_pin text, p_kind text, p_id uuid, p_qty numeric, p_reason text, p_note text default null, p_by text default null
) returns numeric
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_t record;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);
  if p_qty is null or p_qty <= 0 then raise exception 'stock.invalid_qty'; end if;
  if p_reason is null or p_reason not in ('spillage','breakage','expired','staff','prep_error','other') then raise exception 'stock.invalid_reason'; end if;
  select * into v_t from pos._stock_target(v_reg.org_id, p_kind, p_id);
  return pos._stock_change(v_reg.org_id, v_reg.location_id, v_t.o_product, v_t.o_item, -p_qty, 'waste', p_reason, p_note, p_by, v_reg.id);
end;
$$;

-- Conteo de inventario de un local: se registra lo esperado, lo contado y
-- la diferencia, y el stock queda en lo contado.
--   p_lines = [{"kind":"product|item","id":uuid,"counted":12.5}, ...]
create function pos.inventory_count(
  p_location_id uuid, p_lines jsonb, p_name text default null, p_note text default null, p_by text default null,
  p_client_transaction_id uuid default null
) returns pos.stock_counts
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_org uuid; v_row pos.stock_counts; v_id uuid := gen_random_uuid(); v_line jsonb; v_t record;
  v_expected numeric; v_counted numeric; v_name text; v_unit text; v_lines jsonb := '[]'::jsonb; v_var int := 0; v_seen text[] := '{}';
begin
  select org_id into v_org from pos.locations where id = p_location_id;
  if v_org is null then raise exception 'location.not_found'; end if;
  perform pos._require_catalog_role(v_org);
  perform set_config('pos.operator', coalesce(p_by, ''), true);
  if p_client_transaction_id is not null then
    select * into v_row from pos.stock_counts where client_transaction_id = p_client_transaction_id and location_id = p_location_id;
    if v_row.id is not null then return v_row; end if;
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'stocktake.no_lines'; end if;
  -- Los movimientos se escriben antes que la fila del conteo (ver abajo).
  set constraints pos.inventory_movements_count_id_org_id_fkey deferred;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    if (v_line->>'kind') || (v_line->>'id') = any (v_seen) then raise exception 'stocktake.duplicate_line'; end if;
    v_seen := v_seen || ((v_line->>'kind') || (v_line->>'id'));
    v_counted := (v_line->>'counted')::numeric;
    if v_counted is null or v_counted < 0 then raise exception 'stock.invalid_qty'; end if;
    select * into v_t from pos._stock_target(v_org, v_line->>'kind', (v_line->>'id')::uuid);
    if v_t.o_product is not null then
      select coalesce(pl.stock_qty, 0), p.name, null into v_expected, v_name, v_unit
        from pos.products p left join pos.product_locations pl on pl.product_id = p.id and pl.location_id = p_location_id where p.id = v_t.o_product;
    else
      select coalesce(sl.qty, 0), s.name, s.unit into v_expected, v_name, v_unit
        from pos.stock_items s left join pos.stock_levels sl on sl.stock_item_id = s.id and sl.location_id = p_location_id where s.id = v_t.o_item;
    end if;
    v_expected := coalesce(v_expected, 0);
    if round(v_counted, 3) <> v_expected then v_var := v_var + 1; end if;
    -- También las líneas sin diferencia: el libro muestra que se contaron.
    perform pos._stock_change(v_org, p_location_id, v_t.o_product, v_t.o_item, round(v_counted, 3) - v_expected, 'stocktake',
                              null, null, p_by, p_count_id => v_id, p_expected => v_expected);
    v_lines := v_lines || jsonb_build_object('kind', v_line->>'kind', 'id', v_line->>'id', 'name', v_name, 'unit', v_unit,
                                             'expected', v_expected, 'counted', round(v_counted, 3), 'variance', round(v_counted, 3) - v_expected);
  end loop;

  -- La fila del conteo va al final (los movimientos ya la referencian:
  -- la FK es diferida y se valida al cerrar la transacción).
  insert into pos.stock_counts (id, org_id, location_id, name, lines, items_counted, items_with_variance, note,
                                client_transaction_id, operator_name, created_by_user)
    values (v_id, v_org, p_location_id, nullif(trim(p_name), ''), v_lines, jsonb_array_length(v_lines), v_var, nullif(trim(p_note), ''),
            p_client_transaction_id, nullif(trim(p_by), ''), auth.uid())
    returning * into v_row;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- Tipo de negocio (y catálogo de ejemplo si el negocio está vacío)
-- ---------------------------------------------------------------------
create function pos._seed_catalog(p_org_id uuid, p_type text) returns void
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare
  es boolean := (select language = 'es' from pos.organizations where id = p_org_id);
  c_coffee uuid; c_cold uuid; c_food uuid; c_sweet uuid; c_drinks uuid; c_mains uuid; c_starters uuid; c_desserts uuid; c_beer uuid; c_wine uuid; c_snacks uuid; c_gelato uuid; c_extras uuid;
  g_size uuid; g_milk uuid; g_extra uuid; g_serve uuid; g_flavours uuid; g_cook uuid;
begin
  -- Nombres en el idioma del negocio; precios de ejemplo (se editan).
  if p_type in ('cafe', 'food_truck') then
    insert into pos.categories (org_id, name, color, sort_order) values
      (p_org_id, case when es then 'Café' else 'Coffee' end, '#C8A27C', 1) returning id into c_coffee;
    insert into pos.categories (org_id, name, color, sort_order) values
      (p_org_id, case when es then 'Bebidas frías' else 'Cold drinks' end, '#8FB8DE', 2) returning id into c_cold;
    insert into pos.categories (org_id, name, color, sort_order) values
      (p_org_id, case when es then 'Comida' else 'Food' end, '#E3B778', 3) returning id into c_food;
    insert into pos.categories (org_id, name, color, sort_order) values
      (p_org_id, case when es then 'Dulces' else 'Sweets' end, '#E8A7B5', 4) returning id into c_sweet;
    insert into pos.modifier_groups (org_id, name, min_select, max_select, sort_order) values
      (p_org_id, case when es then 'Tamaño' else 'Size' end, 1, 1, 1) returning id into g_size;
    insert into pos.modifiers (org_id, group_id, name, price_delta, is_default, sort_order) values
      (p_org_id, g_size, 'Regular', 0, true, 1), (p_org_id, g_size, case when es then 'Grande' else 'Large' end, 0.50, false, 2);
    insert into pos.modifier_groups (org_id, name, min_select, max_select, sort_order) values
      (p_org_id, case when es then 'Leche' else 'Milk' end, 1, 1, 2) returning id into g_milk;
    insert into pos.modifiers (org_id, group_id, name, price_delta, is_default, sort_order) values
      (p_org_id, g_milk, case when es then 'Entera' else 'Full cream' end, 0, true, 1), (p_org_id, g_milk, case when es then 'Descremada' else 'Trim' end, 0, false, 2),
      (p_org_id, g_milk, case when es then 'Avena' else 'Oat' end, 0.80, false, 3), (p_org_id, g_milk, case when es then 'Soya' else 'Soy' end, 0.80, false, 4);
    insert into pos.modifier_groups (org_id, name, min_select, max_select, sort_order) values
      (p_org_id, 'Extras', 0, 3, 3) returning id into g_extra;
    insert into pos.modifiers (org_id, group_id, name, price_delta, sort_order) values
      (p_org_id, g_extra, case when es then 'Shot extra' else 'Extra shot' end, 0.50, 1), (p_org_id, g_extra, case when es then 'Descafeinado' else 'Decaf' end, 0, 2),
      (p_org_id, g_extra, case when es then 'Jarabe' else 'Syrup' end, 0.80, 3);
    insert into pos.products (org_id, category_id, name, price, station, sort_order) values
      (p_org_id, c_coffee, 'Flat white', 5.50, 'coffee', 1), (p_org_id, c_coffee, 'Latte', 5.50, 'coffee', 2),
      (p_org_id, c_coffee, 'Cappuccino', 5.50, 'coffee', 3), (p_org_id, c_coffee, 'Long black', 4.80, 'coffee', 4),
      (p_org_id, c_coffee, 'Espresso', 4.00, 'coffee', 5), (p_org_id, c_coffee, 'Mocha', 6.00, 'coffee', 6),
      (p_org_id, c_coffee, 'Chai latte', 5.80, 'coffee', 7),
      (p_org_id, c_cold, case when es then 'Café helado' else 'Iced coffee' end, 7.00, 'coffee', 8),
      (p_org_id, c_cold, case when es then 'Jugo de naranja' else 'Orange juice' end, 5.50, 'none', 9),
      (p_org_id, c_food, case when es then 'Sándwich de jamón y queso' else 'Ham & cheese toastie' end, 10.50, 'kitchen', 10),
      (p_org_id, c_food, 'BLT', 12.00, 'kitchen', 11),
      (p_org_id, c_sweet, case when es then 'Muffin' else 'Muffin' end, 4.50, 'none', 12),
      (p_org_id, c_sweet, case when es then 'Scone de queso' else 'Cheese scone' end, 5.00, 'none', 13);
    insert into pos.product_modifier_groups (org_id, product_id, group_id, sort_order)
      select p_org_id, p.id, g.id, g.sort_order from pos.products p cross join pos.modifier_groups g
      where p.org_id = p_org_id and p.category_id = c_coffee and g.id in (g_size, g_milk, g_extra)
        and not (p.name in ('Espresso', 'Long black') and g.id = g_milk);
  elsif p_type = 'gelato' then
    insert into pos.categories (org_id, name, color, sort_order) values
      (p_org_id, case when es then 'Helados' else 'Gelato' end, '#F2C6D0', 1) returning id into c_gelato;
    insert into pos.categories (org_id, name, color, sort_order) values
      (p_org_id, case when es then 'Para llevar' else 'Take home' end, '#B9D8C2', 2) returning id into c_extras;
    insert into pos.categories (org_id, name, color, sort_order) values
      (p_org_id, case when es then 'Bebidas' else 'Drinks' end, '#8FB8DE', 3) returning id into c_drinks;
    insert into pos.modifier_groups (org_id, name, min_select, max_select, sort_order) values
      (p_org_id, case when es then 'Vaso o cono' else 'Cup or cone' end, 1, 1, 1) returning id into g_serve;
    insert into pos.modifiers (org_id, group_id, name, price_delta, is_default, sort_order) values
      (p_org_id, g_serve, case when es then 'Vaso' else 'Cup' end, 0, true, 1), (p_org_id, g_serve, case when es then 'Cono' else 'Cone' end, 0, false, 2),
      (p_org_id, g_serve, case when es then 'Cono de galleta' else 'Waffle cone' end, 1.50, false, 3);
    insert into pos.modifier_groups (org_id, name, min_select, max_select, sort_order) values
      (p_org_id, case when es then 'Sabores' else 'Flavours' end, 1, 3, 2) returning id into g_flavours;
    insert into pos.modifiers (org_id, group_id, name, price_delta, sort_order) values
      (p_org_id, g_flavours, case when es then 'Chocolate' else 'Chocolate' end, 0, 1), (p_org_id, g_flavours, case when es then 'Vainilla' else 'Vanilla' end, 0, 2),
      (p_org_id, g_flavours, case when es then 'Frutilla' else 'Strawberry' end, 0, 3), (p_org_id, g_flavours, 'Pistachio', 0, 4),
      (p_org_id, g_flavours, case when es then 'Limón' else 'Lemon sorbet' end, 0, 5), (p_org_id, g_flavours, case when es then 'Dulce de leche' else 'Salted caramel' end, 0, 6);
    insert into pos.modifier_groups (org_id, name, min_select, max_select, sort_order) values
      (p_org_id, 'Toppings', 0, 3, 3) returning id into g_extra;
    insert into pos.modifiers (org_id, group_id, name, price_delta, sort_order) values
      (p_org_id, g_extra, case when es then 'Salsa de chocolate' else 'Chocolate sauce' end, 1.00, 1), (p_org_id, g_extra, case when es then 'Nueces' else 'Nuts' end, 1.00, 2);
    insert into pos.products (org_id, category_id, name, price, sort_order) values
      (p_org_id, c_gelato, case when es then '1 bocha' else '1 scoop' end, 6.00, 1),
      (p_org_id, c_gelato, case when es then '2 bochas' else '2 scoops' end, 8.50, 2),
      (p_org_id, c_gelato, case when es then '3 bochas' else '3 scoops' end, 10.50, 3),
      (p_org_id, c_extras, case when es then 'Pote 500 ml' else 'Take-home tub 500 ml' end, 16.00, 4),
      (p_org_id, c_drinks, 'Affogato', 7.50, 5);
    insert into pos.product_modifier_groups (org_id, product_id, group_id, sort_order)
      select p_org_id, p.id, g.id, g.sort_order from pos.products p cross join pos.modifier_groups g
      where p.org_id = p_org_id and p.category_id = c_gelato and g.org_id = p_org_id and g.id in (g_serve, g_flavours, g_extra);
    -- 1, 2 o 3 sabores según el tamaño: el máximo del grupo es 3 y la
    -- caja limita por producto (se ajusta en Productos si hace falta).
  elsif p_type in ('restaurant', 'bar') then
    if p_type = 'restaurant' then
      insert into pos.categories (org_id, name, color, sort_order) values
        (p_org_id, case when es then 'Entradas' else 'Starters' end, '#B9D8C2', 1) returning id into c_starters;
      insert into pos.categories (org_id, name, color, sort_order) values
        (p_org_id, case when es then 'Fondos' else 'Mains' end, '#E3B778', 2) returning id into c_mains;
      insert into pos.categories (org_id, name, color, sort_order) values
        (p_org_id, case when es then 'Postres' else 'Desserts' end, '#E8A7B5', 3) returning id into c_desserts;
    else
      insert into pos.categories (org_id, name, color, sort_order) values
        (p_org_id, case when es then 'Snacks' else 'Snacks' end, '#E3B778', 3) returning id into c_snacks;
    end if;
    insert into pos.categories (org_id, name, color, sort_order) values
      (p_org_id, case when es then 'Cervezas' else 'Beer' end, '#E9C46A', 4) returning id into c_beer;
    insert into pos.categories (org_id, name, color, sort_order) values
      (p_org_id, case when es then 'Vinos' else 'Wine' end, '#B56576', 5) returning id into c_wine;
    insert into pos.categories (org_id, name, color, sort_order) values
      (p_org_id, case when es then 'Sin alcohol' else 'Soft drinks' end, '#8FB8DE', 6) returning id into c_drinks;
    if p_type = 'restaurant' then
      insert into pos.modifier_groups (org_id, name, min_select, max_select, sort_order) values
        (p_org_id, case when es then 'Punto de la carne' else 'Cooking' end, 1, 1, 1) returning id into g_cook;
      insert into pos.modifiers (org_id, group_id, name, sort_order, is_default) values
        (p_org_id, g_cook, case when es then 'Jugoso' else 'Rare' end, 1, false), (p_org_id, g_cook, case when es then 'A punto' else 'Medium' end, 2, true),
        (p_org_id, g_cook, case when es then 'Bien cocido' else 'Well done' end, 3, false);
      insert into pos.products (org_id, category_id, name, price, station, sort_order) values
        (p_org_id, c_starters, case when es then 'Pan de ajo' else 'Garlic bread' end, 9.00, 'kitchen', 1),
        (p_org_id, c_starters, case when es then 'Sopa del día' else 'Soup of the day' end, 12.00, 'kitchen', 2),
        (p_org_id, c_mains, case when es then 'Filete' else 'Sirloin steak' end, 34.00, 'kitchen', 3),
        (p_org_id, c_mains, 'Fish & chips', 26.00, 'kitchen', 4),
        (p_org_id, c_mains, case when es then 'Risotto de hongos' else 'Mushroom risotto' end, 27.00, 'kitchen', 5),
        (p_org_id, c_desserts, case when es then 'Pavlova' else 'Pavlova' end, 14.00, 'kitchen', 6);
      insert into pos.product_modifier_groups (org_id, product_id, group_id)
        select p_org_id, id, g_cook from pos.products where org_id = p_org_id and name in ('Filete', 'Sirloin steak');
    else
      insert into pos.products (org_id, category_id, name, price, station, sort_order) values
        (p_org_id, c_snacks, case when es then 'Papas fritas' else 'Fries' end, 9.00, 'kitchen', 1),
        (p_org_id, c_snacks, 'Nachos', 16.00, 'kitchen', 2),
        (p_org_id, c_snacks, case when es then 'Alitas' else 'Chicken wings' end, 15.00, 'kitchen', 3);
    end if;
    insert into pos.products (org_id, category_id, name, price, station, sort_order) values
      (p_org_id, c_beer, case when es then 'Cerveza tirada' else 'Draught beer' end, 10.00, 'bar', 10),
      (p_org_id, c_beer, case when es then 'Cerveza botella' else 'Bottled beer' end, 9.00, 'bar', 11),
      (p_org_id, c_wine, case when es then 'Copa de vino tinto' else 'Glass of red' end, 12.00, 'bar', 12),
      (p_org_id, c_wine, case when es then 'Copa de vino blanco' else 'Glass of white' end, 12.00, 'bar', 13),
      (p_org_id, c_drinks, case when es then 'Bebida' else 'Soft drink' end, 5.00, 'bar', 14),
      (p_org_id, c_drinks, case when es then 'Agua mineral' else 'Sparkling water' end, 5.00, 'bar', 15);
  end if;
  -- 'events' y 'other' parten vacíos.
end;
$$;

create function pos.set_business_type(p_org_id uuid, p_type text, p_seed boolean default false) returns pos.organizations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_org pos.organizations;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin']);
  if p_type not in ('cafe','restaurant','bar','food_truck','gelato','events','other') then raise exception 'validation.invalid_option'; end if;
  update pos.organizations set business_type = p_type where id = p_org_id returning * into v_org;
  if coalesce(p_seed, false)
     and not exists (select 1 from pos.products where org_id = p_org_id)
     and not exists (select 1 from pos.categories where org_id = p_org_id) then
    perform pos._seed_catalog(p_org_id, p_type);
  end if;
  return v_org;
end;
$$;

create function pos.set_features(p_org_id uuid, p_features jsonb) returns pos.organizations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_org pos.organizations; k text;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin']);
  if p_features is null or jsonb_typeof(p_features) <> 'object' then raise exception 'validation.invalid_option'; end if;
  for k in select jsonb_object_keys(p_features) loop
    if k not in ('events','tables','kds','order_type','tips') or jsonb_typeof(p_features->k) <> 'boolean' then
      raise exception 'validation.invalid_option';
    end if;
  end loop;
  update pos.organizations set features = features || p_features where id = p_org_id returning * into v_org;
  return v_org;
end;
$$;

-- ---------------------------------------------------------------------
-- Caja: marcar agotado (staff, con PIN de caja).
-- ---------------------------------------------------------------------
create function pos.set_sold_out(p_register_id uuid, p_pin text, p_product_id uuid, p_sold_out boolean) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  if not exists (select 1 from pos.products where id = p_product_id and org_id = v_reg.org_id and active) then raise exception 'product.not_found'; end if;
  insert into pos.product_locations (org_id, product_id, location_id, sold_out)
    values (v_reg.org_id, p_product_id, v_reg.location_id, coalesce(p_sold_out, false))
    on conflict (product_id, location_id) do update set sold_out = coalesce(p_sold_out, false);
  perform pos._audit(v_reg.org_id, v_reg.id, case when p_sold_out then 'menu.sold_out' else 'menu.back_in_stock' end, 'product', p_product_id,
                     jsonb_build_object('location_id', v_reg.location_id));
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Caja: catálogo listo para vender en ESTA caja (local + tipo de caja),
-- con precio efectivo, agotados, stock, opciones y promos vigentes.
-- Solo lectura; cualquier miembro del negocio.
-- ---------------------------------------------------------------------
create function pos.register_catalog(p_register_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_for_member(p_register_id);
  return jsonb_build_object(
    'register', jsonb_build_object('id', v_reg.id, 'name', v_reg.name, 'type', v_reg.type, 'location_id', v_reg.location_id),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'color', c.color) order by c.sort_order, c.name)
      from pos.categories c where c.org_id = v_reg.org_id and c.active
        and exists (select 1 from pos.products p left join pos.product_locations pl on pl.product_id = p.id and pl.location_id = v_reg.location_id
                    where p.category_id = c.id and p.active and p.kind = v_reg.type and coalesce(pl.available, true))), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', p.name, 'price', coalesce(pl.price, p.price), 'base_price', p.price,
        'category_id', p.category_id, 'color', coalesce(p.color, c.color), 'station', p.station,
        'sold_out', coalesce(pl.sold_out, false), 'track_stock', p.track_stock,
        'stock_qty', case when p.track_stock then pl.stock_qty end, 'initial_stock', case when p.track_stock then pl.initial_stock end,
        'groups', coalesce((select jsonb_agg(pmg.group_id order by pmg.sort_order) from pos.product_modifier_groups pmg
                            join pos.modifier_groups g on g.id = pmg.group_id and g.active where pmg.product_id = p.id), '[]'::jsonb),
        'promotion', (select jsonb_build_object('bundle_qty', pr.bundle_qty, 'bundle_price', pr.bundle_price, 'name', pr.name)
                      from pos.product_promotions pr where pr.product_id = p.id and pr.active
                        and (pr.location_id is null or pr.location_id = v_reg.location_id)
                        and (pr.starts_at is null or pr.starts_at <= now()) and (pr.ends_at is null or pr.ends_at >= now())
                      order by pr.location_id nulls last, pr.created_at desc limit 1))
        order by coalesce(c.sort_order, 1000000), p.sort_order, p.name)
      from pos.products p
      left join pos.categories c on c.id = p.category_id and c.active
      left join pos.product_locations pl on pl.product_id = p.id and pl.location_id = v_reg.location_id
      where p.org_id = v_reg.org_id and p.active and p.kind = v_reg.type and coalesce(pl.available, true)), '[]'::jsonb),
    'modifier_groups', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min', g.min_select, 'max', g.max_select,
        'options', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'price_delta', m.price_delta, 'is_default', m.is_default)
                             order by m.sort_order, m.name) from pos.modifiers m where m.group_id = g.id and m.active), '[]'::jsonb))
        order by g.sort_order, g.name)
      from pos.modifier_groups g where g.org_id = v_reg.org_id and g.active
        and exists (select 1 from pos.product_modifier_groups pmg where pmg.group_id = g.id)), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------
revoke execute on function pos._require_catalog_role(uuid) from public, anon, authenticated;
revoke execute on function pos._stock_change(uuid, uuid, uuid, uuid, numeric, text, text, text, text, uuid, uuid, uuid, uuid, numeric, boolean) from public, anon, authenticated;
revoke execute on function pos._stock_target(uuid, text, uuid) from public, anon, authenticated;
revoke execute on function pos._seed_catalog(uuid, text) from public, anon, authenticated;
revoke execute on function pos._valid_color(text) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'pos.catalog_save_category(uuid, uuid, text, text, int)', 'pos.catalog_remove_category(uuid, uuid)', 'pos.catalog_reorder(uuid, text, uuid[])',
    'pos.catalog_save_product(uuid, uuid, text, numeric, uuid, text, text, text, boolean, uuid[])', 'pos.catalog_remove_product(uuid, uuid)',
    'pos.catalog_set_product_location(uuid, uuid, uuid, boolean, numeric)',
    'pos.catalog_save_modifier_group(uuid, uuid, text, int, int, jsonb)', 'pos.catalog_remove_modifier_group(uuid, uuid)',
    'pos.catalog_set_recipe(uuid, uuid, jsonb)', 'pos.catalog_set_modifier_recipe(uuid, uuid, jsonb)',
    'pos.catalog_save_promotion(uuid, uuid, uuid, int, numeric, text, uuid, timestamptz, timestamptz, boolean)', 'pos.catalog_remove_promotion(uuid, uuid)',
    'pos.inventory_save_item(uuid, uuid, text, text, numeric, text, numeric)', 'pos.inventory_remove_item(uuid, uuid)',
    'pos.inventory_receive(uuid, text, uuid, numeric, text, text, text)', 'pos.inventory_waste(uuid, text, uuid, numeric, text, text, text)',
    'pos.register_waste(uuid, text, text, uuid, numeric, text, text, text)', 'pos.inventory_count(uuid, jsonb, text, text, text, uuid)',
    'pos.set_business_type(uuid, text, boolean)', 'pos.set_features(uuid, jsonb)', 'pos.set_sold_out(uuid, text, uuid, boolean)',
    'pos.register_catalog(uuid)']
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
grant execute on all functions in schema pos to service_role;

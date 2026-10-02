-- =====================================================================
-- Productos e insumos duplicados: un doble toque en "Agregar" creaba el
-- mismo producto dos veces (34 ms de diferencia). La base de datos ahora
-- impide dos productos (o insumos) ACTIVOS con el mismo nombre en la
-- misma caja, sin importar mayúsculas ni espacios.
--
-- Limpieza previa: de cada grupo duplicado se conserva el más antiguo y
-- los demás se desactivan (no se borran: el historial de ventas los
-- sigue nombrando).
-- =====================================================================
update pos.menu_items m set active = false
where m.active and exists (
  select 1 from pos.menu_items o
  where o.register_id = m.register_id and o.active and lower(trim(o.name)) = lower(trim(m.name))
    and (o.created_at, o.id) < (m.created_at, m.id));

update pos.ingredients i set active = false
where i.active and exists (
  select 1 from pos.ingredients o
  where o.register_id = i.register_id and o.active and lower(trim(o.name)) = lower(trim(i.name))
    and (o.created_at, o.id) < (i.created_at, i.id));

create unique index menu_items_unique_active_name on pos.menu_items (register_id, lower(trim(name))) where active;
create unique index ingredients_unique_active_name on pos.ingredients (register_id, lower(trim(name))) where active;

create or replace function pos.add_menu_item(p_register_id uuid, p_pin text, p_name text, p_price numeric, p_sort_order int)
returns pos.menu_items
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_item pos.menu_items;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'validation.name_required'; end if;
  begin
    insert into pos.menu_items (org_id, register_id, name, price, sort_order)
      values (v_reg.org_id, v_reg.id, trim(p_name), p_price, coalesce(p_sort_order, 0))
      returning * into v_item;
  exception when unique_violation then
    raise exception 'menu.duplicate_name' using detail = json_build_object('name', trim(p_name))::text;
  end;
  return v_item;
end;
$$;

create or replace function pos.update_menu_item(p_register_id uuid, p_pin text, p_item_id uuid, p_name text, p_price numeric)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  begin
    update pos.menu_items set name = coalesce(nullif(trim(p_name), ''), name), price = coalesce(p_price, price)
      where id = p_item_id and register_id = v_reg.id;
  exception when unique_violation then
    raise exception 'menu.duplicate_name' using detail = json_build_object('name', trim(p_name))::text;
  end;
  return true;
end;
$$;

create or replace function pos.upsert_ingredient(
  p_register_id uuid, p_pin text, p_ingredient_id uuid, p_name text, p_unit text,
  p_container_size numeric, p_container_label text
) returns pos.ingredients
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_row pos.ingredients; v_current pos.ingredients;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;

  begin
    if p_ingredient_id is null then
      if coalesce(trim(p_name), '') = '' then raise exception 'validation.name_required'; end if;
      insert into pos.ingredients (org_id, register_id, name, unit, container_size, container_label)
        values (v_reg.org_id, v_reg.id, trim(p_name), p_unit, p_container_size, p_container_label)
        returning * into v_row;
    else
      select * into v_current from pos.ingredients where id = p_ingredient_id and register_id = v_reg.id;
      if v_current.id is null then raise exception 'ingredient.not_found'; end if;
      -- No se puede cambiar la unidad con stock cargado: el número guardado
      -- (ej. 9500) quedaría reinterpretado en silencio en la unidad nueva.
      if p_unit is not null and p_unit <> v_current.unit and v_current.stock_qty is not null then
        raise exception 'ingredient.unit_locked' using detail = json_build_object('unit', v_current.unit)::text;
      end if;
      update pos.ingredients set
        name = coalesce(nullif(trim(p_name), ''), name), unit = coalesce(p_unit, unit),
        container_size = p_container_size, container_label = p_container_label
      where id = p_ingredient_id and register_id = v_reg.id
      returning * into v_row;
    end if;
  exception when unique_violation then
    raise exception 'ingredient.duplicate_name' using detail = json_build_object('name', trim(p_name))::text;
  end;
  return v_row;
end;
$$;

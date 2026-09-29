-- =====================================================================
-- Fase 1 — Funciones del POS, portadas al modelo multi-tenant.
--
-- Reglas que cumplen TODAS las funciones de este archivo:
--   1. Primero verifican que el usuario autenticado sea miembro activo de
--      la organización dueña de la caja (_register_for_member). Como son
--      security definer se saltan la RLS, así que este chequeo es el que
--      aísla a los tenants en las escrituras.
--   2. org_id se deriva siempre de la caja en el servidor — nunca viene
--      del navegador.
--   3. PIN incorrecto => la función devuelve null / false, NUNCA lanza un
--      error. Motivo: un "raise exception" deshace toda la transacción,
--      incluido el registro del intento fallido en pin_attempts — con el
--      diseño anterior, el límite de intentos solo funcionaba en las
--      verify_*_pin sueltas, y cualquier otra función (create_event,
--      void_order, add_menu_item...) permitía probar PINs sin límite.
--      El frontend tiene que tratar null/false como "PIN incorrecto".
--      Los demás errores de validación sí lanzan excepción, como antes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Límite de intentos de PIN
-- ---------------------------------------------------------------------
create function pos._pin_locked(p_scope text, p_scope_id uuid) returns boolean
language sql stable security definer set search_path = pos, extensions, pg_temp as $$
  select exists (
    select 1 from pos.pin_attempts
    where scope = p_scope and scope_id = p_scope_id
      and locked_until is not null and locked_until > now()
  );
$$;

create function pos._pin_record(p_scope text, p_scope_id uuid, p_success boolean, p_max_fails int, p_lockout_minutes int)
returns void
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if p_success then
    insert into pos.pin_attempts (scope, scope_id, fail_count, locked_until, updated_at)
      values (p_scope, p_scope_id, 0, null, now())
      on conflict (scope, scope_id) do update set fail_count = 0, locked_until = null, updated_at = now();
  else
    insert into pos.pin_attempts (scope, scope_id, fail_count, locked_until, updated_at)
      values (p_scope, p_scope_id, 1, null, now())
      on conflict (scope, scope_id) do update set
        fail_count = pos.pin_attempts.fail_count + 1,
        locked_until = case when pos.pin_attempts.fail_count + 1 >= p_max_fails
                            then now() + make_interval(mins => p_lockout_minutes)
                            else pos.pin_attempts.locked_until end,
        updated_at = now();
  end if;
end;
$$;

-- Compara contra el hash y registra el intento. Si el scope está
-- bloqueado, devuelve false sin siquiera comparar.
create function pos._check_pin(p_scope text, p_scope_id uuid, p_hash text, p_pin text, p_max_fails int, p_lockout_minutes int)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_ok boolean;
begin
  if pos._pin_locked(p_scope, p_scope_id) then return false; end if;
  v_ok := coalesce(p_pin is not null and p_hash is not null and extensions.crypt(p_pin, p_hash) = p_hash, false);
  perform pos._pin_record(p_scope, p_scope_id, v_ok, p_max_fails, p_lockout_minutes);
  return v_ok;
end;
$$;

-- ---------------------------------------------------------------------
-- Acceso a una caja
-- ---------------------------------------------------------------------

-- Devuelve la caja si el usuario es miembro activo de su organización;
-- si no, lanza error. (No es un chequeo de PIN, así que sí puede lanzar.)
create function pos._register_for_member(p_register_id uuid) returns pos.registers
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  select * into v_reg from pos.registers where id = p_register_id;
  if v_reg.id is null or auth.uid() is null or not pos.is_org_member(v_reg.org_id) then
    raise exception 'Caja no encontrada o sin acceso';
  end if;
  return v_reg;
end;
$$;

-- Caja + PIN de caja. Devuelve null si el PIN es incorrecto.
create function pos._register_with_pin(p_register_id uuid, p_pin text) returns pos.registers
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_for_member(p_register_id);
  if not pos._check_pin('register', v_reg.id, v_reg.pin_hash, p_pin, 5, 5) then return null; end if;
  return v_reg;
end;
$$;

-- Caja + PIN de Entrega. Devuelve null si el PIN es incorrecto.
create function pos._register_with_despacho_pin(p_register_id uuid, p_pin text) returns pos.registers
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_for_member(p_register_id);
  if not pos._check_pin('despacho', v_reg.id, v_reg.despacho_pin_hash, p_pin, 5, 5) then return null; end if;
  return v_reg;
end;
$$;

-- Caja + (PIN de caja O PIN de Entrega), para anular/reabrir desde
-- cualquiera de las dos pantallas. Corrige un bug del diseño anterior:
-- antes, cada anulación hecha desde Entrega contaba como un intento
-- fallido del PIN de CAJA (se probaba ese primero), así que 5
-- anulaciones legítimas desde Entrega bloqueaban la caja 5 minutos.
-- Ahora un acierto en cualquiera de los dos no registra ningún fallo, y
-- un PIN que no coincide con ninguno cuenta como fallo en AMBOS scopes
-- (si contara solo en uno, el otro PIN se podría adivinar sin límite
-- por esta vía).
create function pos._register_with_any_pin(p_register_id uuid, p_pin text) returns pos.registers
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_for_member(p_register_id);
  if p_pin is null then return null; end if;

  if not pos._pin_locked('register', v_reg.id)
     and extensions.crypt(p_pin, v_reg.pin_hash) = v_reg.pin_hash then
    perform pos._pin_record('register', v_reg.id, true, 5, 5);
    return v_reg;
  end if;

  if not pos._pin_locked('despacho', v_reg.id)
     and extensions.crypt(p_pin, v_reg.despacho_pin_hash) = v_reg.despacho_pin_hash then
    perform pos._pin_record('despacho', v_reg.id, true, 5, 5);
    return v_reg;
  end if;

  perform pos._pin_record('register', v_reg.id, false, 5, 5);
  perform pos._pin_record('despacho', v_reg.id, false, 5, 5);
  return null;
end;
$$;

-- PIN de supervisor de la organización (autoriza cortesías). Límite más
-- estricto que el de las cajas.
create function pos._check_supervisor_pin(p_org_id uuid, p_pin text) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_hash text;
begin
  select supervisor_pin_hash into v_hash from pos.org_secrets where org_id = p_org_id;
  return pos._check_pin('supervisor', p_org_id, v_hash, p_pin, 3, 15);
end;
$$;

-- ---------------------------------------------------------------------
-- Verificación de PIN desde la pantalla (devuelven true/false)
-- ---------------------------------------------------------------------
create function pos.verify_register_pin(p_register_id uuid, p_pin text) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  return (pos._register_with_pin(p_register_id, p_pin)).id is not null;
end;
$$;

create function pos.verify_despacho_pin(p_register_id uuid, p_pin text) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  return (pos._register_with_despacho_pin(p_register_id, p_pin)).id is not null;
end;
$$;

create function pos.verify_supervisor_pin(p_register_id uuid, p_pin text) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_for_member(p_register_id);
  return pos._check_supervisor_pin(v_reg.org_id, p_pin);
end;
$$;

-- ---------------------------------------------------------------------
-- Administración de cajas (rol owner/admin; ya no hay PIN de admin)
-- ---------------------------------------------------------------------
create function pos.create_register(p_location_id uuid, p_name text, p_type text, p_pin text, p_despacho_pin text)
returns pos.registers
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_loc pos.locations; v_row pos.registers;
begin
  select * into v_loc from pos.locations where id = p_location_id;
  if v_loc.id is null then raise exception 'Ubicación no encontrada'; end if;
  perform pos._require_org_role(v_loc.org_id, array['owner','admin']);
  if p_type not in ('producto','ticket') then raise exception 'Tipo inválido'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'El nombre es obligatorio'; end if;

  insert into pos.registers (org_id, location_id, name, type, pin_hash, despacho_pin_hash)
    values (v_loc.org_id, v_loc.id, trim(p_name), p_type, pos._hash_pin(p_pin), pos._hash_pin(p_despacho_pin))
    returning * into v_row;
  return v_row;
end;
$$;

create function pos.update_register(
  p_register_id uuid, p_name text default null, p_pin text default null,
  p_despacho_pin text default null, p_active boolean default null
) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  select * into v_reg from pos.registers where id = p_register_id;
  if v_reg.id is null then raise exception 'Caja no encontrada'; end if;
  perform pos._require_org_role(v_reg.org_id, array['owner','admin']);

  update pos.registers set
    name              = coalesce(nullif(trim(p_name), ''), name),
    pin_hash          = case when p_pin is null then pin_hash else pos._hash_pin(p_pin) end,
    despacho_pin_hash = case when p_despacho_pin is null then despacho_pin_hash else pos._hash_pin(p_despacho_pin) end,
    active            = coalesce(p_active, active)
  where id = p_register_id;

  -- Un PIN nuevo desbloquea su scope (el bloqueo era contra el PIN viejo).
  if p_pin is not null then delete from pos.pin_attempts where scope = 'register' and scope_id = p_register_id; end if;
  if p_despacho_pin is not null then delete from pos.pin_attempts where scope = 'despacho' and scope_id = p_register_id; end if;
  return true;
end;
$$;

create function pos.reset_ticket_numbering(p_register_id uuid, p_event_id uuid, p_start_at int default 1)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  select * into v_reg from pos.registers where id = p_register_id;
  if v_reg.id is null then raise exception 'Caja no encontrada'; end if;
  perform pos._require_org_role(v_reg.org_id, array['owner','admin']);
  if p_start_at is null or p_start_at < 1 then raise exception 'El número inicial debe ser 1 o mayor'; end if;
  -- La FK compuesta (event_id, org_id) rechaza un evento de otra organización.
  insert into pos.ticket_counters (org_id, register_id, event_id, next_ticket)
    values (v_reg.org_id, p_register_id, p_event_id, p_start_at)
    on conflict (register_id, event_id) do update set next_ticket = p_start_at;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Eventos (con PIN de caja; el evento es de la organización de la caja)
-- ---------------------------------------------------------------------
create function pos.create_event(p_register_id uuid, p_pin text, p_name text, p_event_date date, p_location_id uuid default null)
returns pos.events
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_event pos.events;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'El nombre es obligatorio'; end if;
  -- La FK compuesta (location_id, org_id) rechaza una ubicación de otra org.
  insert into pos.events (org_id, location_id, name, event_date, active)
    values (v_reg.org_id, p_location_id, trim(p_name), p_event_date, true)
    returning * into v_event;
  return v_event;
end;
$$;

create function pos.close_event(p_register_id uuid, p_pin text, p_event_id uuid)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  update pos.events set active = false where id = p_event_id and org_id = v_reg.org_id;
  if not found then raise exception 'Evento no encontrado'; end if;
  return true;
end;
$$;

create function pos.reopen_event(p_register_id uuid, p_pin text, p_event_id uuid)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  update pos.events set active = true where id = p_event_id and org_id = v_reg.org_id;
  if not found then raise exception 'Evento no encontrado'; end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Menú y stock
-- ---------------------------------------------------------------------
create function pos.add_menu_item(p_register_id uuid, p_pin text, p_name text, p_price numeric, p_sort_order int)
returns pos.menu_items
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_item pos.menu_items;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  insert into pos.menu_items (org_id, register_id, name, price, sort_order)
    values (v_reg.org_id, v_reg.id, p_name, p_price, coalesce(p_sort_order, 0))
    returning * into v_item;
  return v_item;
end;
$$;

create function pos.update_menu_item(p_register_id uuid, p_pin text, p_item_id uuid, p_name text, p_price numeric)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  update pos.menu_items set name = coalesce(p_name, name), price = coalesce(p_price, price)
    where id = p_item_id and register_id = v_reg.id;
  return true;
end;
$$;

create function pos.remove_menu_item(p_register_id uuid, p_pin text, p_item_id uuid)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  update pos.menu_items set active = false where id = p_item_id and register_id = v_reg.id;
  return true;
end;
$$;

create function pos.set_item_color(p_register_id uuid, p_pin text, p_item_id uuid, p_color text)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  update pos.menu_items set color = p_color where id = p_item_id and register_id = v_reg.id;
  return true;
end;
$$;

create function pos.disable_stock(p_register_id uuid, p_pin text, p_item_id uuid)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  update pos.menu_items set track_stock = false where id = p_item_id and register_id = v_reg.id;
  return true;
end;
$$;

-- p_mode = 'reset' -> fija stock_qty e initial_stock en p_qty (carga inicial).
-- p_mode = 'add'   -> suma p_qty a ambos (reposición).
create function pos.restock_item(
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

  select * into v_item from pos.menu_items where id = p_item_id and register_id = v_reg.id for update;
  if v_item.id is null then raise exception 'Producto no encontrado'; end if;

  if p_mode = 'reset' then
    v_new_stock := p_qty; v_new_initial := p_qty; v_type := 'carga_inicial';
  elsif p_mode = 'add' then
    v_new_stock := coalesce(v_item.stock_qty, 0) + p_qty;
    v_new_initial := coalesce(v_item.initial_stock, 0) + p_qty;
    v_type := 'restock';
  else
    raise exception 'Modo inválido';
  end if;

  update pos.menu_items set track_stock = true, stock_qty = v_new_stock, initial_stock = v_new_initial
    where id = p_item_id and register_id = v_reg.id returning * into v_item;

  insert into pos.stock_movements (org_id, register_id, menu_item_id, type, qty_change, qty_after, note, created_by, created_by_user)
    values (v_reg.org_id, v_reg.id, p_item_id, v_type, p_qty, v_new_stock, p_note, p_by, auth.uid());

  return v_item;
end;
$$;

-- ---------------------------------------------------------------------
-- Insumos
-- ---------------------------------------------------------------------
create function pos.upsert_ingredient(
  p_register_id uuid, p_pin text, p_ingredient_id uuid, p_name text, p_unit text,
  p_container_size numeric, p_container_label text
) returns pos.ingredients
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_row pos.ingredients; v_current pos.ingredients;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;

  if p_ingredient_id is null then
    insert into pos.ingredients (org_id, register_id, name, unit, container_size, container_label)
      values (v_reg.org_id, v_reg.id, p_name, p_unit, p_container_size, p_container_label)
      returning * into v_row;
  else
    select * into v_current from pos.ingredients where id = p_ingredient_id and register_id = v_reg.id;
    if v_current.id is null then raise exception 'Insumo no encontrado'; end if;
    -- No se puede cambiar la unidad con stock cargado: el número guardado
    -- (ej. 9500) quedaría reinterpretado en silencio en la unidad nueva.
    if p_unit is not null and p_unit <> v_current.unit and v_current.stock_qty is not null then
      raise exception 'No se puede cambiar la unidad con stock cargado (%). Usa "Reiniciar a" con la unidad nueva primero.', v_current.unit;
    end if;
    update pos.ingredients set
      name = coalesce(p_name, name), unit = coalesce(p_unit, unit),
      container_size = p_container_size, container_label = p_container_label
    where id = p_ingredient_id and register_id = v_reg.id
    returning * into v_row;
  end if;
  return v_row;
end;
$$;

create function pos.remove_ingredient(p_register_id uuid, p_pin text, p_ingredient_id uuid)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  update pos.ingredients set active = false where id = p_ingredient_id and register_id = v_reg.id;
  return true;
end;
$$;

create function pos.restock_ingredient(
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

  select * into v_row from pos.ingredients where id = p_ingredient_id and register_id = v_reg.id for update;
  if v_row.id is null then raise exception 'Insumo no encontrado'; end if;

  if p_mode = 'reset' then
    v_new_stock := p_qty; v_new_initial := p_qty; v_type := 'carga_inicial';
  elsif p_mode = 'add' then
    v_new_stock := coalesce(v_row.stock_qty, 0) + p_qty;
    v_new_initial := coalesce(v_row.initial_stock, 0) + p_qty;
    v_type := 'restock';
  else
    raise exception 'Modo inválido';
  end if;

  update pos.ingredients set stock_qty = v_new_stock, initial_stock = v_new_initial
    where id = p_ingredient_id and register_id = v_reg.id returning * into v_row;

  insert into pos.stock_movements (org_id, register_id, ingredient_id, type, qty_change, qty_after, created_by, created_by_user)
    values (v_reg.org_id, v_reg.id, p_ingredient_id, v_type, p_qty, v_new_stock, p_by, auth.uid());

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- Receta — reemplaza la lista completa de una vez.
-- p_recipe = [{"ingredient_id": "...", "qty_per_unit": 100}, ...]
-- Las FKs compuestas de recipe_items ya impiden mezclar cajas; la
-- validación de acá es para devolver un mensaje claro.
-- ---------------------------------------------------------------------
create function pos.set_recipe(p_register_id uuid, p_pin text, p_menu_item_id uuid, p_recipe jsonb)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_line jsonb; v_qty numeric;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;

  if not exists (select 1 from pos.menu_items where id = p_menu_item_id and register_id = v_reg.id) then
    raise exception 'Producto no encontrado en esta caja';
  end if;

  for v_line in select * from jsonb_array_elements(coalesce(p_recipe, '[]'::jsonb)) loop
    if not exists (select 1 from pos.ingredients where id = (v_line->>'ingredient_id')::uuid and register_id = v_reg.id) then
      raise exception 'Un insumo de la receta no pertenece a esta caja';
    end if;
    v_qty := (v_line->>'qty_per_unit')::numeric;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Cantidad de receta inválida para un insumo';
    end if;
  end loop;

  delete from pos.recipe_items where menu_item_id = p_menu_item_id and register_id = v_reg.id;
  insert into pos.recipe_items (org_id, register_id, menu_item_id, ingredient_id, qty_per_unit)
    select v_reg.org_id, v_reg.id, p_menu_item_id, (l->>'ingredient_id')::uuid, (l->>'qty_per_unit')::numeric
    from jsonb_array_elements(coalesce(p_recipe, '[]'::jsonb)) l;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Promociones
-- ---------------------------------------------------------------------
create function pos.upsert_promotion(
  p_register_id uuid, p_pin text, p_promotion_id uuid, p_menu_item_id uuid, p_name text,
  p_bundle_qty int, p_bundle_price numeric, p_active boolean, p_starts_at timestamptz, p_ends_at timestamptz
) returns pos.promotions
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_row pos.promotions;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;

  if not exists (select 1 from pos.menu_items where id = p_menu_item_id and register_id = v_reg.id) then
    raise exception 'Producto no encontrado en esta caja';
  end if;

  if p_promotion_id is null then
    insert into pos.promotions (org_id, register_id, menu_item_id, name, bundle_qty, bundle_price, active, starts_at, ends_at)
      values (v_reg.org_id, v_reg.id, p_menu_item_id, p_name, p_bundle_qty, p_bundle_price, p_active, p_starts_at, p_ends_at)
      returning * into v_row;
  else
    update pos.promotions set
      menu_item_id = p_menu_item_id, name = p_name, bundle_qty = p_bundle_qty, bundle_price = p_bundle_price,
      active = p_active, starts_at = p_starts_at, ends_at = p_ends_at
    where id = p_promotion_id and register_id = v_reg.id
    returning * into v_row;
    if v_row.id is null then raise exception 'Promoción no encontrada en esta caja'; end if;
  end if;
  return v_row;
end;
$$;

create function pos.delete_promotion(p_register_id uuid, p_pin text, p_promotion_id uuid)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;
  delete from pos.promotions where id = p_promotion_id and register_id = v_reg.id;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Pedidos: crear
-- ---------------------------------------------------------------------
create function pos.create_order(
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

  if p_payment_method <> 'cortesia' and abs((coalesce(p_cash,0) + coalesce(p_card,0)) - v_total) > 1 then
    raise exception 'El efectivo + tarjeta no coincide con el total';
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

-- ---------------------------------------------------------------------
-- Pedidos: anular / reabrir (PIN de caja o de Entrega)
-- ---------------------------------------------------------------------

-- Repone (p_sign = 1) o vuelve a descontar (p_sign = -1) el stock de un
-- pedido: productos por sus cantidades, insumos por la foto de consumo
-- guardada al vender (nunca por la receta actual).
create function pos._apply_order_stock(p_order pos.orders, p_sign int, p_note text) returns void
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_item jsonb; v_qty numeric; v_after numeric;
begin
  for v_item in select * from jsonb_array_elements(p_order.items) loop
    if v_item ? 'id' then
      v_qty := coalesce((v_item->>'qty')::numeric, 0) * p_sign;
      update pos.menu_items
        set stock_qty = stock_qty + v_qty
        where id = (v_item->>'id')::uuid and register_id = p_order.register_id
          and track_stock = true and stock_qty is not null
        returning stock_qty into v_after;
      if found then
        insert into pos.stock_movements (org_id, register_id, menu_item_id, event_id, type, qty_change, qty_after, note, created_by_user)
          values (p_order.org_id, p_order.register_id, (v_item->>'id')::uuid, p_order.event_id, 'ajuste', v_qty, v_after, p_note, auth.uid());
      end if;
    end if;
  end loop;

  if p_order.ingredient_consumption is not null then
    for v_item in select * from jsonb_array_elements(p_order.ingredient_consumption) loop
      v_qty := (v_item->>'qty')::numeric * p_sign;
      update pos.ingredients
        set stock_qty = coalesce(stock_qty, 0) + v_qty
        where id = (v_item->>'ingredient_id')::uuid and register_id = p_order.register_id
        returning stock_qty into v_after;
      if found then
        insert into pos.stock_movements (org_id, register_id, ingredient_id, event_id, type, qty_change, qty_after, note, created_by_user)
          values (p_order.org_id, p_order.register_id, (v_item->>'ingredient_id')::uuid, p_order.event_id, 'ajuste', v_qty, v_after, p_note, auth.uid());
      end if;
    end loop;
  end if;
end;
$$;

create function pos.void_order(p_register_id uuid, p_pin text, p_order_id uuid)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_order pos.orders;
begin
  v_reg := pos._register_with_any_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;

  -- Transición atómica: solo tiene efecto si el pedido NO estaba anulado.
  -- Si dos dispositivos anulan a la vez, solo uno repone stock.
  update pos.orders set status = 'anulado'
    where id = p_order_id and register_id = v_reg.id and status <> 'anulado'
    returning * into v_order;

  if not found then
    if not exists (select 1 from pos.orders where id = p_order_id and register_id = v_reg.id) then
      raise exception 'Pedido no encontrado';
    end if;
    return true; -- ya estaba anulado
  end if;

  -- Los pedidos de prueba nunca descontaron stock real: no se repone nada.
  if not v_order.is_test then
    perform pos._apply_order_stock(v_order, 1, 'Repuesto por anular ticket #' || v_order.ticket_num);
  end if;
  return true;
end;
$$;

create function pos.reopen_order(p_register_id uuid, p_pin text, p_order_id uuid)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_order pos.orders;
begin
  v_reg := pos._register_with_any_pin(p_register_id, p_pin);
  if v_reg.id is null then return false; end if;

  -- Transición atómica anulado -> reabierto: solo la llamada que la gana
  -- vuelve a descontar stock (protege contra un doble descuento).
  update pos.orders set status = 'pendiente_entrega', delivered_at = null
    where id = p_order_id and register_id = v_reg.id and status = 'anulado'
    returning * into v_order;

  if not found then
    -- No estaba anulado (ej. "entregado" que se reabre para corregir):
    -- no hay stock que mover, solo cambia el estado.
    update pos.orders set status = 'pendiente_entrega', delivered_at = null
      where id = p_order_id and register_id = v_reg.id;
    if not found then raise exception 'Pedido no encontrado'; end if;
    return true;
  end if;

  if not v_order.is_test then
    perform pos._apply_order_stock(v_order, -1, 'Descontado de nuevo al reabrir ticket #' || v_order.ticket_num);
  end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Entrega (PIN de Entrega)
-- ---------------------------------------------------------------------
create function pos.despacho_toggle_item(p_register_id uuid, p_despacho_pin text, p_order_id uuid, p_item_index int)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_despacho_pin(p_register_id, p_despacho_pin);
  if v_reg.id is null then return false; end if;
  -- Un solo UPDATE: dos toques simultáneos se serializan, no se pisan.
  update pos.orders
    set items = jsonb_set(
      items, array[p_item_index::text, 'delivered'],
      to_jsonb(not coalesce((items->p_item_index->>'delivered')::boolean, false))
    )
    where id = p_order_id and register_id = v_reg.id
      and p_item_index >= 0 and p_item_index < jsonb_array_length(items);
  return true;
end;
$$;

create function pos.despacho_confirm_all(p_register_id uuid, p_despacho_pin text, p_order_id uuid, p_delivered_by text)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  v_reg := pos._register_with_despacho_pin(p_register_id, p_despacho_pin);
  if v_reg.id is null then return false; end if;
  -- Un solo UPDATE (antes era leer + escribir por separado).
  update pos.orders set
    items = (select jsonb_agg(elem || '{"delivered":true}'::jsonb) from jsonb_array_elements(items) elem),
    status = 'entregado', delivered_at = now(), delivered_by = p_delivered_by
  where id = p_order_id and register_id = v_reg.id and status = 'pendiente_entrega';
  return true;
end;
$$;

-- =====================================================================
-- Permisos de ejecución.
-- Se revoca todo y se habilita solo la API pública, solo para usuarios
-- autenticados. Las funciones internas (prefijo _) no se pueden llamar
-- desde la API.
-- =====================================================================
revoke execute on all functions in schema pos from public, anon, authenticated;

-- Usadas por las políticas RLS (se evalúan con los permisos del usuario).
grant execute on function pos.user_org_ids() to authenticated;
grant execute on function pos.has_org_role(uuid, text[]) to authenticated;
grant execute on function pos.is_org_member(uuid) to authenticated;

-- Organización, ubicaciones, miembros
grant execute on function pos.create_organization(text, text, text) to authenticated;
grant execute on function pos.create_location(uuid, text) to authenticated;
grant execute on function pos.update_location(uuid, text, boolean) to authenticated;
grant execute on function pos.add_member(uuid, text, text) to authenticated;
grant execute on function pos.set_member_role(uuid, uuid, text, text) to authenticated;
grant execute on function pos.set_supervisor_pin(uuid, text) to authenticated;

-- PIN
grant execute on function pos.verify_register_pin(uuid, text) to authenticated;
grant execute on function pos.verify_despacho_pin(uuid, text) to authenticated;
grant execute on function pos.verify_supervisor_pin(uuid, text) to authenticated;

-- Cajas y numeración
grant execute on function pos.create_register(uuid, text, text, text, text) to authenticated;
grant execute on function pos.update_register(uuid, text, text, text, boolean) to authenticated;
grant execute on function pos.reset_ticket_numbering(uuid, uuid, int) to authenticated;

-- Eventos
grant execute on function pos.create_event(uuid, text, text, date, uuid) to authenticated;
grant execute on function pos.close_event(uuid, text, uuid) to authenticated;
grant execute on function pos.reopen_event(uuid, text, uuid) to authenticated;

-- Menú, stock, insumos, recetas, promociones
grant execute on function pos.add_menu_item(uuid, text, text, numeric, int) to authenticated;
grant execute on function pos.update_menu_item(uuid, text, uuid, text, numeric) to authenticated;
grant execute on function pos.remove_menu_item(uuid, text, uuid) to authenticated;
grant execute on function pos.set_item_color(uuid, text, uuid, text) to authenticated;
grant execute on function pos.disable_stock(uuid, text, uuid) to authenticated;
grant execute on function pos.restock_item(uuid, text, uuid, text, numeric, text, text) to authenticated;
grant execute on function pos.upsert_ingredient(uuid, text, uuid, text, text, numeric, text) to authenticated;
grant execute on function pos.remove_ingredient(uuid, text, uuid) to authenticated;
grant execute on function pos.restock_ingredient(uuid, text, uuid, text, numeric, text) to authenticated;
grant execute on function pos.set_recipe(uuid, text, uuid, jsonb) to authenticated;
grant execute on function pos.upsert_promotion(uuid, text, uuid, uuid, text, int, numeric, boolean, timestamptz, timestamptz) to authenticated;
grant execute on function pos.delete_promotion(uuid, text, uuid) to authenticated;

-- Pedidos y Entrega
grant execute on function pos.create_order(uuid, text, uuid, jsonb, text, numeric, numeric, text, text, text, text, boolean, uuid) to authenticated;
grant execute on function pos.void_order(uuid, text, uuid) to authenticated;
grant execute on function pos.reopen_order(uuid, text, uuid) to authenticated;
grant execute on function pos.despacho_toggle_item(uuid, text, uuid, int) to authenticated;
grant execute on function pos.despacho_confirm_all(uuid, text, uuid, text) to authenticated;

grant execute on all functions in schema pos to service_role;

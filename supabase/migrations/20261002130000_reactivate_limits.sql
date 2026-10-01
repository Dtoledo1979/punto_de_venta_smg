-- =====================================================================
-- Reactivar una caja o un local respeta el límite del plan (antes solo
-- se verificaba al crear), y no se puede desactivar una caja con la
-- sesión abierta (quedaría una caja invisible con efectivo sin cerrar).
-- Misma firma: se conservan los permisos.
-- =====================================================================
create or replace function pos.update_register(
  p_register_id uuid, p_name text default null, p_pin text default null,
  p_despacho_pin text default null, p_active boolean default null
) returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers;
begin
  select * into v_reg from pos.registers where id = p_register_id;
  if v_reg.id is null then raise exception 'register.not_found'; end if;
  perform pos._require_org_role(v_reg.org_id, array['owner','admin']);

  if p_active is true and not v_reg.active then
    perform pos._check_limit(v_reg.org_id, 'registers');
  end if;
  if p_active is false and v_reg.active
     and exists (select 1 from pos.register_sessions where register_id = v_reg.id and status = 'open') then
    raise exception 'register.session_open';
  end if;

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

create or replace function pos.update_location(p_location_id uuid, p_name text default null, p_active boolean default null)
returns pos.locations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_loc pos.locations;
begin
  select * into v_loc from pos.locations where id = p_location_id;
  if v_loc.id is null then raise exception 'location.not_found'; end if;
  perform pos._require_org_role(v_loc.org_id, array['owner','admin']);
  if p_active is true and not v_loc.active then
    perform pos._check_limit(v_loc.org_id, 'locations');
  end if;
  update pos.locations set
    name = coalesce(nullif(trim(p_name), ''), name),
    active = coalesce(p_active, active)
  where id = p_location_id
  returning * into v_loc;
  return v_loc;
end;
$$;

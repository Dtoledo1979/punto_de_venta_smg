-- =====================================================================
-- Fase 6 — Onboarding y suscripciones.
--
-- Suscripción por organización: plan (trial / starter / pro) y estado
-- (trialing / active / past_due / suspended / cancelled). Los límites de
-- cada plan viven en UNA función (pos.plan_limits), no repartidos por la
-- interfaz. El cobro real (Stripe u otro) todavía no existe: las columnas
-- billing_* y la función pos.set_subscription (solo service_role, para un
-- webhook o el panel interno) son el punto de enganche.
--
-- Operar (abrir caja → vender de verdad) requiere: trialing sin vencer,
-- active o past_due (período de gracia). suspended ya cortaba todo acceso
-- (organizations.status); cancelled o prueba vencida dejan entrar para
-- ver datos y probar, pero no abrir caja.
-- =====================================================================

alter table pos.organizations
  add column plan text not null default 'trial' check (plan in ('trial','starter','pro')),
  add column subscription_status text not null default 'trialing'
    check (subscription_status in ('trialing','active','past_due','suspended','cancelled')),
  add column trial_ends_at timestamptz default (now() + interval '14 days'),
  add column billing_provider text,
  add column billing_customer_id text,
  add column billing_subscription_id text;

-- La organización existente (South Media) queda activa en el plan pro.
update pos.organizations set plan = 'pro', subscription_status = 'active', trial_ends_at = null;

-- Límites por plan (fuente única).
create function pos.plan_limits(p_plan text) returns jsonb
language sql immutable as $$
  select case p_plan
    when 'trial'   then '{"locations": 2,  "registers": 4}'::jsonb
    when 'starter' then '{"locations": 1,  "registers": 2}'::jsonb
    when 'pro'     then '{"locations": 10, "registers": 30}'::jsonb
    else '{"locations": 0, "registers": 0}'::jsonb
  end
$$;

-- Qué puede hacer la organización ahora mismo (para la base y la pantalla).
create function pos.org_entitlements(p_org_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
declare v_org pos.organizations; v_can boolean;
begin
  select * into v_org from pos.organizations where id = p_org_id;
  if v_org.id is null then raise exception 'auth.forbidden'; end if;
  if auth.uid() is not null and not pos.is_org_member(p_org_id) then raise exception 'auth.forbidden'; end if;
  v_can := v_org.status = 'active' and (
    v_org.subscription_status in ('active','past_due')
    or (v_org.subscription_status = 'trialing' and (v_org.trial_ends_at is null or v_org.trial_ends_at > now())));
  return jsonb_build_object(
    'plan', v_org.plan, 'status', v_org.subscription_status, 'trial_ends_at', v_org.trial_ends_at,
    'can_operate', v_can,
    'limits', pos.plan_limits(v_org.plan),
    'usage', jsonb_build_object(
      'locations', (select count(*) from pos.locations where org_id = p_org_id and active),
      'registers', (select count(*) from pos.registers where org_id = p_org_id and active)));
end;
$$;

create function pos._check_limit(p_org_id uuid, p_what text) returns void
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_e jsonb;
begin
  v_e := pos.org_entitlements(p_org_id);
  if (v_e->'usage'->>p_what)::int >= (v_e->'limits'->>p_what)::int then
    raise exception 'subscription.limit_reached' using detail = json_build_object('what', p_what, 'limit', v_e->'limits'->>p_what, 'plan', v_e->>'plan')::text;
  end if;
end;
$$;

-- Punto de enganche del cobro: solo service_role (webhook de billing o
-- panel interno). Nunca desde el navegador.
create function pos.set_subscription(
  p_org_id uuid, p_plan text default null, p_status text default null, p_trial_ends_at timestamptz default null,
  p_billing_provider text default null, p_billing_customer_id text default null, p_billing_subscription_id text default null
) returns pos.organizations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_org pos.organizations;
begin
  update pos.organizations set
    plan = coalesce(p_plan, plan),
    subscription_status = coalesce(p_status, subscription_status),
    trial_ends_at = coalesce(p_trial_ends_at, trial_ends_at),
    billing_provider = coalesce(p_billing_provider, billing_provider),
    billing_customer_id = coalesce(p_billing_customer_id, billing_customer_id),
    billing_subscription_id = coalesce(p_billing_subscription_id, billing_subscription_id),
    -- Suspendida por falta de pago: se corta el acceso (RLS); reactivada: vuelve.
    status = case when coalesce(p_status, subscription_status) = 'suspended' then 'suspended'
                  when status = 'suspended' and coalesce(p_status, subscription_status) in ('active','trialing','past_due') then 'active'
                  else status end
  where id = p_org_id returning * into v_org;
  if v_org.id is null then raise exception 'auth.forbidden'; end if;
  return v_org;
end;
$$;

-- Auditoría del cambio de plan/estado (el trigger de organizations ya
-- registra cambios de estado; se agregan plan y suscripción).
create or replace function pos._audit_organizations() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._audit(new.id, null, 'org.update', 'organization', new.id,
    jsonb_build_object(
      'old', jsonb_build_object('name', old.name, 'language', old.language, 'locale', old.locale, 'status', old.status,
                                'plan', old.plan, 'subscription_status', old.subscription_status, 'tax_rate', old.tax_rate, 'tax_number', old.tax_number),
      'new', jsonb_build_object('name', new.name, 'language', new.language, 'locale', new.locale, 'status', new.status,
                                'plan', new.plan, 'subscription_status', new.subscription_status, 'tax_rate', new.tax_rate, 'tax_number', new.tax_number)));
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- Alta de organización (onboarding): moneda, GST y prueba de 14 días.
-- Máximo 3 organizaciones propias por usuario (evita abuso del alta).
-- ---------------------------------------------------------------------
drop function pos.create_organization(text, text, text, text, text);
create function pos.create_organization(
  p_name text, p_slug text, p_supervisor_pin text,
  p_language text default 'en', p_locale text default 'en-NZ',
  p_currency text default 'NZD', p_tax_rate numeric default 0.15, p_tax_number text default null
) returns pos.organizations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_org pos.organizations;
begin
  if auth.uid() is null then raise exception 'auth.forbidden'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'validation.name_required'; end if;
  if (select count(*) from pos.memberships where user_id = auth.uid() and role = 'owner') >= 3 then
    raise exception 'org.too_many';
  end if;
  if p_currency !~ '^[A-Z]{3}$' then raise exception 'org.invalid_currency'; end if;
  if p_tax_rate is null or p_tax_rate < 0 or p_tax_rate >= 1 then raise exception 'org.invalid_tax_rate'; end if;
  if lower(trim(p_slug)) !~ '^[a-z0-9-]{3,40}$' then raise exception 'org.invalid_slug'; end if;
  if exists (select 1 from pos.organizations where slug = lower(trim(p_slug))) then raise exception 'org.slug_taken'; end if;

  insert into pos.organizations (name, slug, language, locale, currency, tax_rate, tax_number)
    values (trim(p_name), lower(trim(p_slug)), coalesce(p_language, 'en'), coalesce(p_locale, 'en-NZ'),
            p_currency, p_tax_rate, nullif(trim(p_tax_number), ''))
    returning * into v_org;
  insert into pos.memberships (org_id, user_id, role) values (v_org.id, auth.uid(), 'owner');
  insert into pos.org_secrets (org_id, supervisor_pin_hash) values (v_org.id, pos._hash_pin(p_supervisor_pin));
  return v_org;
end;
$$;

-- Equipo: owner/admin ven los emails de su organización (auth.users no
-- está expuesta a la API).
create function pos.list_members(p_org_id uuid)
returns table (user_id uuid, email text, role text, status text, created_at timestamptz)
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._require_org_role(p_org_id, array['owner','admin']);
  return query
    select m.user_id, u.email::text, m.role, m.status, m.created_at
    from pos.memberships m join auth.users u on u.id = m.user_id
    where m.org_id = p_org_id
    order by m.created_at;
end;
$$;

revoke execute on function pos.set_subscription(uuid, text, text, timestamptz, text, text, text) from public, anon, authenticated;
revoke execute on function pos._check_limit(uuid, text) from public, anon, authenticated;
grant execute on function pos.org_entitlements(uuid) to authenticated;
grant execute on function pos.plan_limits(text) to authenticated;
grant execute on function pos.list_members(uuid) to authenticated;
grant execute on function pos.create_organization(text, text, text, text, text, text, numeric, text) to authenticated;
grant execute on all functions in schema pos to service_role;

-- ---------------------------------------------------------------------
-- Límites del plan al crear ubicaciones/cajas; suscripción al abrir caja
-- ---------------------------------------------------------------------
create or replace function pos.create_location(p_org_id uuid, p_name text)
returns pos.locations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_loc pos.locations;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin']);
  if coalesce(trim(p_name), '') = '' then raise exception 'validation.name_required'; end if;
  perform pos._check_limit(p_org_id, 'locations');
  insert into pos.locations (org_id, name) values (p_org_id, trim(p_name)) returning * into v_loc;
  return v_loc;
end;
$$;

create or replace function pos.create_register(p_location_id uuid, p_name text, p_type text, p_pin text, p_despacho_pin text)
returns pos.registers
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_loc pos.locations; v_row pos.registers;
begin
  select * into v_loc from pos.locations where id = p_location_id;
  if v_loc.id is null then raise exception 'location.not_found'; end if;
  perform pos._require_org_role(v_loc.org_id, array['owner','admin']);
  if p_type not in ('product','ticket') then raise exception 'register.invalid_type'; end if;
  perform pos._check_limit(v_loc.org_id, 'registers');
  if coalesce(trim(p_name), '') = '' then raise exception 'validation.name_required'; end if;

  insert into pos.registers (org_id, location_id, name, type, pin_hash, despacho_pin_hash)
    values (v_loc.org_id, v_loc.id, trim(p_name), p_type, pos._hash_pin(p_pin), pos._hash_pin(p_despacho_pin))
    returning * into v_row;
  return v_row;
end;
$$;

create or replace function pos.open_register_session(p_register_id uuid, p_pin text, p_opening_float numeric, p_by text default null)
returns pos.register_sessions
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_s pos.register_sessions;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);
  if p_opening_float is null or p_opening_float < 0 then raise exception 'session.invalid_amount'; end if;
  -- Sin suscripción vigente (prueba vencida, suspendida o cancelada) no se
  -- abre caja — y sin caja abierta no hay ventas reales. El modo prueba
  -- sigue funcionando para no bloquear la configuración.
  if not (pos.org_entitlements(v_reg.org_id)->>'can_operate')::boolean then raise exception 'subscription.inactive'; end if;
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

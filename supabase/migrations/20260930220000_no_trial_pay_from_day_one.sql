-- =====================================================================
-- Sin período de prueba: se paga desde el día 1.
--
-- Una organización nueva nace en el plan "starter" con suscripción
-- "incomplete" (pago pendiente): puede configurar todo (productos, cajas,
-- equipo) y usar el modo prueba, pero NO abrir caja para ventas reales
-- hasta que el pago quede confirmado (set_subscription → 'active', que
-- llamará el webhook de Stripe cuando exista; mientras tanto, manual).
-- =====================================================================

-- Datos existentes: nada queda en prueba.
update pos.organizations set plan = 'starter' where plan = 'trial';
update pos.organizations set subscription_status = 'incomplete' where subscription_status = 'trialing';
update pos.organizations set trial_ends_at = null;

alter table pos.organizations drop constraint organizations_plan_check;
alter table pos.organizations drop constraint organizations_subscription_status_check;
alter table pos.organizations
  alter column plan set default 'starter',
  alter column subscription_status set default 'incomplete',
  alter column trial_ends_at set default null,
  add constraint organizations_plan_check check (plan in ('starter','pro')),
  add constraint organizations_subscription_status_check
    check (subscription_status in ('incomplete','active','past_due','suspended','cancelled'));
comment on column pos.organizations.trial_ends_at is 'Sin uso (no hay período de prueba). Se conserva por compatibilidad.';

create or replace function pos.plan_limits(p_plan text) returns jsonb
language sql immutable set search_path = pos, extensions, pg_temp as $$
  select case p_plan
    when 'starter' then '{"locations": 1,  "registers": 2}'::jsonb
    when 'pro'     then '{"locations": 10, "registers": 30}'::jsonb
    else '{"locations": 0, "registers": 0}'::jsonb
  end
$$;

-- Operar requiere pago confirmado (active) o período de gracia (past_due).
create or replace function pos.org_entitlements(p_org_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
declare v_org pos.organizations;
begin
  select * into v_org from pos.organizations where id = p_org_id;
  if v_org.id is null then raise exception 'auth.forbidden'; end if;
  if auth.uid() is not null and not pos.is_org_member(p_org_id) then raise exception 'auth.forbidden'; end if;
  return jsonb_build_object(
    'plan', v_org.plan, 'status', v_org.subscription_status,
    'can_operate', v_org.status = 'active' and v_org.subscription_status in ('active','past_due'),
    'limits', pos.plan_limits(v_org.plan),
    'usage', jsonb_build_object(
      'locations', (select count(*) from pos.locations where org_id = p_org_id and active),
      'registers', (select count(*) from pos.registers where org_id = p_org_id and active)));
end;
$$;

create or replace function pos.set_subscription(
  p_org_id uuid, p_plan text default null, p_status text default null, p_trial_ends_at timestamptz default null,
  p_billing_provider text default null, p_billing_customer_id text default null, p_billing_subscription_id text default null
) returns pos.organizations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_org pos.organizations;
begin
  update pos.organizations set
    plan = coalesce(p_plan, plan),
    subscription_status = coalesce(p_status, subscription_status),
    billing_provider = coalesce(p_billing_provider, billing_provider),
    billing_customer_id = coalesce(p_billing_customer_id, billing_customer_id),
    billing_subscription_id = coalesce(p_billing_subscription_id, billing_subscription_id),
    status = case when coalesce(p_status, subscription_status) = 'suspended' then 'suspended'
                  when status = 'suspended' and coalesce(p_status, subscription_status) in ('active','past_due','incomplete') then 'active'
                  else status end
  where id = p_org_id returning * into v_org;
  if v_org.id is null then raise exception 'auth.forbidden'; end if;
  return v_org;
end;
$$;
revoke execute on function pos.set_subscription(uuid, text, text, timestamptz, text, text, text) from public, anon, authenticated;

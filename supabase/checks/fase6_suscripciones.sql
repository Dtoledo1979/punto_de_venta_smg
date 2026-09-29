-- =====================================================================
-- Verificación de Fase 6: alta de organización, límites de plan,
-- suscripción y equipo. Corre después de fase5 (con ROLLBACK).
-- =====================================================================
reset role;
delete from pos.pin_attempts;
insert into auth.users (id, email, aud, role) values
  ('dddddddd-0000-0000-0000-00000000000d', 'nuevo@test.local', 'authenticated', 'authenticated');

-- O1. Un usuario nuevo crea su negocio: prueba de 14 días, GST y moneda.
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_org pos.organizations; v_e jsonb; v_loc uuid; v_reg uuid; v_i int;
begin
  v_org := pos.create_organization('Coffee Cart', 'coffee-cart', '2468', 'en', 'en-NZ', 'NZD', 0.15, '111-222-333');
  if v_org.plan <> 'trial' or v_org.subscription_status <> 'trialing' or v_org.trial_ends_at < now() + interval '13 days' then
    raise exception 'FALLA O1: prueba inicial % % %', v_org.plan, v_org.subscription_status, v_org.trial_ends_at;
  end if;
  if v_org.tax_number <> '111-222-333' or v_org.currency <> 'NZD' then raise exception 'FALLA O1: GST/moneda'; end if;
  v_e := pos.org_entitlements(v_org.id);
  if not (v_e->>'can_operate')::boolean then raise exception 'FALLA O1: una prueba vigente debería poder operar'; end if;
  begin
    perform pos.create_organization('Coffee Cart 2', 'coffee-cart', '2468');
    raise exception 'FALLA O1: aceptó un slug repetido';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'org.slug_taken' then raise exception 'FALLA O1: error inesperado %', sqlerrm; end if;
  end;

  -- O2. Límite del plan: trial = 2 ubicaciones, 4 cajas.
  v_loc := (pos.create_location(v_org.id, 'Cart')).id;
  for v_i in 1..4 loop
    v_reg := (pos.create_register(v_loc, 'Reg ' || v_i, 'product', '1357', '2468')).id;
  end loop;
  begin
    perform pos.create_register(v_loc, 'Reg 5', 'product', '1357', '2468');
    raise exception 'FALLA O2: superó el límite de cajas del plan';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'subscription.limit_reached' then raise exception 'FALLA O2: error inesperado %', sqlerrm; end if;
  end;
  perform pos.create_location(v_org.id, 'Market');
  begin
    perform pos.create_location(v_org.id, 'Third');
    raise exception 'FALLA O2: superó el límite de ubicaciones';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;

  -- O3. Con prueba vigente se abre caja.
  if (pos.open_register_session(v_reg, '1357', 0)).id is null then raise exception 'FALLA O3: no abrió caja en prueba vigente'; end if;
  insert into t2 values ('org_d', v_org.id), ('reg_d', v_reg);

  -- O4. El navegador no puede cambiar su propia suscripción.
  begin
    perform pos.set_subscription(v_org.id, 'pro', 'active');
    raise exception 'FALLA O4: authenticated cambió su plan';
  exception when insufficient_privilege then null;
  end;

  -- O5. Máximo 3 organizaciones propias.
  perform pos.create_organization('Two', 'org-two-d', '2468');
  perform pos.create_organization('Three', 'org-three-d', '2468');
  begin
    perform pos.create_organization('Four', 'org-four-d', '2468');
    raise exception 'FALLA O5: creó una cuarta organización';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK O1-O5: alta, límites y suscripción';
end $$;
reset role;

-- O6. Prueba vencida (o cancelada): no se abre caja; el modo prueba sigue.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg_d');
begin
  perform pos.set_subscription((select v from t2 where k = 'org_d')::uuid, null, null, now() - interval '1 day');
  perform set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
  perform pos.close_register_session(v_reg, '1357', 0, null, null, true);
  begin
    perform pos.open_register_session(v_reg, '1357', 0);
    raise exception 'FALLA O6: abrió caja con la prueba vencida';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'subscription.inactive' then raise exception 'FALLA O6: error inesperado %', sqlerrm; end if;
  end;
  -- Pagar (webhook de billing): vuelve a operar.
  perform pos.set_subscription((select v from t2 where k = 'org_d')::uuid, 'starter', 'active');
  if (pos.open_register_session(v_reg, '1357', 0)).id is null then raise exception 'FALLA O6: no reactivó al pagar'; end if;
  -- Suspendida: corta todo el acceso (RLS).
  perform pos.set_subscription((select v from t2 where k = 'org_d')::uuid, null, 'suspended');
  if (select status from pos.organizations where id = (select v from t2 where k = 'org_d')::uuid) <> 'suspended' then
    raise exception 'FALLA O6: suspender no cortó el acceso';
  end if;
  perform pos.set_subscription((select v from t2 where k = 'org_d')::uuid, null, 'active');
  if (select status from pos.organizations where id = (select v from t2 where k = 'org_d')::uuid) <> 'active' then
    raise exception 'FALLA O6: reactivar no devolvió el acceso';
  end if;
  raise notice 'OK O6: suscripción gobierna la operación';
end $$;

-- O7. Equipo: owner ve emails; staff no; otra org tampoco.
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  if not exists (select 1 from pos.list_members((select org_a from t_ids)) where email = 'staff-a@test.local' and role = 'staff') then
    raise exception 'FALLA O7: el owner no ve a su equipo';
  end if;
  begin
    perform pos.list_members((select v from t2 where k = 'org_d')::uuid);
    raise exception 'FALLA O7: vio el equipo de otra organización';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
end $$;
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
do $$
begin
  begin
    perform pos.list_members((select org_a from t_ids));
    raise exception 'FALLA O7: staff vio la lista de emails';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK O7: equipo visible solo para owner/admin de la org';
end $$;
reset role;

select 'FASE 6: TODAS LAS VERIFICACIONES PASARON' as resultado_fase6;

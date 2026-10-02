-- =====================================================================
-- Verificación de Fase 6: alta de organización, límites de plan,
-- suscripción y equipo. Corre después de fase5 (con ROLLBACK).
-- =====================================================================
reset role;
delete from pos.pin_attempts;
insert into auth.users (id, email, aud, role) values
  ('dddddddd-0000-0000-0000-00000000000d', 'nuevo@test.local', 'authenticated', 'authenticated');

-- O1. Un usuario nuevo crea su negocio: SIN prueba gratis — nace con pago
--     pendiente (starter / incomplete) y no puede operar hasta pagar.
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_org pos.organizations; v_e jsonb; v_loc uuid; v_reg uuid; v_i int;
begin
  v_org := pos.create_organization('Coffee Cart', 'coffee-cart', '2468', 'en', 'en-NZ', 'NZD', 0.15, '111-222-333',
    p_legal_name => 'Coffee Cart Ltd', p_address_line => '5 Cuba St', p_city => 'Wellington', p_postcode => '6011',
    p_contact_name => 'Ana', p_contact_phone => '+64 21 123 4567', p_nzbn => '9429 0000-00000');
  if v_org.plan <> 'starter' or v_org.subscription_status <> 'incomplete' or v_org.trial_ends_at is not null then
    raise exception 'FALLA O1: alta % % %', v_org.plan, v_org.subscription_status, v_org.trial_ends_at;
  end if;
  if v_org.tax_number <> '111-222-333' or v_org.currency <> 'NZD' then raise exception 'FALLA O1: GST/moneda'; end if;
  -- O1b. Datos legales y de contacto: obligatorios; NZBN opcional y normalizado.
  if v_org.legal_name <> 'Coffee Cart Ltd' or v_org.city <> 'Wellington' or v_org.nzbn <> '9429000000000'
     or v_org.contact_phone <> '+64 21 123 4567' or v_org.country <> 'NZ' then
    raise exception 'FALLA O1b: datos del negocio % %', v_org.legal_name, v_org.nzbn;
  end if;
  begin
    perform pos.create_organization('No Details', 'no-details', '2468');
    raise exception 'FALLA O1b: creó un negocio sin datos legales';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'org.details_required' then raise exception 'FALLA O1b: error inesperado %', sqlerrm; end if;
  end;
  begin
    perform pos.create_organization('Bad', 'bad-nzbn', '2468', p_legal_name => 'X', p_address_line => 'Y', p_city => 'Z',
      p_contact_name => 'W', p_contact_phone => '021 000 0000', p_nzbn => '123');
    raise exception 'FALLA O1b: aceptó un NZBN inválido';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'org.invalid_nzbn' then raise exception 'FALLA O1b: error inesperado %', sqlerrm; end if;
  end;
  begin
    perform pos.update_organization_details(v_org.id, 'Coffee Cart Ltd', '5 Cuba St', 'Wellington', null, 'Ana', 'call me');
    raise exception 'FALLA O1b: aceptó un teléfono inválido';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'org.invalid_phone' then raise exception 'FALLA O1b: error inesperado %', sqlerrm; end if;
  end;
  if (pos.update_organization_details(v_org.id, 'Coffee Cart Limited', '7 Cuba St', 'Wellington', '6011', 'Ana', '04 123 4567', '')).nzbn is not null then
    raise exception 'FALLA O1b: vaciar el NZBN no lo borró';
  end if;
  v_e := pos.org_entitlements(v_org.id);
  if (v_e->>'can_operate')::boolean then raise exception 'FALLA O1: con pago pendiente no debería poder operar'; end if;
  begin
    perform pos.create_organization('Coffee Cart 2', 'coffee-cart', '2468', p_legal_name => 'Test Ltd', p_address_line => '1 Test St', p_city => 'Christchurch', p_contact_name => 'Tester', p_contact_phone => '021 000 0000');
    raise exception 'FALLA O1: aceptó un slug repetido';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'org.slug_taken' then raise exception 'FALLA O1: error inesperado %', sqlerrm; end if;
  end;

  -- O2. Se puede configurar con pago pendiente, dentro del límite del plan
  --     starter: 1 ubicación, 2 cajas.
  v_loc := (pos.create_location(v_org.id, 'Cart')).id;
  for v_i in 1..2 loop
    v_reg := (pos.create_register(v_loc, 'Reg ' || v_i, 'product', '1357', '2468')).id;
  end loop;
  begin
    perform pos.create_register(v_loc, 'Reg 3', 'product', '1357', '2468');
    raise exception 'FALLA O2: superó el límite de cajas del plan';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'subscription.limit_reached' then raise exception 'FALLA O2: error inesperado %', sqlerrm; end if;
  end;
  begin
    perform pos.create_location(v_org.id, 'Second');
    raise exception 'FALLA O2: superó el límite de ubicaciones';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;

  -- O3. Con pago pendiente NO se abre caja (el modo prueba sí vende).
  begin
    perform pos.open_register_session(v_reg, '1357', 0);
    raise exception 'FALLA O3: abrió caja sin pago';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'subscription.inactive' then raise exception 'FALLA O3: error inesperado %', sqlerrm; end if;
  end;
  insert into t2 values ('org_d', v_org.id), ('reg_d', v_reg);

  -- O4. El navegador no puede cambiar su propia suscripción.
  begin
    perform pos.set_subscription(v_org.id, 'pro', 'active');
    raise exception 'FALLA O4: authenticated cambió su plan';
  exception when insufficient_privilege then null;
  end;

  -- O5. Máximo 3 organizaciones propias.
  perform pos.create_organization('Two', 'org-two-d', '2468', p_legal_name => 'Test Ltd', p_address_line => '1 Test St', p_city => 'Christchurch', p_contact_name => 'Tester', p_contact_phone => '021 000 0000');
  perform pos.create_organization('Three', 'org-three-d', '2468', p_legal_name => 'Test Ltd', p_address_line => '1 Test St', p_city => 'Christchurch', p_contact_name => 'Tester', p_contact_phone => '021 000 0000');
  begin
    perform pos.create_organization('Four', 'org-four-d', '2468', p_legal_name => 'Test Ltd', p_address_line => '1 Test St', p_city => 'Christchurch', p_contact_name => 'Tester', p_contact_phone => '021 000 0000');
    raise exception 'FALLA O5: creó una cuarta organización';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK O1-O5: alta, límites y suscripción';
end $$;
reset role;

-- O6. Pago confirmado (webhook de billing) → opera; cancelada → no.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg_d');
begin
  perform set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
  perform pos.set_subscription((select v from t2 where k = 'org_d')::uuid, 'starter', 'active');
  if (pos.open_register_session(v_reg, '1357', 0)).id is null then raise exception 'FALLA O6: no abrió caja con el pago confirmado'; end if;
  perform pos.close_register_session(v_reg, '1357', 0, null, null, true);
  perform pos.set_subscription((select v from t2 where k = 'org_d')::uuid, null, 'cancelled');
  begin
    perform pos.open_register_session(v_reg, '1357', 0);
    raise exception 'FALLA O6: abrió caja con la suscripción cancelada';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'subscription.inactive' then raise exception 'FALLA O6: error inesperado %', sqlerrm; end if;
  end;
  perform pos.set_subscription((select v from t2 where k = 'org_d')::uuid, null, 'active');
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
  begin
    perform pos.update_organization_details((select v from t2 where k = 'org_d')::uuid, 'Hijack Ltd', 'x', 'y', null, 'z', '021 000 0000');
    raise exception 'FALLA O7: editó los datos legales de otra organización';
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
  begin
    perform pos.update_organization_details((select org_a from t_ids), 'Staff Ltd', 'x', 'y', null, 'z', '021 000 0000');
    raise exception 'FALLA O7: staff editó los datos legales';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK O7: equipo visible solo para owner/admin de la org';
end $$;
reset role;

-- O8. Borrar una organización de prueba completa (scripts/delete-org.mjs):
--     la cascada atraviesa los guardas de inmutabilidad y no toca a otras.
do $$
declare v_org uuid := (select v from t2 where k = 'org_d')::uuid; v_a_orders int;
begin
  -- Datos "inmutables" en la org D: una venta real con pago, auditoría y sesión.
  perform set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
  perform pos.open_register_session((select v from t2 where k = 'reg_d')::uuid, '1357', 0);
  perform pos.catalog_save_product(v_org, null, 'Tea', 3, p_track_stock => true);
  perform pos.inventory_receive((select location_id from pos.registers where id = (select v from t2 where k = 'reg_d')::uuid), 'product',
                                (select id from pos.products where org_id = v_org and name = 'Tea'), 10, 'set');
  perform pos.create_event((select v from t2 where k = 'reg_d')::uuid, '1357', 'D event', current_date);
  perform pos.create_order((select v from t2 where k = 'reg_d')::uuid, '1357',
    (select id from pos.events where org_id = v_org limit 1),
    jsonb_build_array(jsonb_build_object('id', (select id from pos.products where org_id = v_org and name = 'Tea'), 'qty', 1)),
    'cash', 3, 0, 'x', null, null);
  select count(*) into v_a_orders from pos.orders where org_id = (select org_a from t_ids);

  delete from pos.organizations where id = v_org;

  if exists (select 1 from pos.orders where org_id = v_org) or exists (select 1 from pos.payments where org_id = v_org)
     or exists (select 1 from pos.audit_log where org_id = v_org) or exists (select 1 from pos.register_sessions where org_id = v_org) then
    raise exception 'FALLA O8: quedaron datos de la organización borrada';
  end if;
  if (select count(*) from pos.orders where org_id = (select org_a from t_ids)) <> v_a_orders then
    raise exception 'FALLA O8: borrar D afectó a otra organización';
  end if;
  raise notice 'OK O8: borrado completo de una organización de prueba';
end $$;

select 'FASE 6: TODAS LAS VERIFICACIONES PASARON' as resultado_fase6;

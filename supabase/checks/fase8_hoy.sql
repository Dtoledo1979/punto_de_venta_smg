-- =====================================================================
-- Verificación de la Fase A: resumen "Hoy" de la oficina.
-- Corre después de fase7b (con ROLLBACK).
-- =====================================================================
reset role;

-- H1. El owner ve el resumen de su negocio y las cifras cuadran con los
--     pedidos y devoluciones del día (sin anulados ni pruebas).
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_o jsonb; v_org uuid := (select org_a from t_ids); v_start timestamptz; v_exp numeric; v_n int; v_loc_sum numeric;
begin
  v_o := pos.today_overview(v_org);
  v_start := (v_o->>'day_start')::timestamptz;
  select coalesce(sum(total), 0), count(*) into v_exp, v_n from pos.orders
    where org_id = v_org and not is_test and status <> 'voided' and paid_at >= v_start;
  v_exp := v_exp - coalesce((select sum(amount) from pos.refunds where org_id = v_org and not is_test and created_at >= v_start), 0);
  if (v_o->>'sales')::numeric <> v_exp or (v_o->>'orders')::int <> v_n then
    raise exception 'FALLA H1: ventas % (esperado %), pedidos % (esperado %)', v_o->>'sales', v_exp, v_o->>'orders', v_n;
  end if;
  select coalesce(sum((x->>'sales')::numeric), 0) into v_loc_sum from jsonb_array_elements(v_o->'by_location') x;
  if v_loc_sum <> v_exp then raise exception 'FALLA H1: la suma por local (%) no cuadra con el total (%)', v_loc_sum, v_exp; end if;
  if jsonb_typeof(v_o->'top_products') <> 'array' or jsonb_typeof(v_o->'setup') <> 'object' then
    raise exception 'FALLA H1: formato inesperado %', v_o;
  end if;
  if not (v_o->'setup'->>'registers')::boolean then raise exception 'FALLA H1: no detectó las cajas'; end if;

  -- H2. Filtro por local: uno que no es del negocio se rechaza.
  begin
    perform pos.today_overview(v_org, (select loc_b from t_b));
    raise exception 'FALLA H2: aceptó un local de otra organización';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'location.not_found' then raise exception 'FALLA H2: error inesperado %', sqlerrm; end if;
  end;

  -- H3. Otra organización: prohibido.
  begin
    perform pos.today_overview((select org_b from t_ids));
    raise exception 'FALLA H3: vio el resumen de otra organización';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK H1-H3: resumen del día';
end $$;

-- H4. Staff no ve las cifras del negocio.
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
do $$
begin
  begin
    perform pos.today_overview((select org_a from t_ids));
    raise exception 'FALLA H4: staff vio las ventas del negocio';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK H4: staff sin acceso al resumen';
end $$;
reset role;

-- H5. anon no puede ejecutarla.
do $$
begin
  if has_function_privilege('anon', 'pos.today_overview(uuid, uuid)', 'execute') then
    raise exception 'FALLA H5: anon puede ejecutar today_overview';
  end if;
end $$;

-- H6. Reactivar respeta el límite del plan; no se desactiva una caja abierta.
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
do $$
declare v_org uuid; v_loc uuid; v_r1 uuid; v_r3 uuid;
begin
  v_org := (pos.create_organization('Limits Cafe', 'limits-cafe', '2468', p_legal_name => 'Limits Ltd', p_address_line => '1 St',
            p_city => 'Nelson', p_contact_name => 'Lu', p_contact_phone => '021 000 0000')).id;
  v_loc := (pos.create_location(v_org, 'Main')).id;
  v_r1 := (pos.create_register(v_loc, 'R1', 'product', '1357', '2468')).id;
  perform pos.create_register(v_loc, 'R2', 'product', '1357', '2468');
  perform pos.update_register(v_r1, p_active => false);
  v_r3 := (pos.create_register(v_loc, 'R3', 'product', '1357', '2468')).id;
  begin
    perform pos.update_register(v_r1, p_active => true);
    raise exception 'FALLA H6: reactivó una caja por sobre el límite del plan';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'subscription.limit_reached' then raise exception 'FALLA H6: error inesperado %', sqlerrm; end if;
  end;
  begin
    perform pos.update_location(v_loc, p_active => false);
    perform pos.create_location(v_org, 'Second');
    perform pos.update_location(v_loc, p_active => true);
    raise exception 'FALLA H6: reactivó un local por sobre el límite del plan';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'subscription.limit_reached' then raise exception 'FALLA H6: error inesperado (local) %', sqlerrm; end if;
  end;
  perform pos.set_subscription(v_org, 'starter', 'active');
  perform pos.open_register_session(v_r3, '1357', 0);
  begin
    perform pos.update_register(v_r3, p_active => false);
    raise exception 'FALLA H6: desactivó una caja con la sesión abierta';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'register.session_open' then raise exception 'FALLA H6: error inesperado (sesión) %', sqlerrm; end if;
  end;
  raise notice 'OK H6: límites al reactivar';
end $$;

select 'FASE 8 (HOY): TODAS LAS VERIFICACIONES PASARON' as resultado_fase8;

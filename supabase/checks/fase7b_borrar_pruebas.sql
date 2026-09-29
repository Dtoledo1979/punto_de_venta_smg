-- =====================================================================
-- Verificación: borrar datos de prueba (solo prueba, solo propia org,
-- solo owner/admin). Corre después de fase7 (con ROLLBACK).
-- =====================================================================
reset role;
delete from pos.pin_attempts;
do $$
declare v_real int; v_real_pay int; v_test int; v_b_test int; v_r jsonb;
begin
  select count(*) into v_real from pos.orders where org_id = (select org_a from t_ids) and not is_test;
  select count(*) into v_real_pay from pos.payments where org_id = (select org_a from t_ids) and not is_test;
  select count(*) into v_test from pos.orders where org_id = (select org_a from t_ids) and is_test;
  select count(*) into v_b_test from pos.orders where org_id = (select org_b from t_ids) and is_test;
  if v_test = 0 then raise exception 'FALLA T1: la prueba necesita pedidos de prueba en A'; end if;

  -- Staff no puede borrar.
  perform set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
  begin
    perform pos.purge_test_data((select org_a from t_ids));
    raise exception 'FALLA T1: staff borró datos de prueba';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  -- B no puede borrar los de A.
  perform set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
  begin
    perform pos.purge_test_data((select org_a from t_ids));
    raise exception 'FALLA T1: B borró datos de A';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;

  perform set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
  v_r := pos.purge_test_data((select org_a from t_ids));
  if (v_r->>'orders')::int <> v_test then raise exception 'FALLA T1: borró % de % pedidos de prueba', v_r->>'orders', v_test; end if;
  if (select count(*) from pos.orders where org_id = (select org_a from t_ids) and is_test) <> 0 then raise exception 'FALLA T1: quedaron pedidos de prueba'; end if;
  if (select count(*) from pos.orders where org_id = (select org_a from t_ids) and not is_test) <> v_real
     or (select count(*) from pos.payments where org_id = (select org_a from t_ids) and not is_test) <> v_real_pay then
    raise exception 'FALLA T1: se borraron datos reales';
  end if;
  if (select count(*) from pos.orders where org_id = (select org_b from t_ids) and is_test) <> v_b_test then raise exception 'FALLA T1: tocó datos de B'; end if;
  if not exists (select 1 from pos.audit_log where action = 'test_data.purge' and org_id = (select org_a from t_ids)) then raise exception 'FALLA T1: sin auditoría'; end if;
  -- Fuera de la función, los pagos siguen siendo imborrables.
  begin
    delete from pos.payments where org_id = (select org_a from t_ids) and not is_test;
    raise exception 'FALLA T1: se pudo borrar un pago real';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK T1: borrado de datos de prueba';
end $$;

select 'FASE 7b: TODAS LAS VERIFICACIONES PASARON' as resultado_fase7b;

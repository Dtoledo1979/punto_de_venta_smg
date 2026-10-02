-- =====================================================================
-- Verificación del reporte de Ventas (sales_report). Corre después de
-- fase8 (con ROLLBACK).
-- =====================================================================
reset role;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_org uuid := (select org_a from t_ids); v_r jsonb; v_tz text; v_today date;
  v_gross numeric; v_n int; v_ref numeric; v_comp int; v_sum numeric;
begin
  select timezone into v_tz from pos.organizations where id = v_org;
  v_today := (now() at time zone v_tz)::date;
  v_r := pos.sales_report(v_org, v_today - 6, v_today);

  -- V1. Totales = consulta directa (sin anulados, pruebas ni cortesías).
  select coalesce(sum(total), 0), count(*) into v_gross, v_n from pos.orders
    where org_id = v_org and not is_test and status <> 'voided' and payment_method <> 'complimentary'
      and paid_at >= (v_today - 6)::timestamp at time zone v_tz;
  select coalesce(sum(amount), 0) into v_ref from pos.refunds
    where org_id = v_org and not is_test and created_at >= (v_today - 6)::timestamp at time zone v_tz;
  select count(*) into v_comp from pos.orders
    where org_id = v_org and not is_test and status <> 'voided' and payment_method = 'complimentary'
      and paid_at >= (v_today - 6)::timestamp at time zone v_tz;
  if (v_r->>'gross')::numeric <> v_gross or (v_r->>'orders')::int <> v_n or (v_r->>'refunds')::numeric <> v_ref
     or (v_r->>'net')::numeric <> v_gross - v_ref or (v_r->'complimentary'->>'orders')::int <> v_comp then
    raise exception 'FALLA V1: % (esperado bruto % pedidos % devol % cortesías %)', v_r, v_gross, v_n, v_ref, v_comp;
  end if;
  if v_n = 0 then raise exception 'FALLA V1: la verificación necesita ventas en el período'; end if;

  -- V2. Las partes suman el total.
  select sum((x->>'net')::numeric) into v_sum from jsonb_array_elements(v_r->'by_day') x;
  if v_sum <> (v_r->>'net')::numeric then raise exception 'FALLA V2: suma por día % <> neto %', v_sum, v_r->>'net'; end if;
  if jsonb_array_length(v_r->'by_day') <> 7 or jsonb_array_length(v_r->'by_hour') <> 24 then raise exception 'FALLA V2: días/horas incompletos'; end if;
  select sum((x->>'net')::numeric) into v_sum from jsonb_array_elements(v_r->'by_location') x;
  if v_sum <> (v_r->>'net')::numeric then raise exception 'FALLA V2: suma por local % <> neto %', v_sum, v_r->>'net'; end if;
  select sum((x->>'gross')::numeric) into v_sum from jsonb_array_elements(v_r->'by_hour') x;
  if v_sum <> (v_r->>'gross')::numeric then raise exception 'FALLA V2: suma por hora % <> bruto %', v_sum, v_r->>'gross'; end if;
  if (v_r->'by_payment'->>'cash')::numeric + (v_r->'by_payment'->>'card')::numeric <> (v_r->>'gross')::numeric then
    raise exception 'FALLA V2: efectivo + tarjeta <> bruto (%)', v_r->'by_payment';
  end if;

  -- V3. Rangos inválidos y datos de otro negocio.
  begin
    perform pos.sales_report(v_org, v_today, v_today - 1);
    raise exception 'FALLA V3: aceptó un rango invertido';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'report.invalid_range' then raise exception 'FALLA V3: error inesperado %', sqlerrm; end if;
  end;
  begin
    perform pos.sales_report((select org_b from t_ids), v_today, v_today);
    raise exception 'FALLA V3: vio las ventas de otra organización';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  begin
    perform pos.sales_report(v_org, v_today, v_today, null, (select ev_b from t_b));
    raise exception 'FALLA V3: aceptó un evento de otra organización';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'event.not_found' then raise exception 'FALLA V3: error inesperado (evento) %', sqlerrm; end if;
  end;
  raise notice 'OK V1-V3: reporte de ventas';
end $$;

-- V4. Staff no ve el reporte.
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
do $$
begin
  begin
    perform pos.sales_report((select org_a from t_ids), current_date, current_date);
    raise exception 'FALLA V4: staff vio el reporte de ventas';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
end $$;
reset role;

select 'FASE 9 (VENTAS): TODAS LAS VERIFICACIONES PASARON' as resultado_fase9;

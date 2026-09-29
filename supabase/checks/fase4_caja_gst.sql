-- =====================================================================
-- Verificación de Fase 4: sesiones de caja con arqueo y GST.
-- Corre después de fase3 (misma transacción, con ROLLBACK).
-- =====================================================================
reset role;
delete from pos.pin_attempts;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;

-- S1. Vender de verdad exige sesión abierta; el modo prueba no.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_ev uuid := (select v from t2 where k = 'ev');
        v_cafe uuid := (select v from t2 where k = 'cafe'); v_o pos.orders;
begin
  -- Cierra la sesión que abrió la preparación (con pedidos pendientes → forzar).
  perform pos.close_register_session(v_reg, '1234', 0, 'fin preparación', 'Tester', true);
  begin
    perform pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_cafe, 'qty', 1)), 'cash', 4.50, 0, 'x', null, null);
    raise exception 'FALLA S1: vendió sin sesión abierta';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'session.not_open' then raise exception 'FALLA S1: error inesperado %', sqlerrm; end if;
  end;
  v_o := pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_cafe, 'qty', 1)), 'cash', 4.50, 0, 'test', null, null, null, true);
  if v_o.id is null or v_o.session_id is not null then raise exception 'FALLA S1: la venta de prueba debería funcionar sin sesión'; end if;
  raise notice 'OK S1: sesión obligatoria para vender (salvo modo prueba)';
end $$;

-- S2. Una sola sesión abierta por caja.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_s pos.register_sessions;
begin
  v_s := pos.open_register_session(v_reg, '1234', 50, 'Cajero');
  insert into t2 values ('session', v_s.id);
  begin
    perform pos.open_register_session(v_reg, '1234', 10, 'Otro');
    raise exception 'FALLA S2: abrió dos sesiones a la vez';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  if pos.open_register_session(v_reg, '0000', 10) is not null then raise exception 'FALLA S2: PIN incorrecto'; end if;
  raise notice 'OK S2: una sesión abierta por caja';
end $$;
reset role;
delete from pos.pin_attempts;
set local role authenticated;

-- S3. Efectivo esperado, calculado a mano:
--   fondo 50 + efectivo 13.50 + parte efectivo del mixto 10 − reembolso efectivo 4.50
--   + entrada 20 − salida 5 = 84.00 ; tarjeta = 3.50 + 4.50 = 8.00
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_ev uuid := (select v from t2 where k = 'ev');
        v_cafe uuid := (select v from t2 where k = 'cafe'); v_cash pos.orders; v_live jsonb; v_try text;
begin
  v_cash := pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_cafe, 'qty', 3)), 'cash', 13.50, 0, 'S3 cash', null, null);
  perform pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_cafe, 'qty', 3)), 'split', 10.00, 3.50, 'S3 split', null, null);
  perform pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_cafe, 'qty', 1)), 'card', 0, 4.50, 'S3 card', null, null);
  perform pos.refund_order(v_reg, '1234', v_cash.id, '[{"index":0,"qty":1}]', 'cash', 'quality', '4321');
  perform pos.record_cash_movement(v_reg, '1234', 'cash_in', 20, 'Float top-up', 'Cajero');
  perform pos.record_cash_movement(v_reg, '1234', 'cash_out', 5, 'Bought ice', 'Cajero');
  perform pos.record_payment_attempt(v_reg, '1234', 9.99, 'declined');
  insert into t2 values ('s3_cash_order', v_cash.id);

  v_live := pos.get_open_session(v_reg)->'live';
  if (v_live->>'expected_cash')::numeric <> 84.00 then raise exception 'FALLA S3: efectivo esperado % (84.00)', v_live->>'expected_cash'; end if;
  if (v_live->>'card_sales')::numeric <> 8.00 then raise exception 'FALLA S3: tarjeta % (8.00)', v_live->>'card_sales'; end if;
  if (v_live->>'gross_sales')::numeric <> 31.50 or (v_live->>'refunds_total')::numeric <> 4.50 or (v_live->>'net_sales')::numeric <> 27.00 then
    raise exception 'FALLA S3: bruto/reembolsos/neto %', v_live;
  end if;
  -- GST incluido al 15%: 13.50 → 1.76 (×2) y 4.50 → 0.59; reembolso 4.50 → 0.59.
  if (v_live->>'tax_sales')::numeric <> 4.11 or (v_live->>'tax_net')::numeric <> 3.52 then
    raise exception 'FALLA S3: GST % / %', v_live->>'tax_sales', v_live->>'tax_net';
  end if;
  if (v_live->>'declined_card_attempts')::int <> 1 then raise exception 'FALLA S3: intentos rechazados'; end if;
  if (select tax_amount from pos.orders where id = v_cash.id) <> 1.76 then raise exception 'FALLA S3: GST guardado en la venta'; end if;

  foreach v_try in array array[
    format('select pos.record_cash_movement(%L, ''1234'', ''cash_out'', 0, ''x'')', v_reg),
    format('select pos.record_cash_movement(%L, ''1234'', ''cash_out'', 5, '' '')', v_reg),
    format('select pos.record_cash_movement(%L, ''1234'', ''bonus'', 5, ''x'')', v_reg)
  ] loop
    begin
      execute v_try;
      raise exception 'FALLA S3: se aceptó -> %', v_try;
    exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    end;
  end loop;
  raise notice 'OK S3: efectivo esperado, tarjeta, neto y GST cuadran';
end $$;

-- S4. Cierre con arqueo: pide confirmar con pendientes, guarda diferencia,
--     queda inmutable, y las ventas de la sesión cerrada ya no se anulan.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_s pos.register_sessions; v_order uuid := (select v from t2 where k = 's3_cash_order');
begin
  begin
    perform pos.close_register_session(v_reg, '1234', 83.00, null, 'Cajero');
    raise exception 'FALLA S4: cerró con pedidos pendientes sin confirmar';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'session.pending_orders' then raise exception 'FALLA S4: error inesperado %', sqlerrm; end if;
  end;
  v_s := pos.close_register_session(v_reg, '1234', 83.00, 'Faltó $1', 'Cajero', true);
  if v_s.status <> 'closed' or v_s.expected_cash <> 84.00 or v_s.counted_cash <> 83.00 or v_s.cash_variance <> -1.00 then
    raise exception 'FALLA S4: cierre % / % / %', v_s.expected_cash, v_s.counted_cash, v_s.cash_variance;
  end if;
  if (v_s.totals->>'net_sales')::numeric <> 27.00 then raise exception 'FALLA S4: foto del reporte Z'; end if;
  begin
    perform pos.void_order(v_reg, '1234', (select id from pos.orders where session_id = v_s.id and refunded_total = 0 limit 1));
    raise exception 'FALLA S4: anuló una venta de una sesión cerrada';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'order.session_closed' then raise exception 'FALLA S4: error inesperado %', sqlerrm; end if;
  end;
  begin
    perform pos.refund_order(v_reg, '1234', v_order, '[{"index":0,"qty":1}]', 'cash', 'quality', '4321');
    raise exception 'FALLA S4: reembolso en efectivo sin sesión abierta';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  insert into t2 values ('closed_session', v_s.id);
  raise notice 'OK S4: cierre con arqueo y diferencia';
end $$;

reset role;
do $$
begin
  begin
    update pos.register_sessions set counted_cash = 84 where id = (select v from t2 where k = 'closed_session')::uuid;
    raise exception 'FALLA S4b: se editó una sesión cerrada';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  if not exists (select 1 from pos.audit_log where action = 'session.close' and entity_id = (select v from t2 where k = 'closed_session')::uuid)
     or not exists (select 1 from pos.audit_log where action = 'cash.cash_out') then
    raise exception 'FALLA S4b: faltan registros de auditoría de caja';
  end if;
  raise notice 'OK S4b: sesión cerrada inmutable y auditada';
end $$;

-- S5. Cambiar la tasa de GST no altera ventas pasadas.
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_ev uuid := (select v from t2 where k = 'ev');
        v_cafe uuid := (select v from t2 where k = 'cafe'); v_o pos.orders;
begin
  perform pos.update_organization_tax((select org_a from t_ids), 0.10, '123-456-789');
  perform pos.open_register_session(v_reg, '1234', 0, 'Cajero');
  v_o := pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_cafe, 'qty', 1)), 'cash', 4.50, 0, 'S5', null, null);
  if v_o.tax_rate <> 0.10 or v_o.tax_amount <> 0.41 then raise exception 'FALLA S5: venta nueva con GST % / %', v_o.tax_rate, v_o.tax_amount; end if;
  if (select tax_amount from pos.orders where id = (select v from t2 where k = 's3_cash_order')::uuid) <> 1.76 then
    raise exception 'FALLA S5: el cambio de tasa alteró una venta pasada';
  end if;
  begin
    perform pos.update_organization_tax((select org_a from t_ids), 1.5);
    raise exception 'FALLA S5: aceptó una tasa inválida';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK S5: GST por venta, inmutable ante cambios de tasa';
end $$;

-- S6. Staff no cambia el GST; B no ve sesiones de A.
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
do $$
begin
  begin
    perform pos.update_organization_tax((select org_a from t_ids), 0);
    raise exception 'FALLA S6: staff cambió el GST';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
end $$;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
do $$
begin
  if exists (select 1 from pos.register_sessions where org_id <> (select org_b from t_ids))
     or exists (select 1 from pos.cash_movements where org_id <> (select org_b from t_ids)) then
    raise exception 'FALLA S6: B ve sesiones o movimientos de caja de A';
  end if;
  begin
    perform pos.get_open_session((select v from t2 where k = 'reg')::uuid);
    raise exception 'FALLA S6: B consultó la sesión de una caja de A';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK S6: permisos de GST y aislamiento de sesiones';
end $$;
reset role;

select 'FASE 4: TODAS LAS VERIFICACIONES PASARON' as resultado_fase4;

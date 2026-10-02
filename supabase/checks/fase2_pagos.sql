-- =====================================================================
-- Verificación de Fase 2: libro de pagos, pago rechazado, reembolsos,
-- inmutabilidad de datos financieros y auditoría.
-- Corre después de fase1_aislamiento.sql, en la misma transacción (con
-- ROLLBACK): reutiliza la org A, su caja (PIN 1234 / Entrega 5678) y su
-- PIN de supervisor (4321). La fase 1 deja la org A suspendida al final:
-- acá se reactiva.
-- =====================================================================
reset role;
update pos.organizations set status = 'active' where slug = 'org-a';
delete from pos.pin_attempts;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;

create temp table if not exists t2 (k text primary key, v text) on commit drop;

do $$
declare v_reg uuid; v_ev uuid; v_cafe uuid; v_pisco uuid; v_ing uuid; v_o pos.orders; v_n int; v_sum numeric;
begin
  select id into v_reg from pos.registers where org_id = (select org_a from t_ids);
  select id into v_ev from pos.events where org_id = (select org_a from t_ids);
  select id into v_cafe from pos.products where org_id = (select org_a from t_ids) and name = 'Café';
  select id into v_pisco from pos.products where org_id = (select org_a from t_ids) and name = 'Piscola';
  -- Insumo con receta para probar la devolución proporcional de insumos.
  v_ing := (pos.inventory_save_item((select org_a from t_ids), null, 'Pisco', 'ml', 700, 'bottle')).id;
  perform pos.inventory_receive((select location_id from pos.registers where id = v_reg), 'item', v_ing, 1000, 'set');
  perform pos.catalog_set_recipe((select org_a from t_ids), v_pisco, jsonb_build_array(jsonb_build_object('stock_item_id', v_ing, 'qty', 60)));
  insert into t2 values ('reg', v_reg), ('ev', v_ev), ('cafe', v_cafe), ('pisco', v_pisco), ('ing', v_ing);

  -- F1. Libro de pagos: mixto = 2 filas aprobadas que suman el total.
  v_o := pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_cafe, 'qty', 3)),
                          'split', 10.00, 3.50, 'Split', null, null);
  select count(*), sum(amount) into v_n, v_sum from pos.payments where order_id = v_o.id and kind = 'payment' and status = 'approved';
  if v_n <> 2 or v_sum <> 13.50 then raise exception 'FALLA F1: pagos del mixto % filas / %', v_n, v_sum; end if;
  insert into t2 values ('split_order', v_o.id);
  v_o := pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_cafe, 'qty', 3)),
                          'cash', 13.50, 0, 'Cash', null, null);
  insert into t2 values ('cash_order', v_o.id);
  if (select count(*) from pos.payments where order_id = v_o.id) <> 1 then raise exception 'FALLA F1: pago en efectivo'; end if;
  raise notice 'OK F1: libro de pagos por venta';
end $$;

-- F2. Tarjeta rechazada: queda el intento, pero sin pedido, stock ni venta.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_orders int; v_stock numeric; v_id uuid;
begin
  select count(*) into v_orders from pos.orders where register_id = v_reg;
  select stock_qty into v_stock from pos.product_locations where product_id = (select v from t2 where k = 'pisco')::uuid;
  v_id := pos.record_payment_attempt(v_reg, '1234', 25.00, 'declined', 'Tester');
  if v_id is null then raise exception 'FALLA F2: no se registró el rechazo'; end if;
  if (select order_id from pos.payments where id = v_id) is not null then raise exception 'FALLA F2: el rechazo quedó ligado a un pedido'; end if;
  if (select count(*) from pos.orders where register_id = v_reg) <> v_orders then raise exception 'FALLA F2: el rechazo creó un pedido'; end if;
  if (select stock_qty from pos.product_locations where product_id = (select v from t2 where k = 'pisco')::uuid) <> v_stock then raise exception 'FALLA F2: el rechazo tocó stock'; end if;
  if pos.record_payment_attempt(v_reg, '0000', 25.00, 'declined') is not null then raise exception 'FALLA F2: aceptó un PIN incorrecto'; end if;
  begin
    perform pos.record_payment_attempt(v_reg, '1234', 25.00, 'approved');
    raise exception 'FALLA F2: se pudo registrar un "aprobado" sin venta';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK F2: pago rechazado sin venta';
end $$;
reset role;
delete from pos.pin_attempts;
set local role authenticated;

-- F3. Reembolso parcial por línea, con el resto en la última unidad.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_order uuid := (select v from t2 where k = 'cash_order'); v_r pos.refunds;
begin
  v_r := pos.refund_order(v_reg, '1234', v_order, '[{"index":0,"qty":1}]', 'cash', 'quality', '4321');
  if v_r.amount <> 4.50 then raise exception 'FALLA F3: primer reembolso %', v_r.amount; end if;
  v_r := pos.refund_order(v_reg, '1234', v_order, '[{"index":0,"qty":2}]', 'cash', 'quality', '4321');
  if v_r.amount <> 9.00 then raise exception 'FALLA F3: segundo reembolso %', v_r.amount; end if;
  if (select refunded_total from pos.orders where id = v_order) <> 13.50 then raise exception 'FALLA F3: refunded_total'; end if;
  if (select count(*) from pos.payments where order_id = v_order and kind = 'refund') <> 2 then raise exception 'FALLA F3: pagos de devolución'; end if;
  begin
    perform pos.refund_order(v_reg, '1234', v_order, '[{"index":0,"qty":1}]', 'cash', 'quality', '4321');
    raise exception 'FALLA F3: se reembolsó más de lo vendido';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'refund.qty_exceeds' then raise exception 'FALLA F3: error inesperado %', sqlerrm; end if;
  end;
  raise notice 'OK F3: reembolso parcial y total, sin pasarse';
end $$;

-- F4. No se devuelve por un medio más de lo cobrado por ese medio.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_order uuid := (select v from t2 where k = 'split_order'); v_r pos.refunds;
begin
  begin
    perform pos.refund_order(v_reg, '1234', v_order, '[{"index":0,"qty":3}]', 'card', 'other', '4321');
    raise exception 'FALLA F4: devolvió $13.50 por tarjeta con $3.50 cobrados en tarjeta';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'refund.exceeds_method' then raise exception 'FALLA F4: error inesperado %', sqlerrm; end if;
  end;
  -- PIN de supervisor incorrecto: null, sin reembolso.
  if (pos.refund_order(v_reg, '1234', v_order, '[{"index":0,"qty":1}]', 'cash', 'other', '9999')).id is not null then
    raise exception 'FALLA F4: reembolso con PIN de supervisor incorrecto';
  end if;
  if (select refunded_total from pos.orders where id = v_order) <> 0 then raise exception 'FALLA F4: quedó monto reembolsado'; end if;
  raise notice 'OK F4: límite por medio de pago y PIN de supervisor';
end $$;
reset role;
delete from pos.pin_attempts;
set local role authenticated;

-- F5. Idempotencia del reembolso y anulación bloqueada tras reembolsar.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_order uuid := (select v from t2 where k = 'split_order');
        v_tx uuid := gen_random_uuid(); v_r1 pos.refunds; v_r2 pos.refunds;
begin
  v_r1 := pos.refund_order(v_reg, '1234', v_order, '[{"index":0,"qty":1}]', 'cash', 'wrong_item', '4321', false, null, 'Tester', v_tx);
  v_r2 := pos.refund_order(v_reg, '1234', v_order, '[{"index":0,"qty":1}]', 'cash', 'wrong_item', '4321', false, null, 'Tester', v_tx);
  if v_r1.id <> v_r2.id then raise exception 'FALLA F5: el reintento creó un segundo reembolso'; end if;
  if (select refunded_total from pos.orders where id = v_order) <> 4.50 then raise exception 'FALLA F5: refunded_total tras reintento'; end if;
  begin
    perform pos.void_order(v_reg, '1234', v_order);
    raise exception 'FALLA F5: se anuló un pedido con reembolsos';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'order.has_refunds' then raise exception 'FALLA F5: error inesperado %', sqlerrm; end if;
  end;
  raise notice 'OK F5: reembolso idempotente; no se anula lo reembolsado';
end $$;

-- F6. Reembolso con devolución de stock (producto + insumo proporcional).
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_ev uuid := (select v from t2 where k = 'ev');
        v_pisco uuid := (select v from t2 where k = 'pisco'); v_ing uuid := (select v from t2 where k = 'ing');
        v_o pos.orders; v_s0 numeric; v_i0 numeric;
begin
  select stock_qty into v_s0 from pos.product_locations where product_id = v_pisco;
  select qty into v_i0 from pos.stock_levels where stock_item_id = v_ing;
  v_o := pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_pisco, 'qty', 2)), 'card', 0, 20.00, 'Restock', null, null);
  if (select qty from pos.stock_levels where stock_item_id = v_ing) <> v_i0 - 120 then raise exception 'FALLA F6: venta no descontó el insumo'; end if;
  perform pos.refund_order(v_reg, '1234', v_o.id, '[{"index":0,"qty":1}]', 'card', 'changed_mind', '4321', true);
  if (select stock_qty from pos.product_locations where product_id = v_pisco) <> v_s0 - 1 then raise exception 'FALLA F6: stock del producto tras devolver'; end if;
  if (select qty from pos.stock_levels where stock_item_id = v_ing) <> v_i0 - 60 then raise exception 'FALLA F6: insumo tras devolver: %', (select qty from pos.stock_levels where stock_item_id = v_ing); end if;
  if (select count(*) from pos.inventory_movements where type = 'refund_return' and (product_id = v_pisco or stock_item_id = v_ing)) <> 2 then
    raise exception 'FALLA F6: movimientos refund_return';
  end if;
  raise notice 'OK F6: devolución de stock proporcional';
end $$;

-- F7. Anular marca los pagos como anulados; reabrir los reactiva.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_ev uuid := (select v from t2 where k = 'ev'); v_o pos.orders;
begin
  v_o := pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', (select v from t2 where k = 'cafe')::uuid, 'qty', 1)), 'cash', 4.50, 0, 'V', null, null);
  perform pos.void_order(v_reg, '1234', v_o.id);
  if (select status from pos.payments where order_id = v_o.id) <> 'voided' then raise exception 'FALLA F7: pago no anulado'; end if;
  perform pos.reopen_order(v_reg, '1234', v_o.id);
  if (select status from pos.payments where order_id = v_o.id) <> 'approved' then raise exception 'FALLA F7: pago no reactivado'; end if;
  perform pos.void_order(v_reg, '1234', v_o.id); -- queda anulado para F8 (anulado → entregado es inválido)
  insert into t2 values ('void_order', v_o.id);
  raise notice 'OK F7: pagos siguen a anular/reabrir';
end $$;

-- F8. Inmutabilidad (incluso para postgres, que se salta RLS y grants).
reset role;
do $$
declare v_order uuid := (select v from t2 where k = 'cash_order')::uuid; v_try text;
begin
  foreach v_try in array array[
    format('update pos.orders set total = 1 where id = %L', v_order),
    format('update pos.orders set cash_amount = 0 where id = %L', v_order),
    format($q$update pos.orders set items = jsonb_set(items, '{0,price}', '0.01') where id = %L$q$, v_order),
    format('update pos.orders set refunded_total = 0 where id = %L', v_order),
    format($q$update pos.orders set status = 'delivered' where id = %L$q$, (select v from t2 where k = 'void_order')),
    format('update pos.payments set amount = 1 where order_id = %L', v_order),
    format('delete from pos.payments where order_id = %L', v_order),
    format('update pos.refunds set amount = 1 where order_id = %L', v_order),
    'update pos.audit_log set action = ''x''',
    'delete from pos.audit_log'
  ] loop
    begin
      execute v_try;
      raise exception 'FALLA F8: se permitió -> %', v_try;
    exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    end;
  end loop;
  -- Marcar "entregado" sí se puede (es lo único mutable de una línea).
  update pos.orders set items = jsonb_set(items, '{0,delivered}', 'true') where id = v_order;
  raise notice 'OK F8: datos financieros y auditoría inmutables';
end $$;

-- F9. Auditoría: registra las acciones sensibles y solo la ven quienes administran.
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_action text; v_missing text[] := '{}';
begin
  foreach v_action in array array['order.void','order.reopen','order.complimentary','order.refund','payment.declined',
                                  'menu.add','recipe.change','stock.opening_stock','register.create'] loop
    if not exists (select 1 from pos.audit_log where org_id = (select org_a from t_ids) and action = v_action) then
      v_missing := v_missing || v_action;
    end if;
  end loop;
  if array_length(v_missing, 1) > 0 then raise exception 'FALLA F9: faltan en auditoría: %', v_missing; end if;
  if not exists (select 1 from pos.audit_log where action = 'payment.declined' and operator_name = 'Tester') then
    raise exception 'FALLA F9: la auditoría no guardó el nombre del operador';
  end if;
  begin
    insert into pos.audit_log (org_id, action, entity_type) values ((select org_a from t_ids), 'fake', 'x');
    raise exception 'FALLA F9: authenticated pudo escribir en la auditoría';
  exception when insufficient_privilege then null;
  end;
  raise notice 'OK F9: auditoría completa';
end $$;

select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
do $$
begin
  if (select count(*) from pos.audit_log) <> 0 then raise exception 'FALLA F9: staff puede leer la auditoría'; end if;
  if (select count(*) from pos.payments) = 0 then raise exception 'FALLA F9: staff no ve los pagos de su org'; end if;
  raise notice 'OK F9b: auditoría solo para owner/admin/manager';
end $$;

select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
do $$
begin
  if exists (select 1 from pos.payments where org_id <> (select org_b from t_ids))
     or exists (select 1 from pos.refunds where org_id <> (select org_b from t_ids))
     or exists (select 1 from pos.audit_log where org_id <> (select org_b from t_ids)) then
    raise exception 'FALLA F10: B ve pagos, reembolsos o auditoría de A';
  end if;
  raise notice 'OK F10: pagos/reembolsos/auditoría aislados entre orgs';
end $$;
reset role;

select 'FASE 2: TODAS LAS VERIFICACIONES PASARON' as resultado_fase2;

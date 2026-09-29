-- =====================================================================
-- Verificación de Fase 3: precisión de insumos, mermas, toma de
-- inventario y validación de reposición. Corre después de fase2 (misma
-- transacción, con ROLLBACK) y reutiliza su caja, evento e insumo.
-- =====================================================================
reset role;
delete from pos.pin_attempts;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;

-- I1. Precisión: 0.125 ml por unidad × 8 ventas = exactamente 1 ml.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_ev uuid := (select v from t2 where k = 'ev');
        v_item uuid; v_ing uuid; v_i int;
begin
  v_item := (pos.add_menu_item(v_reg, '1234', 'Bitters shot', 2.00, 9)).id;
  v_ing := (pos.upsert_ingredient(v_reg, '1234', null, 'Bitters', 'ml', null, null)).id;
  perform pos.restock_ingredient(v_reg, '1234', v_ing, 'reset', 100);
  perform pos.set_recipe(v_reg, '1234', v_item, jsonb_build_array(jsonb_build_object('ingredient_id', v_ing, 'qty_per_unit', 0.125)));
  for v_i in 1..8 loop
    perform pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_item, 'qty', 1)), 'cash', 2.00, 0, 'P', null, null);
  end loop;
  if (select stock_qty from pos.ingredients where id = v_ing) <> 99.000 then
    raise exception 'FALLA I1: 8 × 0.125 ml dejó % (esperado 99.000)', (select stock_qty from pos.ingredients where id = v_ing);
  end if;
  if (select sum(qty_change) from pos.stock_movements where ingredient_id = v_ing and type = 'sale') <> -1.000 then
    raise exception 'FALLA I1: el historial no suma exactamente -1 ml';
  end if;
  insert into t2 values ('bitters_ing', v_ing), ('bitters_item', v_item);
  raise notice 'OK I1: precisión de 3 decimales sin deriva';
end $$;

-- I2. Merma: baja stock con motivo, no crea pedido ni pago, queda auditada.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_pisco uuid := (select v from t2 where k = 'pisco');
        v_ing uuid := (select v from t2 where k = 'ing'); v_s0 numeric; v_i0 numeric; v_orders int; v_pays int; v_try text;
begin
  select stock_qty into v_s0 from pos.menu_items where id = v_pisco;
  select stock_qty into v_i0 from pos.ingredients where id = v_ing;
  select count(*) into v_orders from pos.orders where register_id = v_reg;
  select count(*) into v_pays from pos.payments where register_id = v_reg;
  if pos.record_waste(v_reg, '1234', v_pisco, null, 1, 'breakage', 'Se cayó', 'Tester') <> v_s0 - 1 then raise exception 'FALLA I2: merma de producto'; end if;
  if pos.record_waste(v_reg, '1234', null, v_ing, 35.5, 'spillage') <> v_i0 - 35.5 then raise exception 'FALLA I2: merma de insumo'; end if;
  if (select count(*) from pos.orders where register_id = v_reg) <> v_orders or (select count(*) from pos.payments where register_id = v_reg) <> v_pays then
    raise exception 'FALLA I2: la merma creó pedido o pago';
  end if;
  if (select count(*) from pos.audit_log where action = 'stock.waste' and details->>'reason' in ('breakage','spillage')) < 2 then
    raise exception 'FALLA I2: merma sin auditoría';
  end if;
  if pos.record_waste(v_reg, '0000', v_pisco, null, 1, 'breakage') is not null then raise exception 'FALLA I2: merma con PIN incorrecto'; end if;
  foreach v_try in array array[
    format('select pos.record_waste(%L, ''1234'', %L, null, 0, ''breakage'')', v_reg, v_pisco),
    format('select pos.record_waste(%L, ''1234'', %L, null, -2, ''breakage'')', v_reg, v_pisco),
    format('select pos.record_waste(%L, ''1234'', %L, null, 1, ''robbery'')', v_reg, v_pisco),
    format('select pos.record_waste(%L, ''1234'', %L, %L, 1, ''other'')', v_reg, v_pisco, v_ing),
    format('select pos.restock_item(%L, ''1234'', %L, ''add'', -5)', v_reg, v_pisco),
    format('select pos.restock_item(%L, ''1234'', %L, ''reset'', -1)', v_reg, v_pisco),
    format('select pos.restock_ingredient(%L, ''1234'', %L, ''add'', 0)', v_reg, v_ing)
  ] loop
    begin
      execute v_try;
      raise exception 'FALLA I2: se aceptó -> %', v_try;
    exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    end;
  end loop;
  raise notice 'OK I2: mermas con motivo, sin venta; reposición validada en el servidor';
end $$;
reset role;
delete from pos.pin_attempts;
set local role authenticated;

-- I3. Toma de inventario: registra esperado/contado/diferencia y deja lo contado.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_pisco uuid := (select v from t2 where k = 'pisco');
        v_ing uuid := (select v from t2 where k = 'ing'); v_bit uuid := (select v from t2 where k = 'bitters_ing');
        v_s0 numeric; v_i0 numeric; v_st pos.stocktakes; v_st2 pos.stocktakes; v_tx uuid := gen_random_uuid();
begin
  select stock_qty into v_s0 from pos.menu_items where id = v_pisco;
  select stock_qty into v_i0 from pos.ingredients where id = v_ing;
  v_st := pos.record_stocktake(v_reg, '1234', jsonb_build_array(
    jsonb_build_object('menu_item_id', v_pisco, 'counted', v_s0 - 2),
    jsonb_build_object('ingredient_id', v_ing, 'counted', v_i0 + 12.25),
    jsonb_build_object('ingredient_id', v_bit, 'counted', 99)
  ), 'Cierre', 'Tester', v_tx);
  if v_st.items_counted <> 3 or v_st.items_with_variance <> 2 then raise exception 'FALLA I3: resumen % / %', v_st.items_counted, v_st.items_with_variance; end if;
  if (select stock_qty from pos.menu_items where id = v_pisco) <> v_s0 - 2 then raise exception 'FALLA I3: stock del producto no quedó en lo contado'; end if;
  if (select stock_qty from pos.ingredients where id = v_ing) <> v_i0 + 12.25 then raise exception 'FALLA I3: stock del insumo no quedó en lo contado'; end if;
  if not exists (select 1 from pos.stock_movements where stocktake_id = v_st.id and menu_item_id = v_pisco
                 and expected_qty = v_s0 and qty_after = v_s0 - 2 and qty_change = -2) then
    raise exception 'FALLA I3: el movimiento no guarda esperado/contado/diferencia';
  end if;
  if (select count(*) from pos.stock_movements where stocktake_id = v_st.id) <> 3 then raise exception 'FALLA I3: faltan movimientos (también los sin diferencia)'; end if;
  v_st2 := pos.record_stocktake(v_reg, '1234', '[{"ingredient_id":"00000000-0000-0000-0000-000000000000","counted":1}]', null, null, v_tx);
  if v_st2.id <> v_st.id then raise exception 'FALLA I3: la toma no es idempotente'; end if;
  if not exists (select 1 from pos.audit_log where action = 'stock.stocktake' and entity_id = v_st.id) then raise exception 'FALLA I3: toma sin auditoría'; end if;
  begin
    perform pos.record_stocktake(v_reg, '1234', jsonb_build_array(jsonb_build_object('menu_item_id', v_pisco, 'counted', 1), jsonb_build_object('menu_item_id', v_pisco, 'counted', 2)));
    raise exception 'FALLA I3: aceptó el mismo ítem dos veces';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  begin
    perform pos.record_stocktake(v_reg, '1234', jsonb_build_array(jsonb_build_object('menu_item_id', v_pisco, 'counted', -1)));
    raise exception 'FALLA I3: aceptó un conteo negativo';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK I3: toma de inventario con diferencias trazables';
end $$;

-- I4. Inmutabilidad de la toma y aislamiento.
reset role;
do $$
begin
  begin
    update pos.stocktakes set note = 'x';
    raise exception 'FALLA I4: se editó una toma de inventario';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK I4: toma inmutable';
end $$;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  if exists (select 1 from pos.stocktakes where org_id <> (select org_b from t_ids)) then raise exception 'FALLA I4: B ve tomas de A'; end if;
  raise notice 'OK I4b: tomas aisladas entre orgs';
end $$;
reset role;

select 'FASE 3: TODAS LAS VERIFICACIONES PASARON' as resultado_fase3;

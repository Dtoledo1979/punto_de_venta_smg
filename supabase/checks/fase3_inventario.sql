-- =====================================================================
-- Verificación de Fase 3: precisión de insumos, mermas, conteo de
-- inventario y validación de reposición (stock por local). Corre después
-- de fase2 (misma transacción, con ROLLBACK) y reutiliza su caja, evento
-- e insumo.
-- =====================================================================
reset role;
delete from pos.pin_attempts;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;

insert into t2 values ('org', (select org_a from t_ids)),
  ('loc', (select location_id from pos.registers where id = (select v from t2 where k = 'reg')::uuid));

-- I1. Precisión: 0.125 ml por unidad × 8 ventas = exactamente 1 ml.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_ev uuid := (select v from t2 where k = 'ev');
        v_org uuid := (select v from t2 where k = 'org'); v_loc uuid := (select v from t2 where k = 'loc');
        v_item uuid; v_ing uuid; v_i int;
begin
  v_item := (pos.catalog_save_product(v_org, null, 'Bitters shot', 2.00)).id;
  v_ing := (pos.inventory_save_item(v_org, null, 'Bitters', 'ml')).id;
  perform pos.inventory_receive(v_loc, 'item', v_ing, 100, 'set');
  perform pos.catalog_set_recipe(v_org, v_item, jsonb_build_array(jsonb_build_object('stock_item_id', v_ing, 'qty', 0.125)));
  for v_i in 1..8 loop
    perform pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_item, 'qty', 1)), 'cash', 2.00, 0, 'P', null, null);
  end loop;
  if (select qty from pos.stock_levels where stock_item_id = v_ing) <> 99.000 then
    raise exception 'FALLA I1: 8 × 0.125 ml dejó % (esperado 99.000)', (select qty from pos.stock_levels where stock_item_id = v_ing);
  end if;
  if (select sum(qty_change) from pos.inventory_movements where stock_item_id = v_ing and type = 'sale') <> -1.000 then
    raise exception 'FALLA I1: el historial no suma exactamente -1 ml';
  end if;
  insert into t2 values ('bitters_ing', v_ing), ('bitters_item', v_item);
  raise notice 'OK I1: precisión de 3 decimales sin deriva';
end $$;

-- I2. Merma: baja stock con motivo, no crea pedido ni pago, queda auditada.
do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_pisco uuid := (select v from t2 where k = 'pisco');
        v_loc uuid := (select v from t2 where k = 'loc');
        v_ing uuid := (select v from t2 where k = 'ing'); v_s0 numeric; v_i0 numeric; v_orders int; v_pays int; v_try text;
begin
  select stock_qty into v_s0 from pos.product_locations where product_id = v_pisco and location_id = v_loc;
  select qty into v_i0 from pos.stock_levels where stock_item_id = v_ing and location_id = v_loc;
  select count(*) into v_orders from pos.orders where register_id = v_reg;
  select count(*) into v_pays from pos.payments where register_id = v_reg;
  if pos.register_waste(v_reg, '1234', 'product', v_pisco, 1, 'breakage', 'Se cayó', 'Tester') <> v_s0 - 1 then raise exception 'FALLA I2: merma de producto'; end if;
  if pos.inventory_waste(v_loc, 'item', v_ing, 35.5, 'spillage') <> v_i0 - 35.5 then raise exception 'FALLA I2: merma de insumo'; end if;
  if (select count(*) from pos.orders where register_id = v_reg) <> v_orders or (select count(*) from pos.payments where register_id = v_reg) <> v_pays then
    raise exception 'FALLA I2: la merma creó pedido o pago';
  end if;
  if (select count(*) from pos.audit_log where action = 'stock.waste' and details->>'reason' in ('breakage','spillage')) < 2 then
    raise exception 'FALLA I2: merma sin auditoría';
  end if;
  if pos.register_waste(v_reg, '0000', 'product', v_pisco, 1, 'breakage') is not null then raise exception 'FALLA I2: merma con PIN incorrecto'; end if;
  foreach v_try in array array[
    format('select pos.inventory_waste(%L, ''product'', %L, 0, ''breakage'')', v_loc, v_pisco),
    format('select pos.inventory_waste(%L, ''product'', %L, -2, ''breakage'')', v_loc, v_pisco),
    format('select pos.inventory_waste(%L, ''product'', %L, 1, ''robbery'')', v_loc, v_pisco),
    format('select pos.inventory_waste(%L, ''nothing'', %L, 1, ''other'')', v_loc, v_pisco),
    format('select pos.inventory_receive(%L, ''product'', %L, -5, ''add'')', v_loc, v_pisco),
    format('select pos.inventory_receive(%L, ''product'', %L, -1, ''set'')', v_loc, v_pisco),
    format('select pos.inventory_receive(%L, ''item'', %L, 0, ''add'')', v_loc, v_ing),
    -- producto sin control de stock
    format('select pos.inventory_receive(%L, ''product'', %L, 5, ''add'')', v_loc, (select v from t2 where k = 'cafe'))
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

-- I3. Conteo: registra esperado/contado/diferencia y deja lo contado.
do $$
declare v_pisco uuid := (select v from t2 where k = 'pisco'); v_loc uuid := (select v from t2 where k = 'loc');
        v_ing uuid := (select v from t2 where k = 'ing'); v_bit uuid := (select v from t2 where k = 'bitters_ing');
        v_s0 numeric; v_i0 numeric; v_st pos.stock_counts; v_st2 pos.stock_counts; v_tx uuid := gen_random_uuid();
begin
  select stock_qty into v_s0 from pos.product_locations where product_id = v_pisco and location_id = v_loc;
  select qty into v_i0 from pos.stock_levels where stock_item_id = v_ing and location_id = v_loc;
  v_st := pos.inventory_count(v_loc, jsonb_build_array(
    jsonb_build_object('kind', 'product', 'id', v_pisco, 'counted', v_s0 - 2),
    jsonb_build_object('kind', 'item', 'id', v_ing, 'counted', v_i0 + 12.25),
    jsonb_build_object('kind', 'item', 'id', v_bit, 'counted', 99)
  ), 'Cierre', null, 'Tester', v_tx);
  if v_st.items_counted <> 3 or v_st.items_with_variance <> 2 then raise exception 'FALLA I3: resumen % / %', v_st.items_counted, v_st.items_with_variance; end if;
  if (select stock_qty from pos.product_locations where product_id = v_pisco and location_id = v_loc) <> v_s0 - 2 then raise exception 'FALLA I3: stock del producto no quedó en lo contado'; end if;
  if (select qty from pos.stock_levels where stock_item_id = v_ing and location_id = v_loc) <> v_i0 + 12.25 then raise exception 'FALLA I3: stock del insumo no quedó en lo contado'; end if;
  if not exists (select 1 from pos.inventory_movements where count_id = v_st.id and product_id = v_pisco
                 and expected_qty = v_s0 and qty_after = v_s0 - 2 and qty_change = -2) then
    raise exception 'FALLA I3: el movimiento no guarda esperado/contado/diferencia';
  end if;
  if (select count(*) from pos.inventory_movements where count_id = v_st.id) <> 3 then raise exception 'FALLA I3: faltan movimientos (también los sin diferencia)'; end if;
  v_st2 := pos.inventory_count(v_loc, '[{"kind":"item","id":"00000000-0000-0000-0000-000000000000","counted":1}]', null, null, null, v_tx);
  if v_st2.id <> v_st.id then raise exception 'FALLA I3: el conteo no es idempotente'; end if;
  if not exists (select 1 from pos.audit_log where action = 'stock.stocktake' and entity_id = v_st.id) then raise exception 'FALLA I3: conteo sin auditoría'; end if;
  begin
    perform pos.inventory_count(v_loc, jsonb_build_array(jsonb_build_object('kind', 'product', 'id', v_pisco, 'counted', 1), jsonb_build_object('kind', 'product', 'id', v_pisco, 'counted', 2)));
    raise exception 'FALLA I3: aceptó el mismo ítem dos veces';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  begin
    perform pos.inventory_count(v_loc, jsonb_build_array(jsonb_build_object('kind', 'product', 'id', v_pisco, 'counted', -1)));
    raise exception 'FALLA I3: aceptó un conteo negativo';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK I3: conteo de inventario con diferencias trazables';
end $$;

-- I4. Inmutabilidad del conteo y del libro; aislamiento.
reset role;
do $$
begin
  begin
    update pos.stock_counts set note = 'x';
    raise exception 'FALLA I4: se editó un conteo de inventario';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  begin
    update pos.inventory_movements set qty_change = 0;
    raise exception 'FALLA I4: se editó el libro de stock';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK I4: conteo y libro inmutables';
end $$;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  if exists (select 1 from pos.stock_counts where org_id <> (select org_b from t_ids)) then raise exception 'FALLA I4: B ve conteos de A'; end if;
  if exists (select 1 from pos.stock_items where org_id <> (select org_b from t_ids)) then raise exception 'FALLA I4: B ve insumos de A'; end if;
  raise notice 'OK I4b: inventario aislado entre orgs';
end $$;
reset role;

select 'FASE 3: TODAS LAS VERIFICACIONES PASARON' as resultado_fase3;

-- =====================================================================
-- Verificación de la Fase B: catálogo del negocio, opciones, recetas de
-- opciones, precio/disponibilidad por local, agotados, stock compartido
-- por local, promociones, numeración diaria, plantillas por rubro.
-- Corre después de fase9 (con ROLLBACK). Org A está en plan pro.
-- =====================================================================
reset role;
delete from pos.pin_attempts;
update pos.organizations set status = 'active' where slug = 'org-a';
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;

create temp table if not exists t10 (k text primary key, v uuid) on commit drop;
grant all on t10 to authenticated;

-- C1. Opciones: precio del servidor, obligatorias, máximos y pertenencia.
do $$
declare v_org uuid := (select org_a from t_ids); v_reg uuid := (select v from t2 where k = 'reg')::uuid;
        g_size uuid; g_milk uuid; g_extra uuid; v_latte uuid; v_large uuid; v_oat uuid; v_shot uuid; v_full uuid; v_reg_size uuid;
        v_o pos.orders; v_try text; v_cat uuid;
begin
  v_cat := (pos.catalog_save_category(v_org, null, 'Coffee', '#c8a27c')).id;
  g_size := (pos.catalog_save_modifier_group(v_org, null, 'Size', 1, 1,
    '[{"name":"Regular","is_default":true},{"name":"Large","price_delta":0.5}]')).id;
  g_milk := (pos.catalog_save_modifier_group(v_org, null, 'Milk', 1, 1,
    '[{"name":"Full cream","is_default":true},{"name":"Oat","price_delta":0.8}]')).id;
  g_extra := (pos.catalog_save_modifier_group(v_org, null, 'Extras', 0, 2,
    '[{"name":"Extra shot","price_delta":0.5},{"name":"Decaf"},{"name":"Syrup","price_delta":0.8}]')).id;
  v_latte := (pos.catalog_save_product(v_org, null, 'Cat latte', 5.50, v_cat, null, 'coffee', 'product', false, array[g_size, g_milk, g_extra])).id;
  select id into v_large from pos.modifiers where group_id = g_size and name = 'Large';
  select id into v_reg_size from pos.modifiers where group_id = g_size and name = 'Regular';
  select id into v_oat from pos.modifiers where group_id = g_milk and name = 'Oat';
  select id into v_full from pos.modifiers where group_id = g_milk and name = 'Full cream';
  select id into v_shot from pos.modifiers where group_id = g_extra and name = 'Extra shot';
  insert into t10 values ('latte', v_latte), ('oat', v_oat), ('full', v_full), ('large', v_large), ('regsize', v_reg_size), ('g_milk', g_milk), ('cat', v_cat);

  v_o := pos.create_order(v_reg, '1234', null, jsonb_build_array(
    jsonb_build_object('id', v_latte, 'qty', 2, 'modifiers', jsonb_build_array(v_large, v_oat, v_shot), 'note', 'extra hot')),
    'cash', 14.60, 0, 'Tom', null, null, p_order_type => 'takeaway');
  if v_o.total <> 14.60 then raise exception 'FALLA C1: total con opciones % (esperado 14.60)', v_o.total; end if;
  if (v_o.items->0->>'price')::numeric <> 7.30 or jsonb_array_length(v_o.items->0->'modifiers') <> 3
     or v_o.items->0->>'note' <> 'extra hot' or v_o.order_type <> 'takeaway' then
    raise exception 'FALLA C1: foto de la línea %', v_o.items->0;
  end if;

  foreach v_try in array array[
    -- falta la leche (obligatoria)
    format('select pos.create_order(%L, ''1234'', null, %L::jsonb, ''cash'', 5.50, 0, null, null, null)', v_reg,
           jsonb_build_array(jsonb_build_object('id', v_latte, 'qty', 1, 'modifiers', jsonb_build_array(v_reg_size)))),
    -- dos tamaños en un grupo de "elegir uno"
    format('select pos.create_order(%L, ''1234'', null, %L::jsonb, ''cash'', 6.00, 0, null, null, null)', v_reg,
           jsonb_build_array(jsonb_build_object('id', v_latte, 'qty', 1, 'modifiers', jsonb_build_array(v_reg_size, v_large, v_full)))),
    -- opción que no pertenece al producto (Piscola no tiene opciones)
    format('select pos.create_order(%L, ''1234'', null, %L::jsonb, ''cash'', 10, 0, null, null, null)', v_reg,
           jsonb_build_array(jsonb_build_object('id', (select v from t2 where k = 'pisco'), 'qty', 1, 'modifiers', jsonb_build_array(v_oat)))),
    -- tipo de pedido inválido
    format('select pos.create_order(%L, ''1234'', null, %L::jsonb, ''cash'', 5.50, 0, null, null, null, null, false, null, ''drive'')', v_reg,
           jsonb_build_array(jsonb_build_object('id', v_latte, 'qty', 1, 'modifiers', jsonb_build_array(v_reg_size, v_full))))
  ] loop
    begin
      execute v_try;
      raise exception 'FALLA C1: se aceptó -> %', v_try;
    exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    end;
  end loop;
  begin
    perform pos.create_order(v_reg, '1234', null, jsonb_build_array(jsonb_build_object('id', v_latte, 'qty', 1, 'modifiers', jsonb_build_array(v_reg_size))),
                             'cash', 5.50, 0, null, null, null);
  exception when raise_exception then
    if sqlerrm <> 'modifier.required' then raise exception 'FALLA C1: error inesperado %', sqlerrm; end if;
  end;
  raise notice 'OK C1: opciones con precio del servidor y validadas';
end $$;

-- C2. Receta de opción: "Avena" consume leche de avena en vez de entera;
--     devolver la línea repone exactamente eso.
do $$
declare v_org uuid := (select org_a from t_ids); v_reg uuid := (select v from t2 where k = 'reg')::uuid;
        v_loc uuid := (select v from t2 where k = 'loc')::uuid; v_milk uuid; v_oatmilk uuid; v_o pos.orders;
        v_latte uuid := (select v from t10 where k = 'latte'); v_m0 numeric; v_a0 numeric;
begin
  v_milk := (pos.inventory_save_item(v_org, null, 'Whole milk', 'ml', 2000, 'bottle')).id;
  v_oatmilk := (select id from pos.stock_items where org_id = v_org and name = 'Oat milk');  -- de fase8 (H7)
  perform pos.inventory_receive(v_loc, 'item', v_milk, 10000, 'set');
  perform pos.inventory_receive(v_loc, 'item', v_oatmilk, 5000, 'set');
  perform pos.catalog_set_recipe(v_org, v_latte, jsonb_build_array(jsonb_build_object('stock_item_id', v_milk, 'qty', 200)));
  perform pos.catalog_set_modifier_recipe(v_org, (select v from t10 where k = 'oat'),
    jsonb_build_array(jsonb_build_object('stock_item_id', v_oatmilk, 'qty', 200), jsonb_build_object('stock_item_id', v_milk, 'qty', -200)));
  select qty into v_m0 from pos.stock_levels where stock_item_id = v_milk and location_id = v_loc;
  select qty into v_a0 from pos.stock_levels where stock_item_id = v_oatmilk and location_id = v_loc;

  v_o := pos.create_order(v_reg, '1234', null, jsonb_build_array(
    jsonb_build_object('id', v_latte, 'qty', 1, 'modifiers', jsonb_build_array((select v from t10 where k = 'regsize'), (select v from t10 where k = 'full'))),
    jsonb_build_object('id', v_latte, 'qty', 2, 'modifiers', jsonb_build_array((select v from t10 where k = 'regsize'), (select v from t10 where k = 'oat')))),
    'card', 0, 18.10, 'Mix', null, null);
  if (select qty from pos.stock_levels where stock_item_id = v_milk and location_id = v_loc) <> v_m0 - 200 then
    raise exception 'FALLA C2: leche entera % (esperado %)', (select qty from pos.stock_levels where stock_item_id = v_milk and location_id = v_loc), v_m0 - 200;
  end if;
  if (select qty from pos.stock_levels where stock_item_id = v_oatmilk and location_id = v_loc) <> v_a0 - 400 then
    raise exception 'FALLA C2: leche de avena no descontada';
  end if;
  -- Devolver 1 de los 2 con avena (línea 1) y reponer.
  perform pos.refund_order(v_reg, '1234', v_o.id, '[{"index":1,"qty":1}]', 'card', 'quality', '4321', true);
  if (select qty from pos.stock_levels where stock_item_id = v_oatmilk and location_id = v_loc) <> v_a0 - 200
     or (select qty from pos.stock_levels where stock_item_id = v_milk and location_id = v_loc) <> v_m0 - 200 then
    raise exception 'FALLA C2: la devolución no repuso lo de esa línea';
  end if;
  raise notice 'OK C2: recetas de opciones y devolución por línea';
end $$;

-- C3. Por local: precio propio, no disponible y agotado.
do $$
declare v_org uuid := (select org_a from t_ids); v_loc2 uuid; v_reg2 uuid; v_cat jsonb; v_o pos.orders;
        v_pisco uuid := (select v from t2 where k = 'pisco')::uuid; v_cafe uuid := (select v from t2 where k = 'cafe')::uuid;
begin
  v_loc2 := (pos.create_location(v_org, 'Second spot')).id;
  v_reg2 := (pos.create_register(v_loc2, 'Window', 'product', '2468', '1357')).id;
  insert into t10 values ('loc2', v_loc2), ('reg2', v_reg2);
  perform pos.open_register_session(v_reg2, '2468', 0);
  perform pos.catalog_set_product_location(v_org, v_cafe, v_loc2, true, 6.00);
  perform pos.catalog_set_product_location(v_org, v_pisco, v_loc2, false);

  v_cat := pos.register_catalog(v_reg2);
  if (select (p->>'price')::numeric from jsonb_array_elements(v_cat->'products') p where (p->>'id')::uuid = v_cafe) <> 6.00 then
    raise exception 'FALLA C3: el catálogo del local no trae su precio';
  end if;
  if exists (select 1 from jsonb_array_elements(v_cat->'products') p where (p->>'id')::uuid = v_pisco) then
    raise exception 'FALLA C3: el catálogo del local muestra un producto no disponible';
  end if;
  v_o := pos.create_order(v_reg2, '2468', null, jsonb_build_array(jsonb_build_object('id', v_cafe, 'qty', 2)), 'cash', 12.00, 0, null, null, null);
  if v_o.total <> 12.00 then raise exception 'FALLA C3: precio del local % (esperado 12.00)', v_o.total; end if;
  begin
    perform pos.create_order(v_reg2, '2468', null, jsonb_build_array(jsonb_build_object('id', v_pisco, 'qty', 1)), 'cash', 10, 0, null, null, null);
    raise exception 'FALLA C3: vendió un producto no disponible en el local';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'product.not_found' then raise exception 'FALLA C3: error inesperado %', sqlerrm; end if;
  end;
  -- Agotado: se marca desde la caja (PIN) y bloquea la venta en ESE local.
  if not pos.set_sold_out(v_reg2, '2468', v_cafe, true) then raise exception 'FALLA C3: no marcó agotado'; end if;
  begin
    perform pos.create_order(v_reg2, '2468', null, jsonb_build_array(jsonb_build_object('id', v_cafe, 'qty', 1)), 'cash', 6.00, 0, null, null, null);
    raise exception 'FALLA C3: vendió un producto agotado';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
    if sqlerrm <> 'product.sold_out' then raise exception 'FALLA C3: error inesperado (agotado) %', sqlerrm; end if;
  end;
  -- En el otro local sigue a la venta, con el precio general.
  v_o := pos.create_order((select v from t2 where k = 'reg')::uuid, '1234', null, jsonb_build_array(jsonb_build_object('id', v_cafe, 'qty', 1)), 'cash', 4.50, 0, null, null, null);
  if v_o.id is null then raise exception 'FALLA C3: el agotado de un local afectó a otro'; end if;
  perform pos.set_sold_out(v_reg2, '2468', v_cafe, false);
  raise notice 'OK C3: precio, disponibilidad y agotado por local';
end $$;

-- C4. Dos cajas del mismo local comparten el stock.
do $$
declare v_org uuid := (select org_a from t_ids); v_loc uuid := (select v from t2 where k = 'loc')::uuid; v_reg3 uuid;
        v_pisco uuid := (select v from t2 where k = 'pisco')::uuid; v_s0 numeric;
begin
  v_reg3 := (pos.create_register(v_loc, 'Back bar', 'product', '1122', '3344')).id;
  perform pos.open_register_session(v_reg3, '1122', 0);
  select stock_qty into v_s0 from pos.product_locations where product_id = v_pisco and location_id = v_loc;
  perform pos.create_order(v_reg3, '1122', null, jsonb_build_array(jsonb_build_object('id', v_pisco, 'qty', 3)), 'cash', 30, 0, null, null, null);
  if (select stock_qty from pos.product_locations where product_id = v_pisco and location_id = v_loc) <> v_s0 - 3 then
    raise exception 'FALLA C4: la segunda caja del local no descontó del mismo stock';
  end if;
  insert into t10 values ('reg3', v_reg3);
  raise notice 'OK C4: stock compartido por local';
end $$;

-- C5. Promoción "3 por $12" repartida entre líneas del mismo producto.
do $$
declare v_org uuid := (select org_a from t_ids); v_reg uuid := (select v from t2 where k = 'reg')::uuid; v_p uuid; v_o pos.orders;
begin
  v_p := (pos.catalog_save_product(v_org, null, 'Donut', 5.00)).id;
  perform pos.catalog_save_promotion(v_org, null, v_p, 3, 12.00, '3 for 12');
  begin
    perform pos.catalog_save_promotion(v_org, null, v_p, 2, 10.00);
    raise exception 'FALLA C5: aceptó una promo que no descuenta';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  -- 2 donuts + 1 café + 2 donuts con nota: 4 donuts → 1 promo (−3) → 20 − 3 + 4.50 = 21.50
  v_o := pos.create_order(v_reg, '1234', null, jsonb_build_array(
    jsonb_build_object('id', v_p, 'qty', 2), jsonb_build_object('id', (select v from t2 where k = 'cafe'), 'qty', 1),
    jsonb_build_object('id', v_p, 'qty', 2, 'note', 'boxed')), 'cash', 21.50, 0, null, null, null);
  if v_o.total <> 21.50 then raise exception 'FALLA C5: total con promo % (esperado 21.50)', v_o.total; end if;
  if (select sum((e->>'discount')::numeric) from jsonb_array_elements(v_o.items) e) <> 3.00 then
    raise exception 'FALLA C5: descuento total distinto de 3 (%)', v_o.items;
  end if;
  raise notice 'OK C5: promociones';
end $$;

-- C6. Sin evento: numeración por caja y día (empieza en 1).
do $$
declare v_reg3 uuid := (select v from t10 where k = 'reg3'); v_o1 pos.orders; v_o2 pos.orders;
        v_pisco uuid := (select v from t2 where k = 'pisco')::uuid;
begin
  -- C4 ya vendió 1 pedido en esta caja.
  v_o1 := pos.create_order(v_reg3, '1122', null, jsonb_build_array(jsonb_build_object('id', v_pisco, 'qty', 1)), 'cash', 10, 0, null, null, null);
  v_o2 := pos.create_order(v_reg3, '1122', null, jsonb_build_array(jsonb_build_object('id', v_pisco, 'qty', 1)), 'cash', 10, 0, null, null, null);
  if v_o1.ticket_num <> 2 or v_o2.ticket_num <> 3 or v_o1.event_id is not null then
    raise exception 'FALLA C6: numeración diaria % / %', v_o1.ticket_num, v_o2.ticket_num;
  end if;
  raise notice 'OK C6: numeración diaria sin eventos';
end $$;
reset role;

-- C7. Plantilla por rubro: un café nuevo arranca con catálogo de ejemplo.
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_org uuid; v_loc uuid; v_reg uuid; v_cat jsonb; v_fw jsonb; n_prod int;
begin
  v_org := (pos.create_organization('Seed Cafe', 'seed-cafe', '2468', p_legal_name => 'Seed Ltd', p_address_line => '1 St',
            p_city => 'Auckland', p_contact_name => 'Sam', p_contact_phone => '021 000 0000')).id;
  perform pos.set_business_type(v_org, 'cafe', true);
  select count(*) into n_prod from pos.products where org_id = v_org;
  if n_prod < 10 or (select count(*) from pos.categories where org_id = v_org) < 3 then raise exception 'FALLA C7: plantilla vacía'; end if;
  perform pos.set_business_type(v_org, 'cafe', true);
  if (select count(*) from pos.products where org_id = v_org) <> n_prod then raise exception 'FALLA C7: la plantilla se duplicó'; end if;
  v_loc := (pos.create_location(v_org, 'Main')).id;
  v_reg := (pos.create_register(v_loc, 'Counter', 'product', '1357', '2468')).id;
  v_cat := pos.register_catalog(v_reg);
  select p into v_fw from jsonb_array_elements(v_cat->'products') p where p->>'name' = 'Flat white';
  if v_fw is null or jsonb_array_length(v_fw->'groups') <> 3 or jsonb_array_length(v_cat->'modifier_groups') < 3 then
    raise exception 'FALLA C7: el flat white de ejemplo no trae sus opciones %', v_fw;
  end if;
  if (select business_type from pos.organizations where id = v_org) <> 'cafe' then raise exception 'FALLA C7: tipo de negocio'; end if;
  -- Funciones visibles: solo claves conocidas, booleanas.
  perform pos.set_features(v_org, '{"tables": true}');
  begin
    perform pos.set_features(v_org, '{"hack": true}');
    raise exception 'FALLA C7: aceptó una función desconocida';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  raise notice 'OK C7: plantilla por rubro';
end $$;
reset role;

-- C8. Staff: no edita el catálogo, sí marca agotado con PIN.
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_org uuid := (select org_a from t_ids);
begin
  begin
    perform pos.catalog_save_product(v_org, null, 'Staff special', 1);
    raise exception 'FALLA C8: staff creó un producto';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  begin
    perform pos.inventory_receive((select v from t2 where k = 'loc')::uuid, 'product', (select v from t2 where k = 'pisco')::uuid, 100, 'set');
    raise exception 'FALLA C8: staff cargó stock desde la oficina';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  if not pos.set_sold_out((select v from t2 where k = 'reg')::uuid, '1234', (select v from t2 where k = 'cafe')::uuid, false) then
    raise exception 'FALLA C8: staff con PIN no pudo cambiar agotado';
  end if;
  if pos.register_catalog((select v from t2 where k = 'reg')::uuid) is null then raise exception 'FALLA C8: staff no ve el catálogo de la caja'; end if;
  raise notice 'OK C8: permisos del catálogo';
end $$;
reset role;

select 'FASE 10 (CATÁLOGO): TODAS LAS VERIFICACIONES PASARON' as resultado_fase10;

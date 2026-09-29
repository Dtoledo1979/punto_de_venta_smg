-- =====================================================================
-- Verificación de Fase 5: estaciones de preparación (KDS).
-- Corre después de fase4 (misma transacción, con ROLLBACK). La fase 4
-- deja una sesión abierta en la caja de A.
-- =====================================================================
reset role;
delete from pos.pin_attempts;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;

do $$
declare v_reg uuid := (select v from t2 where k = 'reg'); v_ev uuid := (select v from t2 where k = 'ev');
        v_beer uuid; v_burger uuid; v_coffee uuid; v_water uuid; v_o pos.orders; v_items jsonb;
begin
  v_beer   := (pos.add_menu_item(v_reg, '1234', 'Beer', 9.00, 20)).id;
  v_burger := (pos.add_menu_item(v_reg, '1234', 'Burger', 18.00, 21)).id;
  v_coffee := (pos.add_menu_item(v_reg, '1234', 'Flat white', 5.50, 22)).id;
  v_water  := (pos.add_menu_item(v_reg, '1234', 'Water bottle', 3.00, 23)).id;
  perform pos.set_item_station(v_reg, '1234', v_burger, 'kitchen');
  perform pos.set_item_station(v_reg, '1234', v_coffee, 'coffee');
  perform pos.set_item_station(v_reg, '1234', v_water, 'none');

  -- K1. Cada línea lleva su estación; "none" queda entregada al cobrar.
  v_o := pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(
    jsonb_build_object('id', v_beer, 'qty', 1), jsonb_build_object('id', v_burger, 'qty', 1),
    jsonb_build_object('id', v_coffee, 'qty', 1), jsonb_build_object('id', v_water, 'qty', 1)),
    'card', 0, 35.50, 'KDS', null, null);
  select jsonb_object_agg(e->>'name', jsonb_build_object('station', e->>'station', 'delivered', (e->>'delivered')::boolean))
    into v_items from jsonb_array_elements(v_o.items) e;
  if v_items->'Beer'->>'station' <> 'bar' or v_items->'Burger'->>'station' <> 'kitchen'
     or v_items->'Flat white'->>'station' <> 'coffee' or v_items->'Water bottle'->>'station' <> 'none' then
    raise exception 'FALLA K1: estaciones en la venta %', v_items;
  end if;
  if (v_items->'Water bottle'->>'delivered')::boolean is not true or (v_items->'Beer'->>'delivered')::boolean then
    raise exception 'FALLA K1: estado inicial de las líneas %', v_items;
  end if;

  -- K2. La cocina marca lo suyo; el bar y el café siguen pendientes.
  perform pos.despacho_mark_station(v_reg, '5678', v_o.id, 'kitchen', 'Chef');
  select jsonb_object_agg(e->>'name', (e->>'delivered')::boolean) into v_items
    from pos.orders o, jsonb_array_elements(o.items) e where o.id = v_o.id;
  if not (v_items->>'Burger')::boolean or (v_items->>'Beer')::boolean or (v_items->>'Flat white')::boolean then
    raise exception 'FALLA K2: marcar cocina afectó otras estaciones %', v_items;
  end if;
  if (select status from pos.orders where id = v_o.id) <> 'pending_delivery' then raise exception 'FALLA K2: el pedido se cerró solo'; end if;

  -- K3. Cambiar la estación de un producto no mueve pedidos ya hechos.
  perform pos.set_item_station(v_reg, '1234', v_beer, 'kitchen');
  if (select e->>'station' from pos.orders o, jsonb_array_elements(o.items) e where o.id = v_o.id and e->>'name' = 'Beer') <> 'bar' then
    raise exception 'FALLA K3: el cambio de estación alteró un pedido pasado';
  end if;

  -- K4. Validaciones y PIN.
  begin
    perform pos.set_item_station(v_reg, '1234', v_beer, 'garage');
    raise exception 'FALLA K4: aceptó una estación inválida';
  exception when raise_exception then if sqlerrm like 'FALLA%' then raise; end if;
  end;
  if pos.despacho_mark_station(v_reg, '0000', v_o.id, 'bar') then raise exception 'FALLA K4: marcó con PIN incorrecto'; end if;
  if not exists (select 1 from pos.audit_log where action = 'menu.update' and details->>'new_station' = 'kitchen') then
    raise exception 'FALLA K4: cambio de estación sin auditoría';
  end if;
  raise notice 'OK K1-K4: estaciones';
end $$;
reset role;

select 'FASE 5: TODAS LAS VERIFICACIONES PASARON' as resultado_fase5;

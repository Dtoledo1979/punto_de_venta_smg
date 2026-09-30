-- =====================================================================
-- Verificación de Fase 1: aislamiento multi-tenant, RLS, grants y PINs.
--
-- Se ejecuta DESPUÉS de las migraciones, dentro de una transacción que
-- termina en ROLLBACK (ver scripts/verificar-db.sh): no deja ningún dato.
-- Cualquier falla lanza una excepción "FALLA: ..." y corta la ejecución.
--
-- Escenario: dos organizaciones (A y B), un usuario owner en cada una,
-- una caja de productos en cada una, un pedido en cada una.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Preparación (como postgres, sin RLS)
-- ---------------------------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'owner-a@test.local', 'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'owner-b@test.local', 'authenticated', 'authenticated'),
  ('cccccccc-0000-0000-0000-00000000000c', 'staff-a@test.local', 'authenticated', 'authenticated');

-- Crear cada organización COMO su usuario, a través de la API real.
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
select pos.create_organization('Org A', 'org-a', '4321');
reset role;

select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
select pos.create_organization('Org B', 'org-b', '8765');
reset role;

-- Ubicación, caja, evento, producto y un pedido por organización.
create temp table t_ids on commit drop as
select
  (select id from pos.organizations where slug = 'org-a') as org_a,
  (select id from pos.organizations where slug = 'org-b') as org_b;
grant select on t_ids to authenticated, anon;

-- Las organizaciones nacen con pago pendiente (fase 6): se activan como lo
-- haría el webhook de billing, para poder abrir caja y vender.
do $$
begin
  if exists (select 1 from pg_proc where proname = 'set_subscription') then
    perform pos.set_subscription(id, 'pro', 'active') from pos.organizations where slug in ('org-a', 'org-b');
  end if;
end $$;

do $$
declare v_org uuid; v_slug text; v_loc uuid; v_reg uuid; v_ev uuid; v_item uuid; v_user text; v_order pos.orders;
begin
  foreach v_slug in array array['org-a','org-b'] loop
    select id into v_org from pos.organizations where slug = v_slug;
    v_user := case v_slug when 'org-a' then 'aaaaaaaa-0000-0000-0000-00000000000a' else 'bbbbbbbb-0000-0000-0000-00000000000b' end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

    v_loc  := (pos.create_location(v_org, 'Local ' || v_slug)).id;
    v_reg  := (pos.create_register(v_loc, 'Barra ' || v_slug, 'product', '1234', '5678')).id;
    v_ev   := (pos.create_event(v_reg, '1234', 'Evento ' || v_slug, current_date)).id;
    v_item := (pos.add_menu_item(v_reg, '1234', 'Piscola', 10, 1)).id;
    perform pos.restock_item(v_reg, '1234', v_item, 'reset', 20);
    -- Vender de verdad exige una sesión de caja abierta (fase 4).
    if exists (select 1 from pg_proc where proname = 'open_register_session') then
      perform pos.open_register_session(v_reg, '1234', 100, 'Tester');
    end if;

    v_order := pos.create_order(v_reg, '1234', v_ev,
      jsonb_build_array(jsonb_build_object('id', v_item, 'qty', 2)),
      'cash', 20, 0, 'Cliente ' || v_slug, null, 'Operador', null, false, gen_random_uuid());
    if v_order.id is null then raise exception 'FALLA: no se pudo crear el pedido de prueba de %', v_slug; end if;
    if v_order.total <> 20 then raise exception 'FALLA: total calculado % (esperado 20)', v_order.total; end if;
  end loop;
end $$;

-- Staff de la org A (para probar el control por rol).
insert into pos.memberships (org_id, user_id, role)
  select org_a, 'cccccccc-0000-0000-0000-00000000000c', 'staff' from t_ids;

-- ---------------------------------------------------------------------
-- 1. Aislamiento de LECTURA: A solo ve lo de A, en todas las tablas.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_org_a uuid := (select org_a from t_ids); v_tbl text; v_foreign int; v_own int;
begin
  foreach v_tbl in array array['locations','registers','events','menu_items','orders',
                               'ticket_counters','stock_movements','memberships'] loop
    execute format('select count(*) filter (where org_id <> $1), count(*) filter (where org_id = $1) from pos.%I', v_tbl)
      into v_foreign, v_own using v_org_a;
    if v_foreign <> 0 then raise exception 'FALLA: A ve % filas de otra org en pos.%', v_foreign, v_tbl; end if;
    if v_own = 0 then raise exception 'FALLA: A no ve sus propias filas en pos.% (la prueba no es válida)', v_tbl; end if;
  end loop;

  if (select count(*) from pos.organizations) <> 1 then
    raise exception 'FALLA: A ve más de una organización';
  end if;
  raise notice 'OK 1: lectura aislada en todas las tablas';
end $$;

-- ---------------------------------------------------------------------
-- 2. Columnas y tablas secretas: ni los hash de PIN ni los secretos.
-- ---------------------------------------------------------------------
do $$
begin
  begin
    perform pin_hash from pos.registers limit 1;
    raise exception 'FALLA: authenticated puede leer registers.pin_hash';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from pos.org_secrets limit 1;
    raise exception 'FALLA: authenticated puede leer org_secrets';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from pos.pin_attempts limit 1;
    raise exception 'FALLA: authenticated puede leer pin_attempts';
  exception when insufficient_privilege then null;
  end;
  raise notice 'OK 2: hash de PIN, secretos e intentos no son legibles';
end $$;

-- ---------------------------------------------------------------------
-- 3. Escritura directa bloqueada (aun sobre filas propias).
-- ---------------------------------------------------------------------
do $$
begin
  begin
    update pos.orders set total = 0;
    raise exception 'FALLA: authenticated puede hacer UPDATE directo en orders';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into pos.memberships (org_id, user_id, role)
      select org_b, 'aaaaaaaa-0000-0000-0000-00000000000a', 'owner' from t_ids;
    raise exception 'FALLA: authenticated puede insertarse como miembro de otra org';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from pos.menu_items;
    raise exception 'FALLA: authenticated puede hacer DELETE directo en menu_items';
  exception when insufficient_privilege then null;
  end;
  raise notice 'OK 3: escrituras directas bloqueadas';
end $$;

-- ---------------------------------------------------------------------
-- 4. RPCs de A contra la caja / org de B: todas rechazadas, incluso con
--    los PIN correctos de B. (A no puede ver los ids de B por RLS, así que
--    se obtienen como postgres.)
-- ---------------------------------------------------------------------
reset role;
create temp table t_b on commit drop as
select r.id as reg_b, r.org_id as org_b, e.id as ev_b, m.id as item_b, o.id as order_b, l.id as loc_b
from pos.registers r
join pos.events e on e.org_id = r.org_id
join pos.menu_items m on m.register_id = r.id
join pos.orders o on o.register_id = r.id
join pos.locations l on l.id = r.location_id
where r.org_id = (select org_b from t_ids);
grant select on t_b to authenticated;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare b t_b%rowtype; v_calls text[]; v_sql text; v_ok int := 0;
begin
  select * into b from t_b;
  if b.reg_b is null then raise exception 'FALLA: la prueba no encontró los datos de B'; end if;

  -- Con el PIN CORRECTO de B: igual tiene que fallar, por no ser miembro.
  v_calls := array[
    format('select pos.verify_register_pin(%L, ''1234'')', b.reg_b),
    format('select pos.verify_supervisor_pin(%L, ''8765'')', b.reg_b),
    format('select pos.void_order(%L, ''1234'', %L)', b.reg_b, b.order_b),
    format('select pos.reopen_order(%L, ''1234'', %L)', b.reg_b, b.order_b),
    format('select pos.add_menu_item(%L, ''1234'', ''Hack'', 1, 1)', b.reg_b),
    format('select pos.restock_item(%L, ''1234'', %L, ''reset'', 0)', b.reg_b, b.item_b),
    format('select pos.close_event(%L, ''1234'', %L)', b.reg_b, b.ev_b),
    format('select pos.despacho_confirm_all(%L, ''5678'', %L, ''x'')', b.reg_b, b.order_b),
    format('select pos.create_order(%L, ''1234'', %L, %L::jsonb, ''cash'', 10, 0, null, null, null)',
           b.reg_b, b.ev_b, jsonb_build_array(jsonb_build_object('id', b.item_b, 'qty', 1))),
    format('select pos.update_register(%L, ''Hack'')', b.reg_b),
    format('select pos.create_location(%L, ''Hack'')', b.org_b),
    format('select pos.create_register(%L, ''Hack'', ''product'', ''1111'', ''2222'')', b.loc_b),
    format('select pos.set_supervisor_pin(%L, ''0000'')', b.org_b),
    format('select pos.add_member(%L, ''owner-a@test.local'', ''owner'')', b.org_b)
  ];
  foreach v_sql in array v_calls loop
    begin
      execute v_sql;
      raise exception 'FALLA: A pudo ejecutar sobre B -> %', v_sql;
    exception
      when raise_exception then
        if sqlerrm like 'FALLA:%' then raise; end if;
        v_ok := v_ok + 1;  -- 'Caja no encontrada o sin acceso' / 'No autorizado'
    end;
  end loop;
  raise notice 'OK 4: % RPCs de A sobre B rechazadas', v_ok;
end $$;

-- ---------------------------------------------------------------------
-- 5. Control por rol: staff no puede administrar.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
do $$
declare v_org_a uuid := (select org_a from t_ids); v_reg_a uuid;
begin
  select id into v_reg_a from pos.registers where org_id = v_org_a;
  if v_reg_a is null then raise exception 'FALLA: staff de A no ve la caja de A'; end if;
  begin
    perform pos.update_register(v_reg_a, null, '0000');
    raise exception 'FALLA: staff puede cambiar el PIN de la caja';
  exception when raise_exception then if sqlerrm like 'FALLA:%' then raise; end if;
  end;
  begin
    perform pos.set_member_role(v_org_a, 'cccccccc-0000-0000-0000-00000000000c', 'owner');
    raise exception 'FALLA: staff puede ascenderse a owner';
  exception when raise_exception then if sqlerrm like 'FALLA:%' then raise; end if;
  end;
  -- Staff sí puede operar la caja con su PIN.
  if not pos.verify_register_pin(v_reg_a, '1234') then
    raise exception 'FALLA: staff con el PIN correcto no puede abrir la caja';
  end if;
  raise notice 'OK 5: permisos por rol';
end $$;

-- ---------------------------------------------------------------------
-- 6. Límite de intentos de PIN: persiste aunque la función NO sea
--    verify_*, y bloquea incluso el PIN correcto mientras dure.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
do $$
declare v_reg_a uuid := (select id from pos.registers where org_id = (select org_a from t_ids)); i int;
begin
  for i in 1..5 loop
    if pos.close_event(v_reg_a, '0000', gen_random_uuid()) then
      raise exception 'FALLA: close_event aceptó un PIN incorrecto';
    end if;
  end loop;
  if pos.verify_register_pin(v_reg_a, '1234') then
    raise exception 'FALLA: tras 5 fallos la caja no quedó bloqueada';
  end if;
  raise notice 'OK 6: bloqueo por intentos fallidos';
end $$;

-- ---------------------------------------------------------------------
-- 7. Anular desde Entrega no bloquea la caja (bug del diseño anterior).
-- ---------------------------------------------------------------------
reset role;
delete from pos.pin_attempts;
set local role authenticated;
do $$
declare v_reg_a uuid; v_order uuid; i int;
begin
  select id into v_reg_a from pos.registers where org_id = (select org_a from t_ids);
  select id into v_order from pos.orders where register_id = v_reg_a limit 1;
  for i in 1..6 loop
    if not pos.void_order(v_reg_a, '5678', v_order) then raise exception 'FALLA: void con PIN de Entrega rechazado'; end if;
    if not pos.reopen_order(v_reg_a, '5678', v_order) then raise exception 'FALLA: reopen con PIN de Entrega rechazado'; end if;
  end loop;
  if not pos.verify_register_pin(v_reg_a, '1234') then
    raise exception 'FALLA: anular/reabrir desde Entrega bloqueó el PIN de caja';
  end if;
  -- Y el stock quedó igual que al principio: 20 - 2 vendidos = 18.
  if (select stock_qty from pos.menu_items where register_id = v_reg_a) <> 18 then
    raise exception 'FALLA: stock descuadrado tras anular/reabrir (%), esperado 18',
      (select stock_qty from pos.menu_items where register_id = v_reg_a);
  end if;
  raise notice 'OK 7: PIN de Entrega en anular/reabrir no bloquea la caja, stock cuadra';
end $$;

-- ---------------------------------------------------------------------
-- 8. Cortesía: PIN de supervisor obligatorio.
-- ---------------------------------------------------------------------
do $$
declare v_reg_a uuid; v_ev uuid; v_item uuid; v_o pos.orders;
begin
  select id into v_reg_a from pos.registers where org_id = (select org_a from t_ids);
  select id into v_ev from pos.events where org_id = (select org_a from t_ids);
  select id into v_item from pos.menu_items where register_id = v_reg_a;
  v_o := pos.create_order(v_reg_a, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_item, 'qty', 1)),
                          'complimentary', 0, 0, null, null, null, '9999');
  if v_o.id is not null then raise exception 'FALLA: cortesía con PIN de supervisor incorrecto'; end if;
  v_o := pos.create_order(v_reg_a, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_item, 'qty', 1)),
                          'complimentary', 0, 0, null, null, null, '4321');
  if v_o.id is null then raise exception 'FALLA: cortesía con PIN de supervisor correcto rechazada'; end if;
  raise notice 'OK 8: cortesía exige PIN de supervisor';
end $$;

-- ---------------------------------------------------------------------
-- 8b. Idempotencia: el mismo intento de cobro (reintento tras corte de red,
--     doble envío) = UN pedido, UN descuento de stock, UN movimiento.
-- ---------------------------------------------------------------------
do $$
declare v_reg uuid; v_ev uuid; v_item uuid; v_tx uuid := gen_random_uuid();
        v_o1 pos.orders; v_o2 pos.orders; v_stock_before numeric; v_movs_before int; v_movs int;
begin
  select id into v_reg from pos.registers where org_id = (select org_a from t_ids);
  select id into v_ev from pos.events where org_id = (select org_a from t_ids);
  select id, stock_qty into v_item, v_stock_before from pos.menu_items where register_id = v_reg and name = 'Piscola';
  select count(*) into v_movs_before from pos.stock_movements where menu_item_id = v_item and type = 'sale';
  v_o1 := pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_item, 'qty', 1)),
                           'cash', 10, 0, 'Reintento', null, null, null, false, v_tx);
  v_o2 := pos.create_order(v_reg, '1234', v_ev, jsonb_build_array(jsonb_build_object('id', v_item, 'qty', 1)),
                           'cash', 10, 0, 'Reintento', null, null, null, false, v_tx);
  if v_o1.id is null or v_o1.id <> v_o2.id then raise exception 'FALLA: el reintento creó un segundo pedido'; end if;
  if (select count(*) from pos.orders where client_transaction_id = v_tx) <> 1 then raise exception 'FALLA: hay más de un pedido con el mismo intento'; end if;
  if (select stock_qty from pos.menu_items where id = v_item) <> v_stock_before - 1 then
    raise exception 'FALLA: el reintento descontó stock dos veces';
  end if;
  -- (no se filtra por created_at: dentro de una transacción now() es siempre el mismo)
  select count(*) - v_movs_before into v_movs from pos.stock_movements where menu_item_id = v_item and type = 'sale';
  if v_movs <> 1 then raise exception 'FALLA: % movimientos de venta para un solo cobro', v_movs; end if;
  raise notice 'OK 8b: idempotencia (un pedido, un descuento)';
end $$;

-- ---------------------------------------------------------------------
-- 9. anon: sin ningún acceso al schema pos.
-- ---------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
do $$
begin
  begin
    perform 1 from pos.orders limit 1;
    raise exception 'FALLA: anon puede leer pos.orders';
  exception when insufficient_privilege then null;
  end;
  begin
    perform pos.verify_register_pin(gen_random_uuid(), '1234');
    raise exception 'FALLA: anon puede ejecutar RPCs';
  exception when insufficient_privilege then null;
  end;
  raise notice 'OK 9: anon sin acceso';
end $$;
reset role;

-- ---------------------------------------------------------------------
-- 9b. Dinero exacto al centavo y montos coherentes con el método de pago.
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_reg uuid; v_ev uuid; v_item uuid; v_o pos.orders; v_items jsonb; v_sql text;
begin
  select id into v_reg from pos.registers where org_id = (select org_a from t_ids);
  select id into v_ev from pos.events where org_id = (select org_a from t_ids);
  v_item := (pos.add_menu_item(v_reg, '1234', 'Café', 4.50, 2)).id;
  v_items := jsonb_build_array(jsonb_build_object('id', v_item, 'qty', 3));

  v_o := pos.create_order(v_reg, '1234', v_ev, v_items, 'cash', 13.50, 0, null, null, null);
  if v_o.total <> 13.50 then raise exception 'FALLA: total con centavos % (esperado 13.50)', v_o.total; end if;
  v_o := pos.create_order(v_reg, '1234', v_ev, v_items, 'split', 10.00, 3.50, null, null, null);
  if v_o.id is null then raise exception 'FALLA: pago mixto exacto rechazado'; end if;

  foreach v_sql in array array[
    -- 1 centavo de diferencia (antes se aceptaba hasta $1)
    format('select pos.create_order(%L, ''1234'', %L, %L::jsonb, ''cash'', 13.49, 0, null, null, null)', v_reg, v_ev, v_items),
    format('select pos.create_order(%L, ''1234'', %L, %L::jsonb, ''cash'', 14.00, 0, null, null, null)', v_reg, v_ev, v_items),
    -- método incoherente con los montos
    format('select pos.create_order(%L, ''1234'', %L, %L::jsonb, ''cash'', 10.00, 3.50, null, null, null)', v_reg, v_ev, v_items),
    format('select pos.create_order(%L, ''1234'', %L, %L::jsonb, ''card'', 13.50, 0, null, null, null)', v_reg, v_ev, v_items),
    format('select pos.create_order(%L, ''1234'', %L, %L::jsonb, ''split'', 13.50, 0, null, null, null)', v_reg, v_ev, v_items),
    -- montos negativos
    format('select pos.create_order(%L, ''1234'', %L, %L::jsonb, ''split'', 15.00, -1.50, null, null, null)', v_reg, v_ev, v_items),
    -- cantidad fraccionaria
    format('select pos.create_order(%L, ''1234'', %L, %L::jsonb, ''cash'', 6.75, 0, null, null, null)', v_reg, v_ev,
           jsonb_build_array(jsonb_build_object('id', v_item, 'qty', 1.5)))
  ] loop
    begin
      execute v_sql;
      raise exception 'FALLA: se aceptó un cobro inválido -> %', v_sql;
    exception when raise_exception then
      if sqlerrm like 'FALLA:%' then raise; end if;
    end;
  end loop;
  -- Los errores llegan como código estable + detalle JSON (el texto lo pone el frontend).
  declare v_msg text; v_detail text;
  begin
    perform pos.create_order(v_reg, '1234', v_ev, v_items, 'cash', 13.49, 0, null, null, null);
  exception when raise_exception then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
    if v_msg <> 'payment.total_mismatch' or (v_detail::jsonb->>'total')::numeric <> 13.50 or (v_detail::jsonb->>'paid')::numeric <> 13.49 then
      raise exception 'FALLA: error mal formado: % / %', v_msg, v_detail;
    end if;
  end;
  raise notice 'OK 9b: dinero exacto al centavo y coherente con el método';
end $$;
reset role;

-- ---------------------------------------------------------------------
-- 10. Organización suspendida: sus usuarios pierden todo el acceso.
-- ---------------------------------------------------------------------
update pos.organizations set status = 'suspended' where slug = 'org-a';
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  if (select count(*) from pos.orders) <> 0 then raise exception 'FALLA: org suspendida sigue viendo pedidos'; end if;
  raise notice 'OK 10: org suspendida sin acceso';
end $$;
reset role;

select 'TODAS LAS VERIFICACIONES PASARON' as resultado;

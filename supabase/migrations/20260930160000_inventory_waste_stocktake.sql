-- =====================================================================
-- Fase 3 — Inventario: mermas, toma de inventario y precisión.
--
-- 1. Precisión: las recetas guardan 3 decimales (0.125 ml por unidad) pero
--    el stock de insumos y el historial guardaban 2 — cada venta
--    redondeaba y la diferencia se acumulaba. Ahora todo usa 3.
-- 2. Merma (waste): baja el stock con un motivo (derrame, rotura, vencido,
--    consumo del personal, error de preparación, otro). NUNCA crea venta.
-- 3. Toma de inventario (stocktake): se cuenta lo físico, el sistema
--    registra lo esperado, lo contado y la diferencia de cada ítem, y deja
--    el stock en lo contado. La diferencia queda a la vista para siempre
--    (no se "pisa" el stock en silencio).
-- 4. El servidor valida las cantidades de reposición (antes solo la
--    pantalla): reiniciar ≥ 0, agregar > 0.
-- =====================================================================

alter table pos.ingredients
  alter column stock_qty type numeric(14,3),
  alter column initial_stock type numeric(14,3),
  alter column container_size type numeric(14,3);
alter table pos.stock_movements
  alter column qty_change type numeric(14,3),
  alter column qty_after type numeric(14,3);

alter table pos.stock_movements
  add column reason text,
  add column expected_qty numeric(14,3),
  add column stocktake_id uuid;

alter table pos.stock_movements drop constraint stock_movements_type_check;
alter table pos.stock_movements add constraint stock_movements_type_check
  check (type in ('opening_stock','purchase','sale','adjustment','void_return','reopen_sale','refund_return','waste','stocktake'));
alter table pos.stock_movements add constraint stock_movements_waste_reason_chk
  check (type <> 'waste' or reason in ('spillage','breakage','expired','staff','prep_error','other'));

-- ---------------------------------------------------------------------
-- Tomas de inventario
-- lines = [{"kind":"menu_item|ingredient","id":..,"name":..,"unit":..,
--           "expected":..,"counted":..,"variance":..}, ...]
-- ---------------------------------------------------------------------
create table pos.stocktakes (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references pos.organizations(id) on delete cascade,
  register_id           uuid not null,
  lines                 jsonb not null,
  items_counted         int not null,
  items_with_variance   int not null,
  note                  text,
  client_transaction_id uuid unique,
  operator_name         text,
  created_by_user       uuid references auth.users(id) on delete set null,
  created_at            timestamptz not null default now(),
  foreign key (register_id, org_id) references pos.registers(id, org_id)
);
create index stocktakes_register_idx on pos.stocktakes (register_id, created_at desc);

alter table pos.stock_movements add constraint stock_movements_stocktake_fk
  foreign key (stocktake_id) references pos.stocktakes(id) deferrable initially deferred;

create function pos._stocktakes_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from pos.organizations where id = old.org_id) then return old; end if; -- cascade
  raise exception 'stocktake.immutable';
end;
$$;
create trigger stocktakes_guard before update or delete on pos.stocktakes
  for each row execute function pos._stocktakes_guard();

alter table pos.stocktakes enable row level security;
create policy tenant_select on pos.stocktakes for select to authenticated using (org_id in (select pos.user_org_ids()));
revoke all on pos.stocktakes from anon, authenticated, public;
grant select on pos.stocktakes to authenticated;
grant all on pos.stocktakes to service_role;

-- ---------------------------------------------------------------------
-- Auditoría: mermas y tomas de inventario
-- ---------------------------------------------------------------------
create or replace function pos._audit_stock() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if new.type in ('opening_stock','purchase','adjustment','waste') then
    perform pos._audit(new.org_id, new.register_id, 'stock.' || new.type,
      case when new.menu_item_id is not null then 'menu_item' else 'ingredient' end,
      coalesce(new.menu_item_id, new.ingredient_id),
      jsonb_build_object('qty_change', new.qty_change, 'qty_after', new.qty_after, 'reason', new.reason));
  end if;
  return null;
end;
$$;

create function pos._audit_stocktakes() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._audit(new.org_id, new.register_id, 'stock.stocktake', 'stocktake', new.id,
    jsonb_build_object('items_counted', new.items_counted, 'items_with_variance', new.items_with_variance));
  return null;
end;
$$;
create trigger stocktakes_audit after insert on pos.stocktakes
  for each row execute function pos._audit_stocktakes();

-- ---------------------------------------------------------------------
-- Merma: baja stock con motivo. Nunca crea pedido, pago ni venta.
-- Exactamente uno de p_menu_item_id / p_ingredient_id.
-- ---------------------------------------------------------------------
create function pos.record_waste(
  p_register_id uuid, p_pin text, p_menu_item_id uuid, p_ingredient_id uuid,
  p_qty numeric, p_reason text, p_note text default null, p_by text default null
) returns numeric
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_reg pos.registers; v_after numeric; v_item pos.menu_items; v_ing pos.ingredients;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);
  if (p_menu_item_id is null) = (p_ingredient_id is null) then raise exception 'stock.invalid_target'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'stock.invalid_qty'; end if;
  if p_reason is null or p_reason not in ('spillage','breakage','expired','staff','prep_error','other') then
    raise exception 'stock.invalid_reason';
  end if;

  if p_menu_item_id is not null then
    select * into v_item from pos.menu_items where id = p_menu_item_id and register_id = v_reg.id for update;
    if v_item.id is null then raise exception 'product.not_found'; end if;
    if not v_item.track_stock or v_item.stock_qty is null then raise exception 'stock.not_tracked'; end if;
    update pos.menu_items set stock_qty = stock_qty - p_qty where id = v_item.id returning stock_qty into v_after;
  else
    select * into v_ing from pos.ingredients where id = p_ingredient_id and register_id = v_reg.id for update;
    if v_ing.id is null then raise exception 'ingredient.not_found'; end if;
    if v_ing.stock_qty is null then raise exception 'stock.not_tracked'; end if;
    update pos.ingredients set stock_qty = stock_qty - p_qty where id = v_ing.id returning stock_qty into v_after;
  end if;

  insert into pos.stock_movements (org_id, register_id, menu_item_id, ingredient_id, type, qty_change, qty_after, reason, note, created_by, created_by_user)
    values (v_reg.org_id, v_reg.id, p_menu_item_id, p_ingredient_id, 'waste', -p_qty, v_after, p_reason, p_note, p_by, auth.uid());
  return v_after;
end;
$$;

-- ---------------------------------------------------------------------
-- Toma de inventario.
--   p_counts = [{"menu_item_id": ..., "counted": 18}, {"ingredient_id": ..., "counted": 950.5}, ...]
-- Por cada ítem: esperado = stock actual, diferencia = contado − esperado,
-- el stock queda en lo contado y el movimiento guarda las tres cifras.
-- Se registran también los ítems sin diferencia (prueba de que se contaron).
-- ---------------------------------------------------------------------
create function pos.record_stocktake(
  p_register_id uuid, p_pin text, p_counts jsonb, p_note text default null,
  p_by text default null, p_client_transaction_id uuid default null
) returns pos.stocktakes
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_reg pos.registers; v_st pos.stocktakes; v_id uuid := gen_random_uuid();
  v_c jsonb; v_counted numeric; v_expected numeric; v_var numeric;
  v_item pos.menu_items; v_ing pos.ingredients; v_lines jsonb := '[]'::jsonb; v_with_var int := 0;
  v_seen uuid[] := '{}'; v_target uuid;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);

  if p_client_transaction_id is not null then
    select * into v_st from pos.stocktakes where client_transaction_id = p_client_transaction_id and register_id = v_reg.id;
    if v_st.id is not null then return v_st; end if;
  end if;
  if p_counts is null or jsonb_typeof(p_counts) <> 'array' or jsonb_array_length(p_counts) = 0 then
    raise exception 'stocktake.empty';
  end if;

  for v_c in select * from jsonb_array_elements(p_counts) loop
    v_counted := (v_c->>'counted')::numeric;
    if v_counted is null or v_counted < 0 then raise exception 'stock.invalid_qty'; end if;
    v_target := coalesce((v_c->>'menu_item_id')::uuid, (v_c->>'ingredient_id')::uuid);
    if v_target is null or ((v_c ? 'menu_item_id') = (v_c ? 'ingredient_id')) then raise exception 'stock.invalid_target'; end if;
    if v_target = any (v_seen) then raise exception 'stocktake.duplicate_item'; end if;
    v_seen := v_seen || v_target;

    if v_c ? 'menu_item_id' then
      select * into v_item from pos.menu_items where id = v_target and register_id = v_reg.id for update;
      if v_item.id is null then raise exception 'product.not_found'; end if;
      if not v_item.track_stock then raise exception 'stock.not_tracked'; end if;
      v_expected := coalesce(v_item.stock_qty, 0);
      update pos.menu_items set stock_qty = v_counted where id = v_item.id;
      v_lines := v_lines || jsonb_build_object('kind', 'menu_item', 'id', v_item.id, 'name', v_item.name, 'unit', null,
                                               'expected', v_expected, 'counted', v_counted, 'variance', v_counted - v_expected);
    else
      select * into v_ing from pos.ingredients where id = v_target and register_id = v_reg.id for update;
      if v_ing.id is null then raise exception 'ingredient.not_found'; end if;
      v_expected := coalesce(v_ing.stock_qty, 0);
      update pos.ingredients set stock_qty = v_counted, initial_stock = coalesce(initial_stock, v_counted) where id = v_ing.id;
      v_lines := v_lines || jsonb_build_object('kind', 'ingredient', 'id', v_ing.id, 'name', v_ing.name, 'unit', v_ing.unit,
                                               'expected', v_expected, 'counted', v_counted, 'variance', v_counted - v_expected);
    end if;
    v_var := v_counted - v_expected;
    if v_var <> 0 then v_with_var := v_with_var + 1; end if;
    insert into pos.stock_movements (org_id, register_id, menu_item_id, ingredient_id, type, qty_change, qty_after,
                                     expected_qty, stocktake_id, note, created_by, created_by_user)
      values (v_reg.org_id, v_reg.id,
              case when v_c ? 'menu_item_id' then v_target end, case when v_c ? 'ingredient_id' then v_target end,
              'stocktake', v_var, v_counted, v_expected, v_id, p_note, p_by, auth.uid());
  end loop;

  begin
    insert into pos.stocktakes (id, org_id, register_id, lines, items_counted, items_with_variance, note,
                                client_transaction_id, operator_name, created_by_user)
      values (v_id, v_reg.org_id, v_reg.id, v_lines, jsonb_array_length(v_lines), v_with_var, p_note,
              p_client_transaction_id, p_by, auth.uid())
      returning * into v_st;
  exception when unique_violation then
    raise exception 'order.invalid_transaction';
  end;
  return v_st;
end;
$$;

grant execute on function pos.record_waste(uuid, text, uuid, uuid, numeric, text, text, text) to authenticated;
grant execute on function pos.record_stocktake(uuid, text, jsonb, text, text, uuid) to authenticated;
grant execute on all functions in schema pos to service_role;

-- ---------------------------------------------------------------------
-- Reposición: el servidor valida la cantidad (antes solo la pantalla)
-- ---------------------------------------------------------------------
create or replace function pos.restock_item(
  p_register_id uuid, p_pin text, p_item_id uuid, p_mode text, p_qty numeric,
  p_note text default null, p_by text default null
) returns pos.menu_items
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_reg pos.registers;
  v_item pos.menu_items;
  v_new_stock numeric;
  v_new_initial numeric;
  v_type text;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);

  select * into v_item from pos.menu_items where id = p_item_id and register_id = v_reg.id for update;
  if v_item.id is null then raise exception 'product.not_found'; end if;
  if p_qty is null or (p_mode = 'reset' and p_qty < 0) or (p_mode = 'add' and p_qty <= 0) then raise exception 'stock.invalid_qty'; end if;

  if p_mode = 'reset' then
    v_new_stock := p_qty; v_new_initial := p_qty; v_type := 'opening_stock';
  elsif p_mode = 'add' then
    v_new_stock := coalesce(v_item.stock_qty, 0) + p_qty;
    v_new_initial := coalesce(v_item.initial_stock, 0) + p_qty;
    v_type := 'purchase';
  else
    raise exception 'stock.invalid_mode';
  end if;

  update pos.menu_items set track_stock = true, stock_qty = v_new_stock, initial_stock = v_new_initial
    where id = p_item_id and register_id = v_reg.id returning * into v_item;

  insert into pos.stock_movements (org_id, register_id, menu_item_id, type, qty_change, qty_after, note, created_by, created_by_user)
    values (v_reg.org_id, v_reg.id, p_item_id, v_type, p_qty, v_new_stock, p_note, p_by, auth.uid());

  return v_item;
end;
$$;

create or replace function pos.restock_ingredient(
  p_register_id uuid, p_pin text, p_ingredient_id uuid, p_mode text, p_qty numeric, p_by text default null
) returns pos.ingredients
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_reg pos.registers;
  v_row pos.ingredients;
  v_new_stock numeric;
  v_new_initial numeric;
  v_type text;
begin
  v_reg := pos._register_with_pin(p_register_id, p_pin);
  if v_reg.id is null then return null; end if;
  perform set_config('pos.operator', coalesce(p_by, ''), true);

  select * into v_row from pos.ingredients where id = p_ingredient_id and register_id = v_reg.id for update;
  if v_row.id is null then raise exception 'ingredient.not_found'; end if;
  if p_qty is null or (p_mode = 'reset' and p_qty < 0) or (p_mode = 'add' and p_qty <= 0) then raise exception 'stock.invalid_qty'; end if;

  if p_mode = 'reset' then
    v_new_stock := p_qty; v_new_initial := p_qty; v_type := 'opening_stock';
  elsif p_mode = 'add' then
    v_new_stock := coalesce(v_row.stock_qty, 0) + p_qty;
    v_new_initial := coalesce(v_row.initial_stock, 0) + p_qty;
    v_type := 'purchase';
  else
    raise exception 'stock.invalid_mode';
  end if;

  update pos.ingredients set stock_qty = v_new_stock, initial_stock = v_new_initial
    where id = p_ingredient_id and register_id = v_reg.id returning * into v_row;

  insert into pos.stock_movements (org_id, register_id, ingredient_id, type, qty_change, qty_after, created_by, created_by_user)
    values (v_reg.org_id, v_reg.id, p_ingredient_id, v_type, p_qty, v_new_stock, p_by, auth.uid());

  return v_row;
end;
$$;

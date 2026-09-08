-- =====================================================================
-- Historial de stock: nueva tabla + funciones de reponer/reiniciar,
-- y actualización de create_order para que cada venta quede registrada.
-- =====================================================================

create table if not exists pos.stock_movements (
  id uuid primary key default gen_random_uuid(),
  menu_item_id uuid not null references pos.menu_items(id) on delete cascade,
  register_id uuid not null references pos.registers(id),
  event_id uuid references pos.events(id),
  type text not null check (type in ('carga_inicial','restock','venta','ajuste')),
  qty_change numeric(10,2) not null,
  qty_after numeric(10,2) not null,
  note text,
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists idx_stock_mov_item on pos.stock_movements (menu_item_id, created_at desc);
alter table pos.stock_movements enable row level security;
drop policy if exists "acceso interno" on pos.stock_movements;
create policy "acceso interno" on pos.stock_movements for all using (true) with check (true);
revoke insert, update, delete on pos.stock_movements from anon, authenticated;
create or replace function pos.restock_item(
  p_register_id uuid, p_pin text, p_item_id uuid, p_mode text, p_qty numeric,
  p_note text default null, p_by text default null
) returns pos.menu_items language plpgsql security definer set search_path = pos as $$
declare
  v_item pos.menu_items;
  v_new_stock numeric;
  v_new_initial numeric;
  v_type text;
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  select * into v_item from pos.menu_items where id = p_item_id and register_id = p_register_id;
  if v_item is null then raise exception 'Producto no encontrado'; end if;

  if p_mode = 'reset' then
    v_new_stock := p_qty; v_new_initial := p_qty; v_type := 'carga_inicial';
  elsif p_mode = 'add' then
    v_new_stock := coalesce(v_item.stock_qty,0) + p_qty;
    v_new_initial := coalesce(v_item.initial_stock,0) + p_qty;
    v_type := 'restock';
  else
    raise exception 'Modo inválido';
  end if;

  update pos.menu_items set track_stock = true, stock_qty = v_new_stock, initial_stock = v_new_initial
    where id = p_item_id returning * into v_item;

  insert into pos.stock_movements (menu_item_id, register_id, type, qty_change, qty_after, note, created_by)
    values (p_item_id, p_register_id, v_type, p_qty, v_new_stock, p_note, p_by);

  return v_item;
end;
$$;
grant execute on function pos.restock_item(uuid, text, uuid, text, numeric, text, text) to anon, authenticated;

create or replace function pos.disable_stock(p_register_id uuid, p_pin text, p_item_id uuid)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  update pos.menu_items set track_stock = false where id = p_item_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.disable_stock(uuid, text, uuid) to anon, authenticated;

create or replace function pos.create_order(
  p_register_id uuid, p_pin text, p_event_id uuid, p_items jsonb,
  p_payment_method text, p_cash numeric, p_card numeric,
  p_customer_name text, p_obs text, p_attended_by text,
  p_admin_pin text default null
) returns pos.orders language plpgsql security definer set search_path = pos as $$
declare
  v_register pos.registers;
  v_total numeric := 0;
  v_ticket_num int;
  v_status text;
  v_delivered_at timestamptz := null;
  v_order pos.orders;
  v_item jsonb;
  v_stock_after numeric;
begin
  select * into v_register from pos.registers where id = p_register_id;
  if v_register is null or v_register.pin <> p_pin then
    raise exception 'PIN incorrecto';
  end if;

  if p_payment_method = 'cortesia' then
    if p_admin_pin is null or not pos.verify_admin_pin(p_admin_pin) then
      raise exception 'Cortesía requiere PIN de administrador válido';
    end if;
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_total := v_total + coalesce((v_item->>'subtotal')::numeric, 0);
  end loop;

  if p_payment_method <> 'cortesia' and abs((coalesce(p_cash,0) + coalesce(p_card,0)) - v_total) > 1 then
    raise exception 'El efectivo + tarjeta no coincide con el total';
  end if;

  update pos.registers set next_ticket = next_ticket + 1 where id = p_register_id returning next_ticket - 1 into v_ticket_num;

  if v_register.type = 'ticket' then
    v_status := 'entregado';
    v_delivered_at := now();
  else
    v_status := 'pendiente_entrega';
  end if;

  insert into pos.orders (
    register_id, event_id, ticket_num, items, total, payment_method,
    cash_amount, card_amount, customer_name, attended_by, status, obs, delivered_at
  ) values (
    p_register_id, p_event_id, v_ticket_num, p_items, v_total, p_payment_method,
    coalesce(p_cash,0), coalesce(p_card,0), p_customer_name, p_attended_by, v_status, p_obs, v_delivered_at
  ) returning * into v_order;

  -- Descontar stock de los productos vendidos que lo tengan activado.
  -- IMPORTANTE: solo toca stock_qty, nunca initial_stock (esa es la base
  -- del % restante — reiniciarla en cada venta es el bug que hacía que
  -- siempre marcara 100%).
  for v_item in select * from jsonb_array_elements(p_items) loop
    if v_item ? 'id' then
      update pos.menu_items
        set stock_qty = greatest(0, stock_qty - coalesce((v_item->>'qty')::numeric, 0))
        where id = (v_item->>'id')::uuid
          and register_id = p_register_id
          and track_stock = true
          and stock_qty is not null
        returning stock_qty into v_stock_after;

      if found then
        insert into pos.stock_movements (menu_item_id, register_id, event_id, type, qty_change, qty_after, created_by)
          values ((v_item->>'id')::uuid, p_register_id, p_event_id, 'venta',
                  -coalesce((v_item->>'qty')::numeric, 0), v_stock_after, p_attended_by);
      end if;
    end if;
  end loop;

  return v_order;
end;
$$;
grant execute on function pos.create_order(uuid, text, uuid, jsonb, text, numeric, numeric, text, text, text, text) to anon, authenticated;

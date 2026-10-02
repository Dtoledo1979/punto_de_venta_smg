-- =====================================================================
-- Reporte de ventas de la oficina (pantalla Ventas), para cualquier
-- período, todos los locales o uno, y opcionalmente un evento.
-- Solo owner/admin/manager. Fechas en la zona horaria del negocio.
--
-- Ventas = pedidos cobrados (no anulados, no de prueba, no cortesías).
-- Las cortesías se informan aparte: no son ingresos.
-- Ventas netas = ventas − devoluciones del período.
--
-- También corrige "Hoy" (today_overview): no sumaba aparte las cortesías.
-- =====================================================================
create function pos.sales_report(
  p_org_id uuid, p_from date, p_to date, p_location_id uuid default null, p_event_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_tz text; v_start timestamptz; v_end timestamptz; v_prev_start timestamptz; v_days int; v_res jsonb;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin','manager']);
  if p_from is null or p_to is null or p_to < p_from then raise exception 'report.invalid_range'; end if;
  if p_to - p_from > 366 then raise exception 'report.range_too_long'; end if;
  if p_location_id is not null and not exists (select 1 from pos.locations where id = p_location_id and org_id = p_org_id) then
    raise exception 'location.not_found';
  end if;
  if p_event_id is not null and not exists (select 1 from pos.events where id = p_event_id and org_id = p_org_id) then
    raise exception 'event.not_found';
  end if;
  select timezone into v_tz from pos.organizations where id = p_org_id;
  v_start := p_from::timestamp at time zone v_tz;
  v_end := (p_to + 1)::timestamp at time zone v_tz;
  v_days := p_to - p_from + 1;
  v_prev_start := (p_from - v_days)::timestamp at time zone v_tz;

  with regs as (
    select r.id, r.name, r.location_id from pos.registers r
    where r.org_id = p_org_id and (p_location_id is null or r.location_id = p_location_id)
  ),
  ord as (
    select o.*, regs.location_id, regs.name as register_name,
           (o.paid_at at time zone v_tz) as local_ts
    from pos.orders o join regs on regs.id = o.register_id
    where o.org_id = p_org_id and not o.is_test and o.status <> 'voided'
      and o.paid_at >= v_prev_start and o.paid_at < v_end
      and (p_event_id is null or o.event_id = p_event_id)
  ),
  cur as (select * from ord where paid_at >= v_start),
  sales as (select * from cur where payment_method <> 'complimentary'),
  ref as (
    select f.amount, f.method, f.created_at, (f.created_at at time zone v_tz) as local_ts, regs.location_id
    from pos.refunds f join regs on regs.id = f.register_id
    join pos.orders o on o.id = f.order_id
    where f.org_id = p_org_id and not f.is_test and f.created_at >= v_prev_start and f.created_at < v_end
      and (p_event_id is null or o.event_id = p_event_id)
  )
  select jsonb_build_object(
    'timezone', v_tz, 'from', p_from, 'to', p_to, 'days', v_days,
    'gross', coalesce((select sum(total) from sales), 0),
    'refunds', coalesce((select sum(amount) from ref where created_at >= v_start), 0),
    'net', coalesce((select sum(total) from sales), 0) - coalesce((select sum(amount) from ref where created_at >= v_start), 0),
    'orders', (select count(*) from sales),
    'avg_ticket', coalesce((select round(avg(total), 2) from sales), 0),
    'gst', coalesce((select sum(tax_amount) from sales), 0),
    'complimentary', jsonb_build_object(
      'orders', (select count(*) from cur where payment_method = 'complimentary'),
      'value', coalesce((select sum(total) from cur where payment_method = 'complimentary'), 0)),
    'previous', jsonb_build_object(
      'net', coalesce((select sum(total) from ord where paid_at < v_start and payment_method <> 'complimentary'), 0)
             - coalesce((select sum(amount) from ref where created_at < v_start), 0),
      'orders', (select count(*) from ord where paid_at < v_start and payment_method <> 'complimentary')),
    'by_day', coalesce((
      select jsonb_agg(jsonb_build_object('date', d::date,
        'net', coalesce((select sum(total) from sales where local_ts::date = d::date), 0)
             - coalesce((select sum(amount) from ref where created_at >= v_start and local_ts::date = d::date), 0),
        'orders', (select count(*) from sales where local_ts::date = d::date)) order by d)
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d), '[]'::jsonb),
    'by_hour', coalesce((
      select jsonb_agg(jsonb_build_object('hour', h,
        'gross', coalesce((select sum(total) from sales where extract(hour from local_ts) = h), 0),
        'orders', (select count(*) from sales where extract(hour from local_ts) = h)) order by h)
      from generate_series(0, 23) h), '[]'::jsonb),
    'by_payment', jsonb_build_object(
      'cash', coalesce((select sum(cash_amount) from sales), 0),
      'card', coalesce((select sum(card_amount) from sales), 0),
      'refunds_cash', coalesce((select sum(amount) from ref where created_at >= v_start and method = 'cash'), 0),
      'refunds_card', coalesce((select sum(amount) from ref where created_at >= v_start and method = 'card'), 0)),
    'by_product', coalesce((
      select jsonb_agg(x order by x.sales desc, x.name) from (
        select it->>'name' as name, sum((it->>'qty')::numeric) as qty, sum((it->>'subtotal')::numeric) as sales
        from sales, jsonb_array_elements(sales.items) it
        group by it->>'name' order by 3 desc, 1 limit 100) x), '[]'::jsonb),
    'by_location', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name,
        'net', coalesce((select sum(total) from sales where sales.location_id = l.id), 0)
             - coalesce((select sum(amount) from ref where created_at >= v_start and ref.location_id = l.id), 0),
        'orders', (select count(*) from sales where sales.location_id = l.id)) order by l.created_at)
      from pos.locations l where l.org_id = p_org_id and (p_location_id is null or l.id = p_location_id)), '[]'::jsonb),
    'by_register', coalesce((
      select jsonb_agg(jsonb_build_object('name', register_name, 'gross', g, 'orders', n) order by g desc)
      from (select register_name, sum(total) g, count(*) n from sales group by register_name) r), '[]'::jsonb),
    'by_staff', coalesce((
      select jsonb_agg(jsonb_build_object('name', who, 'gross', g, 'orders', n, 'avg', round(g / n, 2)) order by g desc)
      from (select coalesce(nullif(trim(attended_by), ''), '—') who, sum(total) g, count(*) n from sales group by 1) s), '[]'::jsonb)
  ) into v_res;
  return v_res;
end;
$$;

revoke execute on function pos.sales_report(uuid, date, date, uuid, uuid) from public, anon;
grant execute on function pos.sales_report(uuid, date, date, uuid, uuid) to authenticated, service_role;

-- "Hoy": las cortesías no son ventas (misma función, con ese filtro).
create or replace function pos.today_overview(p_org_id uuid, p_location_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
declare
  v_tz text; v_start timestamptz; v_now timestamptz := now();
  v_week constant interval := interval '7 days';
  v_res jsonb;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin','manager']);
  if p_location_id is not null and not exists (select 1 from pos.locations where id = p_location_id and org_id = p_org_id) then
    raise exception 'location.not_found';
  end if;
  select timezone into v_tz from pos.organizations where id = p_org_id;
  v_start := date_trunc('day', v_now at time zone v_tz) at time zone v_tz;

  with regs as (
    select r.id, r.location_id from pos.registers r
    where r.org_id = p_org_id and (p_location_id is null or r.location_id = p_location_id)
  ),
  ord as (
    select o.*, regs.location_id from pos.orders o join regs on regs.id = o.register_id
    where o.org_id = p_org_id and not o.is_test and o.status <> 'voided' and o.payment_method <> 'complimentary'
      and ((o.paid_at >= v_start and o.paid_at <= v_now) or (o.paid_at >= v_start - v_week and o.paid_at <= v_now - v_week))
  ),
  ref as (
    select f.amount, f.created_at, regs.location_id from pos.refunds f join regs on regs.id = f.register_id
    where f.org_id = p_org_id and not f.is_test
      and ((f.created_at >= v_start and f.created_at <= v_now) or (f.created_at >= v_start - v_week and f.created_at <= v_now - v_week))
  ),
  totals as (
    select
      coalesce(sum(total) filter (where paid_at >= v_start), 0) as gross,
      count(*) filter (where paid_at >= v_start) as orders,
      coalesce(sum(total) filter (where paid_at < v_start), 0) as gross_lw,
      count(*) filter (where paid_at < v_start) as orders_lw
    from ord
  ),
  rtotals as (
    select coalesce(sum(amount) filter (where created_at >= v_start), 0) as refunds,
           coalesce(sum(amount) filter (where created_at < v_start), 0) as refunds_lw
    from ref
  )
  select jsonb_build_object(
    'timezone', v_tz,
    'day_start', v_start,
    'as_of', v_now,
    'sales', t.gross - r.refunds,
    'orders', t.orders,
    'avg_ticket', case when t.orders > 0 then round(t.gross / t.orders, 2) else 0 end,
    'refunds', r.refunds,
    'last_week', jsonb_build_object(
      'sales', t.gross_lw - r.refunds_lw, 'orders', t.orders_lw,
      'avg_ticket', case when t.orders_lw > 0 then round(t.gross_lw / t.orders_lw, 2) else 0 end),
    'by_location', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name,
               'sales', coalesce((select sum(total) from ord where ord.location_id = l.id and paid_at >= v_start), 0)
                      - coalesce((select sum(amount) from ref where ref.location_id = l.id and created_at >= v_start), 0),
               'orders', (select count(*) from ord where ord.location_id = l.id and paid_at >= v_start))
             order by l.created_at)
      from pos.locations l where l.org_id = p_org_id and (p_location_id is null or l.id = p_location_id)), '[]'::jsonb),
    'top_products', coalesce((
      select jsonb_agg(x order by x.qty desc, x.name) from (
        select it->>'name' as name, sum((it->>'qty')::numeric) as qty, sum((it->>'subtotal')::numeric) as sales
        from ord, jsonb_array_elements(ord.items) it
        where ord.paid_at >= v_start
        group by it->>'name' order by 2 desc, 1 limit 5) x), '[]'::jsonb),
    'registers', jsonb_build_object(
      'total', (select count(*) from pos.registers r join regs on regs.id = r.id where r.active),
      'open', (select count(*) from pos.register_sessions s join regs on regs.id = s.register_id where s.status = 'open')),
    'open_sessions', coalesce((
      select jsonb_agg(jsonb_build_object('register', r.name, 'location', l.name, 'opened_at', s.opened_at, 'opened_by', s.opened_by_name) order by s.opened_at)
      from pos.register_sessions s join pos.registers r on r.id = s.register_id join regs on regs.id = r.id
      join pos.locations l on l.id = r.location_id where s.status = 'open'), '[]'::jsonb),
    'low_stock', coalesce((
      select jsonb_agg(y order by y.pct) from (
        select m.name, m.stock_qty as qty, null::text as unit, round(m.stock_qty / m.initial_stock, 3) as pct, rg.name as register
        from pos.menu_items m join regs on regs.id = m.register_id join pos.registers rg on rg.id = m.register_id
        where m.active and m.track_stock and m.initial_stock > 0 and m.stock_qty / m.initial_stock <= 0.25
        union all
        select i.name, i.stock_qty, i.unit, round(i.stock_qty / i.initial_stock, 3), rg.name
        from pos.ingredients i join regs on regs.id = i.register_id join pos.registers rg on rg.id = i.register_id
        where i.active and i.initial_stock > 0 and i.stock_qty is not null and i.stock_qty / i.initial_stock <= 0.25
        order by 4 limit 8) y), '[]'::jsonb),
    'last_close_variance', (
      select jsonb_build_object('register', r.name, 'variance', s.cash_variance, 'closed_at', s.closed_at)
      from pos.register_sessions s join pos.registers r on r.id = s.register_id join regs on regs.id = r.id
      where s.status = 'closed' and s.cash_variance <> 0 and s.closed_at >= v_start - interval '1 day'
      order by s.closed_at desc limit 1),
    'setup', jsonb_build_object(
      'details', (select legal_name is not null and address_line is not null and contact_phone is not null from pos.organizations where id = p_org_id),
      'products', exists (select 1 from pos.menu_items m where m.org_id = p_org_id and m.active),
      'registers', exists (select 1 from pos.registers r where r.org_id = p_org_id and r.active),
      'first_sale', exists (select 1 from pos.orders o where o.org_id = p_org_id),
      'team', (select count(*) from pos.memberships m where m.org_id = p_org_id and m.status = 'active') > 1)
  ) into v_res
  from totals t, rtotals r;
  return v_res;
end;
$$;

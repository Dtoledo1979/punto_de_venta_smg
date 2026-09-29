-- =====================================================================
-- Borrar datos de prueba (Test Mode → "Clear test data").
--
-- Las ventas de prueba (is_test) nunca tocan stock ni reportes, pero
-- quedan guardadas. Esta función las elimina — solo las de prueba, solo
-- de la propia organización, solo owner/admin — junto con sus pagos,
-- intentos rechazados y reembolsos de prueba. Los guardas de
-- inmutabilidad siguen protegiendo TODO lo que no es de prueba.
-- La auditoría conserva el registro de que se borró (y cuánto).
-- =====================================================================

create or replace function pos._payments_guard() returns trigger
language plpgsql set search_path = pos, extensions, pg_temp as $$
begin
  if tg_op = 'DELETE' then
    if not exists (select 1 from pos.organizations where id = old.org_id) then return old; end if; -- cascade
    if old.is_test and current_setting('pos.purging_test_data', true) = 'on' then return old; end if;
    raise exception 'payment.immutable';
  end if;
  if (to_jsonb(new) - 'status') <> (to_jsonb(old) - 'status')
     or not ((old.status, new.status) in (('approved','voided'), ('voided','approved'))) or new.kind <> 'payment' then
    raise exception 'payment.immutable';
  end if;
  return new;
end;
$$;

create or replace function pos._refunds_guard() returns trigger
language plpgsql set search_path = pos, extensions, pg_temp as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from pos.organizations where id = old.org_id) then return old; end if; -- cascade
  if tg_op = 'DELETE' and old.is_test and current_setting('pos.purging_test_data', true) = 'on' then return old; end if;
  raise exception 'refund.immutable';
end;
$$;

create function pos.purge_test_data(p_org_id uuid) returns jsonb
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_orders int; v_payments int; v_refunds int;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin']);
  perform set_config('pos.purging_test_data', 'on', true);

  delete from pos.payments where org_id = p_org_id and is_test;
  get diagnostics v_payments = row_count;
  delete from pos.refunds where org_id = p_org_id and is_test;
  get diagnostics v_refunds = row_count;
  delete from pos.orders where org_id = p_org_id and is_test;
  get diagnostics v_orders = row_count;

  perform set_config('pos.purging_test_data', 'off', true);
  perform pos._audit(p_org_id, null, 'test_data.purge', 'organization', p_org_id,
    jsonb_build_object('orders', v_orders, 'payments', v_payments, 'refunds', v_refunds));
  return jsonb_build_object('orders', v_orders, 'payments', v_payments, 'refunds', v_refunds);
end;
$$;

revoke execute on function pos.purge_test_data(uuid) from public, anon;
grant execute on function pos.purge_test_data(uuid) to authenticated;

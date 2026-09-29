-- =====================================================================
-- Endurecimiento de permisos de funciones (hallazgo del revisor de
-- seguridad de Supabase).
--
-- Supabase otorga EXECUTE a anon/authenticated en TODA función nueva por
-- un privilegio por defecto GLOBAL del rol postgres; el "revoke ... in
-- schema pos" de la migración 1 no lo anula. La migración 3 lo corrigió
-- con un revoke explícito, pero las funciones creadas en las migraciones
-- 5 a 10 heredaron el EXECUTE. Consecuencias:
--   * anon: ninguna (no tiene USAGE en el schema pos: no puede llamar nada).
--   * authenticated: podía llamar funciones internas. La relevante:
--     pos._session_totals no verifica membresía (la usan funciones que sí
--     lo hacen) → con el id de una sesión de caja de OTRA organización se
--     podían leer sus totales.
--
-- Regla desde ahora (verificada por supabase/checks/fase7_permisos.sql):
--   * anon: EXECUTE en ninguna función del schema pos.
--   * authenticated: EXECUTE solo en la API pública; nunca en funciones
--     internas (prefijo _) ni en las de uso exclusivo del servidor.
-- =====================================================================

revoke execute on all functions in schema pos from public, anon;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'pos'
      and (p.proname like '\_%' or p.proname in ('set_subscription'))
  loop
    execute format('revoke execute on function %s from authenticated', f.sig);
  end loop;
end $$;

-- Las funciones usadas dentro de políticas RLS se evalúan con los
-- permisos de quien consulta: necesitan EXECUTE para authenticated.
grant execute on function pos.user_org_ids() to authenticated;
grant execute on function pos.has_org_role(uuid, text[]) to authenticated;
grant execute on function pos.is_org_member(uuid) to authenticated;

-- search_path fijo en todas las funciones (incluidas las de triggers).
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'pos'
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  loop
    execute format('alter function %s set search_path = pos, extensions, pg_temp', f.sig);
  end loop;
end $$;

-- Índices para las FKs usadas en consultas y borrados en cascada.
create index if not exists payments_refund_idx on pos.payments (refund_id);
create index if not exists stock_movements_stocktake_idx on pos.stock_movements (stocktake_id);
create index if not exists stock_movements_register_idx on pos.stock_movements (register_id, created_at desc);
create index if not exists orders_register_event_idx on pos.orders (register_id, event_id);
create index if not exists refunds_register_idx on pos.refunds (register_id, created_at desc);
create index if not exists cash_movements_register_idx on pos.cash_movements (register_id);
create index if not exists recipe_items_ingredient_idx on pos.recipe_items (ingredient_id, register_id);
create index if not exists promotions_menu_item_register_idx on pos.promotions (menu_item_id, register_id);

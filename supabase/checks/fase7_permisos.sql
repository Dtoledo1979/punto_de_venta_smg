-- =====================================================================
-- Verificación de Fase 7: permisos de funciones (regla general, cubre
-- también las funciones que se agreguen en el futuro).
-- =====================================================================
reset role;
do $$
declare v_bad text;
begin
  -- P1. anon no ejecuta NINGUNA función del schema pos.
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'pos' and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_bad is not null then raise exception 'FALLA P1: anon puede ejecutar: %', v_bad; end if;

  -- P2. authenticated no ejecuta funciones internas ni de servidor.
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'pos' and (p.proname like '\_%' or p.proname = 'set_subscription')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if v_bad is not null then raise exception 'FALLA P2: authenticated puede ejecutar funciones internas: %', v_bad; end if;

  -- P3. Toda función security definer fija su search_path.
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'pos'
    and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%');
  if v_bad is not null then raise exception 'FALLA P3: funciones sin search_path fijo: %', v_bad; end if;

  -- P4. Toda tabla del schema tiene RLS activada.
  select string_agg(c.relname, ', ') into v_bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'pos' and c.relkind = 'r' and not c.relrowsecurity;
  if v_bad is not null then raise exception 'FALLA P4: tablas sin RLS: %', v_bad; end if;

  -- P5. Ninguna tabla acepta escrituras directas de anon/authenticated.
  select string_agg(distinct c.relname, ', ') into v_bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  cross join (values ('anon'), ('authenticated')) r(role)
  cross join (values ('INSERT'), ('UPDATE'), ('DELETE')) pr(priv)
  where n.nspname = 'pos' and c.relkind = 'r' and has_table_privilege(r.role, c.oid, pr.priv);
  if v_bad is not null then raise exception 'FALLA P5: escritura directa permitida en: %', v_bad; end if;

  raise notice 'OK P1-P5: permisos de funciones y tablas';
end $$;

select 'FASE 7: TODAS LAS VERIFICACIONES PASARON' as resultado_fase7;

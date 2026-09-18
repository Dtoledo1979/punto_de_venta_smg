-- =====================================================================
-- Soporte para varias ubicaciones/cajas (ej. Christchurch + Wellington
-- funcionando al mismo tiempo, cada una con su propio stock).
-- Solo agrega una función nueva — no toca tablas existentes.
-- =====================================================================

create or replace function pos.create_register(p_admin_pin text, p_name text, p_type text, p_pin text, p_despacho_pin text)
returns pos.registers language plpgsql security definer set search_path = pos as $$
declare v_row pos.registers;
begin
  if not pos.verify_admin_pin(p_admin_pin) then raise exception 'PIN de administrador incorrecto'; end if;
  if p_type not in ('producto','ticket') then raise exception 'Tipo inválido'; end if;
  insert into pos.registers (name, type, pin, despacho_pin)
    values (p_name, p_type, p_pin, coalesce(p_despacho_pin, '5678'))
    returning * into v_row;
  return v_row;
end;
$$;
grant execute on function pos.create_register(text, text, text, text, text) to anon, authenticated;

alter table pos.menu_items add column if not exists color text;

create or replace function pos.set_item_color(p_register_id uuid, p_pin text, p_item_id uuid, p_color text)
returns boolean language plpgsql security definer set search_path = pos as $$
begin
  if not pos.verify_register_pin(p_register_id, p_pin) then raise exception 'PIN incorrecto'; end if;
  update pos.menu_items set color = p_color where id = p_item_id and register_id = p_register_id;
  return true;
end;
$$;
grant execute on function pos.set_item_color(uuid, text, uuid, text) to anon, authenticated;

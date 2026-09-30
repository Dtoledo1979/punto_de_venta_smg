-- =====================================================================
-- Datos del negocio para el perfil del cliente (facturación de la
-- suscripción y facturas de GST): razón social, dirección, contacto y
-- teléfono obligatorios al dar de alta; NZBN opcional.
--
-- Las organizaciones ya existentes quedan con estos campos vacíos; el
-- owner los completa desde Settings (update_organization_details).
-- =====================================================================

alter table pos.organizations
  add column legal_name    text,
  add column address_line  text,
  add column city          text,
  add column postcode      text,
  add column country       text not null default 'NZ',
  add column contact_name  text,
  add column contact_phone text,
  add column nzbn          text;

alter table pos.organizations
  add constraint organizations_country_check  check (country ~ '^[A-Z]{2}$'),
  add constraint organizations_nzbn_check     check (nzbn is null or nzbn ~ '^[0-9]{13}$'),
  add constraint organizations_phone_check    check (contact_phone is null or contact_phone ~ '^\+?[0-9 ()-]{6,20}$'),
  add constraint organizations_details_length check (
    coalesce(length(legal_name), 0) <= 200 and coalesce(length(address_line), 0) <= 300
    and coalesce(length(city), 0) <= 100 and coalesce(length(postcode), 0) <= 12
    and coalesce(length(contact_name), 0) <= 150);

-- Valida y normaliza los datos del negocio (compartido por alta y edición).
-- Devuelve el NZBN normalizado (solo dígitos) o null.
create function pos._validate_business_details(
  p_legal_name text, p_address_line text, p_city text, p_postcode text,
  p_contact_name text, p_contact_phone text, p_nzbn text
) returns text
language plpgsql immutable set search_path = pos, extensions, pg_temp as $$
declare v_nzbn text := nullif(regexp_replace(coalesce(p_nzbn, ''), '[\s-]', '', 'g'), '');
begin
  if coalesce(trim(p_legal_name), '') = '' or coalesce(trim(p_address_line), '') = ''
     or coalesce(trim(p_city), '') = '' or coalesce(trim(p_contact_name), '') = ''
     or coalesce(trim(p_contact_phone), '') = '' then
    raise exception 'org.details_required';
  end if;
  if trim(p_contact_phone) !~ '^\+?[0-9 ()-]{6,20}$' then raise exception 'org.invalid_phone'; end if;
  if v_nzbn is not null and v_nzbn !~ '^[0-9]{13}$' then raise exception 'org.invalid_nzbn'; end if;
  if length(trim(p_legal_name)) > 200 or length(trim(p_address_line)) > 300 or length(trim(p_city)) > 100
     or length(coalesce(trim(p_postcode), '')) > 12 or length(trim(p_contact_name)) > 150 then
    raise exception 'validation.too_long';
  end if;
  return v_nzbn;
end;
$$;

-- ---------------------------------------------------------------------
-- Alta: ahora exige los datos del negocio.
-- ---------------------------------------------------------------------
drop function pos.create_organization(text, text, text, text, text, text, numeric, text);
create function pos.create_organization(
  p_name text, p_slug text, p_supervisor_pin text,
  p_language text default 'en', p_locale text default 'en-NZ',
  p_currency text default 'NZD', p_tax_rate numeric default 0.15, p_tax_number text default null,
  p_legal_name text default null, p_address_line text default null, p_city text default null,
  p_postcode text default null, p_contact_name text default null, p_contact_phone text default null,
  p_nzbn text default null
) returns pos.organizations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_org pos.organizations; v_nzbn text;
begin
  if auth.uid() is null then raise exception 'auth.forbidden'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'validation.name_required'; end if;
  if (select count(*) from pos.memberships where user_id = auth.uid() and role = 'owner') >= 3 then
    raise exception 'org.too_many';
  end if;
  if p_currency !~ '^[A-Z]{3}$' then raise exception 'org.invalid_currency'; end if;
  if p_tax_rate is null or p_tax_rate < 0 or p_tax_rate >= 1 then raise exception 'org.invalid_tax_rate'; end if;
  if lower(trim(p_slug)) !~ '^[a-z0-9-]{3,40}$' then raise exception 'org.invalid_slug'; end if;
  v_nzbn := pos._validate_business_details(p_legal_name, p_address_line, p_city, p_postcode, p_contact_name, p_contact_phone, p_nzbn);
  if exists (select 1 from pos.organizations where slug = lower(trim(p_slug))) then raise exception 'org.slug_taken'; end if;

  insert into pos.organizations (name, slug, language, locale, currency, tax_rate, tax_number,
                                 legal_name, address_line, city, postcode, contact_name, contact_phone, nzbn)
    values (trim(p_name), lower(trim(p_slug)), coalesce(p_language, 'en'), coalesce(p_locale, 'en-NZ'),
            p_currency, p_tax_rate, nullif(trim(p_tax_number), ''),
            trim(p_legal_name), trim(p_address_line), trim(p_city), nullif(trim(p_postcode), ''),
            trim(p_contact_name), trim(p_contact_phone), v_nzbn)
    returning * into v_org;
  insert into pos.memberships (org_id, user_id, role) values (v_org.id, auth.uid(), 'owner');
  insert into pos.org_secrets (org_id, supervisor_pin_hash) values (v_org.id, pos._hash_pin(p_supervisor_pin));
  return v_org;
end;
$$;

-- ---------------------------------------------------------------------
-- Edición de los datos del negocio (owner/admin). Todos obligatorios
-- salvo código postal y NZBN (vacío = se borra).
-- ---------------------------------------------------------------------
create function pos.update_organization_details(
  p_org_id uuid, p_legal_name text, p_address_line text, p_city text, p_postcode text,
  p_contact_name text, p_contact_phone text, p_nzbn text default null
) returns pos.organizations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_org pos.organizations; v_nzbn text;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin']);
  v_nzbn := pos._validate_business_details(p_legal_name, p_address_line, p_city, p_postcode, p_contact_name, p_contact_phone, p_nzbn);
  update pos.organizations set
    legal_name = trim(p_legal_name), address_line = trim(p_address_line), city = trim(p_city),
    postcode = nullif(trim(p_postcode), ''), contact_name = trim(p_contact_name),
    contact_phone = trim(p_contact_phone), nzbn = v_nzbn
  where id = p_org_id
  returning * into v_org;
  return v_org;
end;
$$;

-- Auditoría: se agregan los datos del negocio.
create or replace function pos._audit_organizations() returns trigger
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._audit(new.id, null, 'org.update', 'organization', new.id,
    jsonb_build_object(
      'old', jsonb_build_object('name', old.name, 'language', old.language, 'locale', old.locale, 'status', old.status,
                                'plan', old.plan, 'subscription_status', old.subscription_status, 'tax_rate', old.tax_rate, 'tax_number', old.tax_number,
                                'legal_name', old.legal_name, 'address_line', old.address_line, 'city', old.city, 'postcode', old.postcode,
                                'contact_name', old.contact_name, 'contact_phone', old.contact_phone, 'nzbn', old.nzbn),
      'new', jsonb_build_object('name', new.name, 'language', new.language, 'locale', new.locale, 'status', new.status,
                                'plan', new.plan, 'subscription_status', new.subscription_status, 'tax_rate', new.tax_rate, 'tax_number', new.tax_number,
                                'legal_name', new.legal_name, 'address_line', new.address_line, 'city', new.city, 'postcode', new.postcode,
                                'contact_name', new.contact_name, 'contact_phone', new.contact_phone, 'nzbn', new.nzbn)));
  return null;
end;
$$;

-- Permisos (las funciones nuevas nacen con EXECUTE para anon por los
-- default privileges globales de Supabase: se revoca explícitamente).
revoke execute on function pos._validate_business_details(text, text, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function pos.create_organization(text, text, text, text, text, text, numeric, text, text, text, text, text, text, text, text) from public, anon;
revoke execute on function pos.update_organization_details(uuid, text, text, text, text, text, text, text) from public, anon;
grant execute on function pos.create_organization(text, text, text, text, text, text, numeric, text, text, text, text, text, text, text, text) to authenticated;
grant execute on function pos.update_organization_details(uuid, text, text, text, text, text, text, text) to authenticated;
grant execute on all functions in schema pos to service_role;

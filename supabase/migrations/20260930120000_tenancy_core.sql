-- =====================================================================
-- Fase 1 — Núcleo multi-tenant: organizaciones, ubicaciones, miembros.
--
-- Identidad = Supabase Auth (auth.uid()). Tenant = pos.memberships.
-- La anon key no tiene ningún acceso al schema pos (ver grants en la
-- migración de tablas POS). Todas las escrituras pasan por funciones
-- security definer que verifican el rol del usuario adentro.
-- =====================================================================

create schema if not exists pos;
create extension if not exists pgcrypto with schema extensions;

-- Postgres le da EXECUTE a PUBLIC en toda función nueva por defecto.
-- Esto lo apaga para todo lo que se cree de acá en adelante en "pos":
-- cada RPC pública se habilita explícitamente, una por una.
alter default privileges in schema pos revoke execute on functions from public;
alter default privileges in schema pos revoke all on tables from anon, authenticated;

-- ---------------------------------------------------------------------
-- Organizaciones (tenants): cada negocio cliente del SaaS.
-- status = 'suspended' corta todo el acceso de sus usuarios de inmediato.
-- ---------------------------------------------------------------------
create table pos.organizations (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  slug       text not null unique check (slug ~ '^[a-z0-9-]{3,40}$'),
  status     text not null default 'active' check (status in ('active','suspended')),
  currency   text not null default 'NZD',
  timezone   text not null default 'Pacific/Auckland',
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Ubicaciones físicas de una organización (Christchurch, Wellington...).
-- unique (id, org_id) es el destino de las FKs compuestas que garantizan
-- que nada de una org pueda colgar de una ubicación de otra.
-- ---------------------------------------------------------------------
create table pos.locations (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references pos.organizations(id) on delete cascade,
  name       text not null,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, org_id),
  unique (org_id, name)
);

-- ---------------------------------------------------------------------
-- Miembros: qué usuario de Auth pertenece a qué organización, con qué rol.
--   owner   — todo, incluido gestionar owners y la organización.
--   admin   — ubicaciones, cajas, PINs, numeración, miembros (no owners).
--   manager — (reservado para permisos de gestión en fases siguientes).
--   staff   — operar cajas con su PIN. Las cuentas de dispositivos
--             compartidos deben ser staff.
-- ---------------------------------------------------------------------
create table pos.memberships (
  org_id     uuid not null references pos.organizations(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('owner','admin','manager','staff')),
  status     text not null default 'active' check (status in ('active','disabled')),
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index memberships_user_idx on pos.memberships (user_id) where status = 'active';

-- ---------------------------------------------------------------------
-- Secretos por organización. Reemplaza a la antigua pos.admin_settings
-- (una sola fila global). Nunca legible desde la API: sin grants ni
-- políticas, solo lo tocan funciones security definer.
-- ---------------------------------------------------------------------
create table pos.org_secrets (
  org_id              uuid primary key references pos.organizations(id) on delete cascade,
  supervisor_pin_hash text not null
);

-- =====================================================================
-- Funciones auxiliares de RLS.
-- security definer: leen memberships sin disparar su propia RLS (evita
-- recursión). search_path fijo: no se pueden secuestrar con objetos de
-- otro schema.
-- =====================================================================
create function pos.user_org_ids() returns setof uuid
language sql stable security definer set search_path = pos, extensions, pg_temp as $$
  select m.org_id
  from pos.memberships m
  join pos.organizations o on o.id = m.org_id
  where m.user_id = auth.uid() and m.status = 'active' and o.status = 'active'
$$;

create function pos.has_org_role(p_org_id uuid, p_roles text[]) returns boolean
language sql stable security definer set search_path = pos, extensions, pg_temp as $$
  select exists (
    select 1
    from pos.memberships m
    join pos.organizations o on o.id = m.org_id
    where m.org_id = p_org_id and m.user_id = auth.uid()
      and m.status = 'active' and o.status = 'active'
      and m.role = any (p_roles)
  )
$$;

create function pos.is_org_member(p_org_id uuid) returns boolean
language sql stable security definer set search_path = pos, extensions, pg_temp as $$
  select pos.has_org_role(p_org_id, array['owner','admin','manager','staff'])
$$;

create function pos._require_org_role(p_org_id uuid, p_roles text[]) returns void
language plpgsql stable security definer set search_path = pos, extensions, pg_temp as $$
begin
  if auth.uid() is null or not pos.has_org_role(p_org_id, p_roles) then
    raise exception 'No autorizado';
  end if;
end;
$$;

-- PIN: solo dígitos, 4 a 8. Se guarda con bcrypt, nunca en texto plano.
create function pos._hash_pin(p_pin text) returns text
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  if p_pin is null or p_pin !~ '^[0-9]{4,8}$' then
    raise exception 'El PIN debe tener entre 4 y 8 dígitos';
  end if;
  return extensions.crypt(p_pin, extensions.gen_salt('bf'));
end;
$$;

-- =====================================================================
-- Alta de organizaciones y gestión de miembros
-- =====================================================================

-- Cualquier usuario autenticado puede crear una organización y queda como
-- su owner. (Mientras el registro público de usuarios esté desactivado en
-- Auth, solo pueden hacerlo las cuentas que se creen a mano.)
create function pos.create_organization(p_name text, p_slug text, p_supervisor_pin text)
returns pos.organizations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_org pos.organizations;
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'El nombre es obligatorio'; end if;

  insert into pos.organizations (name, slug) values (trim(p_name), lower(trim(p_slug)))
    returning * into v_org;
  insert into pos.memberships (org_id, user_id, role) values (v_org.id, auth.uid(), 'owner');
  insert into pos.org_secrets (org_id, supervisor_pin_hash) values (v_org.id, pos._hash_pin(p_supervisor_pin));
  return v_org;
end;
$$;

create function pos.create_location(p_org_id uuid, p_name text)
returns pos.locations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_loc pos.locations;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin']);
  if coalesce(trim(p_name), '') = '' then raise exception 'El nombre es obligatorio'; end if;
  insert into pos.locations (org_id, name) values (p_org_id, trim(p_name)) returning * into v_loc;
  return v_loc;
end;
$$;

create function pos.update_location(p_location_id uuid, p_name text default null, p_active boolean default null)
returns pos.locations
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_loc pos.locations;
begin
  select * into v_loc from pos.locations where id = p_location_id;
  if v_loc.id is null then raise exception 'Ubicación no encontrada'; end if;
  perform pos._require_org_role(v_loc.org_id, array['owner','admin']);
  update pos.locations set
    name = coalesce(nullif(trim(p_name), ''), name),
    active = coalesce(p_active, active)
  where id = p_location_id
  returning * into v_loc;
  return v_loc;
end;
$$;

-- Agrega a un usuario que ya existe en Supabase Auth. (Las invitaciones
-- por email quedan para una fase siguiente.)
create function pos.add_member(p_org_id uuid, p_email text, p_role text)
returns pos.memberships
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_user_id uuid; v_row pos.memberships;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin']);
  if p_role not in ('owner','admin','manager','staff') then raise exception 'Rol inválido'; end if;
  if p_role = 'owner' and not pos.has_org_role(p_org_id, array['owner']) then
    raise exception 'Solo un owner puede agregar otro owner';
  end if;

  select id into v_user_id from auth.users where lower(email) = lower(trim(p_email));
  if v_user_id is null then
    raise exception 'No existe un usuario con ese email — hay que crearlo primero en Supabase Auth';
  end if;
  if exists (select 1 from pos.memberships where org_id = p_org_id and user_id = v_user_id) then
    raise exception 'Ese usuario ya es miembro — usa set_member_role para cambiar su rol';
  end if;

  insert into pos.memberships (org_id, user_id, role) values (p_org_id, v_user_id, p_role)
    returning * into v_row;
  return v_row;
end;
$$;

create function pos.set_member_role(p_org_id uuid, p_user_id uuid, p_role text default null, p_status text default null)
returns pos.memberships
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
declare v_target pos.memberships; v_caller_is_owner boolean;
begin
  perform pos._require_org_role(p_org_id, array['owner','admin']);
  -- Bloquear la organización serializa los cambios de roles concurrentes:
  -- sin esto, dos owners degradándose mutuamente al mismo tiempo podrían
  -- dejar la organización sin ningún owner.
  perform 1 from pos.organizations where id = p_org_id for update;

  select * into v_target from pos.memberships where org_id = p_org_id and user_id = p_user_id;
  if v_target.user_id is null then raise exception 'Miembro no encontrado'; end if;
  if p_role is not null and p_role not in ('owner','admin','manager','staff') then raise exception 'Rol inválido'; end if;
  if p_status is not null and p_status not in ('active','disabled') then raise exception 'Estado inválido'; end if;

  v_caller_is_owner := pos.has_org_role(p_org_id, array['owner']);
  if not v_caller_is_owner and (v_target.role = 'owner' or p_role = 'owner') then
    raise exception 'Solo un owner puede modificar owners';
  end if;

  update pos.memberships set
    role = coalesce(p_role, role),
    status = coalesce(p_status, status)
  where org_id = p_org_id and user_id = p_user_id
  returning * into v_target;

  if not exists (select 1 from pos.memberships where org_id = p_org_id and role = 'owner' and status = 'active') then
    raise exception 'La organización tiene que conservar al menos un owner activo';
  end if;
  return v_target;
end;
$$;

-- PIN de supervisor: autoriza cortesías en el dispositivo compartido.
-- Siempre se exige el PIN (no alcanza con el rol): en un dispositivo
-- compartido, el rol es el de la cuenta del dispositivo, no el de la
-- persona que lo está usando en ese momento.
create function pos.set_supervisor_pin(p_org_id uuid, p_new_pin text)
returns boolean
language plpgsql security definer set search_path = pos, extensions, pg_temp as $$
begin
  perform pos._require_org_role(p_org_id, array['owner','admin']);
  insert into pos.org_secrets (org_id, supervisor_pin_hash) values (p_org_id, pos._hash_pin(p_new_pin))
    on conflict (org_id) do update set supervisor_pin_hash = excluded.supervisor_pin_hash;
  return true;
end;
$$;

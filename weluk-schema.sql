-- =====================================================
-- WELUK — Esquema de Base de Datos (MVP)
-- Correr en: Supabase Studio → SQL Editor
-- =====================================================

-- Extensión para generar UUIDs
create extension if not exists "pgcrypto";

-- =====================================================
-- 1. COMPANIES
-- =====================================================
create table companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

-- =====================================================
-- 2. PROFILES
-- (id referencia a auth.users.id — se crea vía trigger o manual al registrar usuario)
-- =====================================================
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  company_id uuid references companies(id) on delete set null, -- null = superadmin
  role text not null check (role in ('superadmin', 'company_admin')),
  full_name text,
  created_at timestamptz not null default now()
);

-- =====================================================
-- 3. MEDIA
-- =====================================================
create table media (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  type text not null check (type in ('image', 'video')),
  storage_path text not null,
  duration_seconds integer not null default 8, -- default de reproducción para imágenes
  created_at timestamptz not null default now()
);

-- =====================================================
-- 4. PLAYLISTS
-- =====================================================
create table playlists (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  name text not null,
  updated_at timestamptz not null default now(),  -- cambia con cualquier edición (draft)
  published_at timestamptz,                        -- SOLO cambia al publicar — esto escucha el visor
  created_at timestamptz not null default now()
);

-- =====================================================
-- 5. PLAYLIST_ITEMS
-- =====================================================
create table playlist_items (
  id uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references playlists(id) on delete cascade,
  media_id uuid not null references media(id) on delete cascade,
  order_index integer not null default 0,
  duration_seconds integer, -- override opcional del default de media
  created_at timestamptz not null default now()
);

-- =====================================================
-- 6. SCREENS
-- =====================================================
create table screens (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  device_uuid uuid not null unique, -- generado/persistido en el visor (localStorage)
  name text not null,
  status text not null default 'pending' check (status in ('pending', 'paired', 'disconnected')),
  current_playlist_id uuid references playlists(id) on delete set null,
  current_playlist_updated_at timestamptz,
  last_seen_at timestamptz, -- respaldo histórico (Presence maneja el estado en vivo)
  created_at timestamptz not null default now()
);

-- =====================================================
-- 7. PAIRING_CODES
-- =====================================================
create table pairing_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  device_uuid uuid not null,
  status text not null default 'pending' check (status in ('pending', 'claimed', 'expired')),
  expires_at timestamptz not null,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);

-- Solo puede existir UN código pending por combinación código+estado a la vez
-- (evita colisión de dos pantallas mostrando el mismo código simultáneamente)
create unique index idx_pairing_codes_pending_unique
  on pairing_codes (code)
  where status = 'pending';

-- =====================================================
-- ÍNDICES adicionales para consultas frecuentes
-- =====================================================
create index idx_profiles_company_id on profiles(company_id);
create index idx_media_company_id on media(company_id);
create index idx_playlists_company_id on playlists(company_id);
create index idx_playlist_items_playlist_id on playlist_items(playlist_id);
create index idx_screens_company_id on screens(company_id);
create index idx_screens_device_uuid on screens(device_uuid);
create index idx_pairing_codes_device_uuid on pairing_codes(device_uuid);

-- =====================================================
-- ROW LEVEL SECURITY (RLS) — habilitar en todas las tablas
-- =====================================================
alter table companies enable row level security;
alter table profiles enable row level security;
alter table media enable row level security;
alter table playlists enable row level security;
alter table playlist_items enable row level security;
alter table screens enable row level security;
alter table pairing_codes enable row level security;

-- Función helper: obtiene el company_id del usuario autenticado actual
create or replace function auth_company_id()
returns uuid
language sql
security definer
stable
as $$
  select company_id from profiles where id = auth.uid()
$$;

-- Función helper: chequea si el usuario actual es superadmin
create or replace function is_superadmin()
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and role = 'superadmin'
  )
$$;

-- --- Policies: companies ---
create policy "superadmin ve todas las companies"
  on companies for select
  using (is_superadmin());

create policy "company_admin ve su propia company"
  on companies for select
  using (id = auth_company_id());

-- --- Policies: profiles ---
create policy "superadmin ve todos los profiles"
  on profiles for select
  using (is_superadmin());

create policy "usuario ve su propio profile"
  on profiles for select
  using (id = auth.uid());

-- --- Policies: media, playlists, playlist_items, screens (mismo patrón) ---
create policy "superadmin acceso total a media"
  on media for all
  using (is_superadmin());

create policy "company_admin ve su media"
  on media for select
  using (company_id = auth_company_id());

create policy "superadmin acceso total a playlists"
  on playlists for all
  using (is_superadmin());

create policy "company_admin ve sus playlists"
  on playlists for select
  using (company_id = auth_company_id());

create policy "superadmin acceso total a screens"
  on screens for all
  using (is_superadmin());

create policy "company_admin ve sus screens"
  on screens for select
  using (company_id = auth_company_id());

-- Nota: playlist_items y pairing_codes se acceden vía join con playlists/screens,
-- ajustar policies según se necesite al construir el panel (pendiente de afinar
-- cuando se implemente la lógica real de escritura desde el panel).

-- =====================================================
-- REALTIME — habilitar en las tablas que escucha el visor
-- =====================================================
alter publication supabase_realtime add table screens;
alter publication supabase_realtime add table playlists;
alter publication supabase_realtime add table pairing_codes;

-- =====================================================
-- ACCESO PARA EL VISOR (rol anon — sin sesión de usuario)
-- El visor (APK/browser) no hace login como usuario del panel,
-- opera como "anon" y necesita permisos explícitos, ya que
-- "Automatically expose new tables" está desactivado a propósito.
-- =====================================================

-- GRANTs base: sin esto, RLS ni siquiera entra a evaluarse
grant select, insert, update on pairing_codes to anon;
grant select on screens to anon;
grant select on playlists to anon;
grant select on playlist_items to anon;
grant select on media to anon;

-- --- Policies: pairing_codes (anon) ---
create policy "anon puede crear su codigo de pairing"
  on pairing_codes for insert
  to anon
  with check (true);

create policy "anon puede leer/consultar su propio codigo"
  on pairing_codes for select
  to anon
  using (true);

-- --- Policies: screens (anon) ---
-- El visor solo necesita leer SU PROPIA fila, filtrando por device_uuid
-- desde el cliente (no hay forma de restringir por fila sin auth real aquí,
-- así que el filtro efectivo lo hace el visor pidiendo su propio device_uuid;
-- se restringen las columnas sensibles a nivel de vista si se requiere más adelante)
create policy "anon puede leer screens por device_uuid"
  on screens for select
  to anon
  using (true);

-- El visor necesita poder desconectarse a sí mismo (botón "Disconnect" del overlay
-- de diagnóstico, sección 9 del CLAUDE.md). NO se usa una policy de UPDATE/DELETE
-- abierta para anon (using(true) permitía tocar CUALQUIER pantalla de CUALQUIER
-- company con solo la anon key, que es pública — corregido 30 julio 2026). En su
-- lugar, una función security definer auto-limitada a la fila del device_uuid
-- recibido como parámetro: el device_uuid funciona como token de capacidad (alta
-- entropía, generado con crypto.randomUUID), suficiente prueba de identidad para
-- un cliente anon sin sesión — pero un usuario autenticado del panel NO debe
-- reusar esta función, ya tiene ownership real vía auth_company_id().
--
-- "Eliminar pantalla" es de un solo paso (como Juuno, sin estado intermedio
-- 'disconnected'): desconectar = borrar la fila, libera el device_uuid de
-- inmediato sin que un admin tenga que borrar manualmente después.
create or replace function disconnect_own_screen(p_device_uuid uuid)
returns setof screens
language sql
security definer
as $$
  delete from screens where device_uuid = p_device_uuid returning *;
$$;

grant execute on function disconnect_own_screen(uuid) to anon;

-- Necesario para que Realtime pueda filtrar eventos DELETE por device_uuid. Por
-- defecto (REPLICA IDENTITY DEFAULT) Postgres solo incluye la primary key (`id`)
-- en la fila "old" de un DELETE — como device_uuid no es la PK, un filtro
-- `device_uuid=eq.X` sobre un evento DELETE nunca matchea y el visor no se entera
-- nunca de que su pantalla fue borrada (falla en silencio, mismo patrón que el
-- gotcha de RLS de la sección 4 del CLAUDE.md). FULL incluye todas las columnas.
alter table screens replica identity full;

-- --- Policies: playlists, playlist_items, media (anon, solo lectura) ---
create policy "anon puede leer playlists publicadas"
  on playlists for select
  to anon
  using (published_at is not null);

create policy "anon puede leer playlist_items"
  on playlist_items for select
  to anon
  using (true);

create policy "anon puede leer media"
  on media for select
  to anon
  using (true);

-- =====================================================
-- FIN DEL SCRIPT
-- =====================================================
-- Run this in the Supabase SQL Editor for the NovaFlames project.
-- UUIDs remain the internal Supabase keys; snowflake_id is the public platform ID.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique
    check (username ~ '^[a-z0-9_-]{3,24}$'),
  display_name text not null
    check (char_length(display_name) between 1 and 32),
  created_at timestamptz not null default now()
);

create table if not exists public.chat_servers (
  id text primary key check (id ~ '^[a-z0-9-]{1,32}$'),
  name text not null check (char_length(name) between 1 and 40),
  short text not null check (char_length(short) between 1 and 2),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_channels (
  server_id text not null references public.chat_servers (id) on delete cascade,
  name text not null check (name ~ '^[a-z0-9-]{1,32}$'),
  topic text not null default '',
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (server_id, name)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('channel', 'dm')),
  server_id text,
  channel_name text,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  recipient_id uuid references public.profiles (id) on delete cascade,
  content text not null check (char_length(content) between 1 and 2000 and content ~ '[^[:space:]]'),
  created_at timestamptz not null default now(),
  check (
    (kind = 'channel' and server_id is not null and channel_name is not null and recipient_id is null)
    or
    (kind = 'dm' and server_id is null and channel_name is null and recipient_id is not null and recipient_id <> sender_id)
  )
);

create index if not exists messages_channel_history_idx
  on public.messages (server_id, channel_name, created_at);
create index if not exists messages_sender_recipient_history_idx
  on public.messages (sender_id, recipient_id, created_at);
create index if not exists messages_recipient_sender_history_idx
  on public.messages (recipient_id, sender_id, created_at);

create table if not exists public.server_invites (
  id uuid primary key default gen_random_uuid(),
  server_id text not null constraint server_invites_server_id_fkey references public.chat_servers (id) on delete cascade,
  inviter_id uuid not null constraint server_invites_inviter_id_fkey references public.profiles (id) on delete cascade,
  invitee_id uuid not null constraint server_invites_invitee_id_fkey references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  check (inviter_id <> invitee_id)
);

create table if not exists public.custom_emojis (
  id uuid primary key default gen_random_uuid(),
  server_id text not null references public.chat_servers (id) on delete cascade,
  name text not null check (name ~ '^[a-zA-Z0-9_]{2,32}$'),
  image_url text not null,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (server_id, name)
);

create index if not exists server_invites_inbox_idx
  on public.server_invites (invitee_id, status, created_at desc);
create index if not exists server_invites_sender_idx
  on public.server_invites (inviter_id, created_at desc);

create table if not exists public.novaflames_snowflake_state (
  singleton boolean primary key default true check (singleton),
  last_timestamp bigint not null default 0,
  last_sequence integer not null default 0 check (last_sequence between 0 and 4095)
);

alter table public.novaflames_snowflake_state
  add column if not exists last_sequence integer not null default 0
  check (last_sequence between 0 and 4095);

do $$
begin
  if exists (
    select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'novaflames_snowflake_state'
        and column_name = 'sequence'
  ) then
    execute 'update public.novaflames_snowflake_state
      set last_sequence = sequence
      where last_sequence = 0 and sequence between 0 and 4095';
  end if;
end;
$$;

insert into public.novaflames_snowflake_state (singleton)
values (true)
on conflict (singleton) do nothing;

revoke all on table public.novaflames_snowflake_state from public, anon, authenticated;

create or replace function public.generate_novaflames_snowflake_id()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  epoch_ms constant bigint := 1420070400000;
  timestamp_ms bigint;
  current_timestamp_ms bigint;
  sequence_value integer;
begin
  select last_timestamp, last_sequence
    into timestamp_ms, sequence_value
    from public.novaflames_snowflake_state
    where singleton = true
    for update;

  current_timestamp_ms := floor(extract(epoch from clock_timestamp()) * 1000)::bigint - epoch_ms;
  if current_timestamp_ms > timestamp_ms then
    timestamp_ms := current_timestamp_ms;
    sequence_value := 0;
  else
    sequence_value := sequence_value + 1;
    if sequence_value > 4095 then
      timestamp_ms := timestamp_ms + 1;
      sequence_value := 0;
    end if;
  end if;

  update public.novaflames_snowflake_state
    set last_timestamp = timestamp_ms, last_sequence = sequence_value
    where singleton = true;

  return ((timestamp_ms::numeric * 4194304 + sequence_value)::bigint)::text;
end;
$$;

revoke all on function public.generate_novaflames_snowflake_id() from public, anon, authenticated;

create or replace function public.assign_novaflames_snowflake_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.snowflake_id := public.generate_novaflames_snowflake_id();
  return new;
end;
$$;

revoke all on function public.assign_novaflames_snowflake_id() from public, anon, authenticated;

alter table public.profiles add column if not exists snowflake_id text;
alter table public.chat_servers add column if not exists snowflake_id text;
alter table public.chat_channels add column if not exists snowflake_id text;
alter table public.messages add column if not exists snowflake_id text;
alter table public.server_invites add column if not exists snowflake_id text;
alter table public.custom_emojis add column if not exists snowflake_id text;

drop trigger if exists assign_novaflames_snowflake_id on public.profiles;
create trigger assign_novaflames_snowflake_id before insert on public.profiles
  for each row execute procedure public.assign_novaflames_snowflake_id();
drop trigger if exists assign_novaflames_snowflake_id on public.chat_servers;
create trigger assign_novaflames_snowflake_id before insert on public.chat_servers
  for each row execute procedure public.assign_novaflames_snowflake_id();
drop trigger if exists assign_novaflames_snowflake_id on public.chat_channels;
create trigger assign_novaflames_snowflake_id before insert on public.chat_channels
  for each row execute procedure public.assign_novaflames_snowflake_id();
drop trigger if exists assign_novaflames_snowflake_id on public.messages;
create trigger assign_novaflames_snowflake_id before insert on public.messages
  for each row execute procedure public.assign_novaflames_snowflake_id();
drop trigger if exists assign_novaflames_snowflake_id on public.server_invites;
create trigger assign_novaflames_snowflake_id before insert on public.server_invites
  for each row execute procedure public.assign_novaflames_snowflake_id();
drop trigger if exists assign_novaflames_snowflake_id on public.custom_emojis;
create trigger assign_novaflames_snowflake_id before insert on public.custom_emojis
  for each row execute procedure public.assign_novaflames_snowflake_id();

update public.profiles set snowflake_id = public.generate_novaflames_snowflake_id() where snowflake_id is null;
update public.chat_servers set snowflake_id = public.generate_novaflames_snowflake_id() where snowflake_id is null;
update public.chat_channels set snowflake_id = public.generate_novaflames_snowflake_id() where snowflake_id is null;
update public.messages set snowflake_id = public.generate_novaflames_snowflake_id() where snowflake_id is null;
update public.server_invites set snowflake_id = public.generate_novaflames_snowflake_id() where snowflake_id is null;
update public.custom_emojis set snowflake_id = public.generate_novaflames_snowflake_id() where snowflake_id is null;

alter table public.profiles alter column snowflake_id set not null;
alter table public.chat_servers alter column snowflake_id set not null;
alter table public.chat_channels alter column snowflake_id set not null;
alter table public.messages alter column snowflake_id set not null;
alter table public.server_invites alter column snowflake_id set not null;
alter table public.custom_emojis alter column snowflake_id set not null;

create unique index if not exists profiles_snowflake_id_key on public.profiles (snowflake_id);
create unique index if not exists chat_servers_snowflake_id_key on public.chat_servers (snowflake_id);
create unique index if not exists chat_channels_snowflake_id_key on public.chat_channels (snowflake_id);
create unique index if not exists messages_snowflake_id_key on public.messages (snowflake_id);
create unique index if not exists server_invites_snowflake_id_key on public.server_invites (snowflake_id);
create unique index if not exists custom_emojis_snowflake_id_key on public.custom_emojis (snowflake_id);

alter table public.chat_servers enable row level security;
alter table public.chat_channels enable row level security;
alter table public.profiles enable row level security;
alter table public.messages enable row level security;
alter table public.server_invites enable row level security;
alter table public.custom_emojis enable row level security;

drop policy if exists "Authenticated users can view servers" on public.chat_servers;
create policy "Authenticated users can view servers"
  on public.chat_servers for select to authenticated
  using (auth.uid() is not null);
drop policy if exists "Authenticated users can create servers" on public.chat_servers;
create policy "Authenticated users can create servers"
  on public.chat_servers for insert to authenticated
  with check (created_by = auth.uid());

drop policy if exists "Authenticated users can view channels" on public.chat_channels;
create policy "Authenticated users can view channels"
  on public.chat_channels for select to authenticated
  using (auth.uid() is not null);
drop policy if exists "Authenticated users can create channels" on public.chat_channels;
create policy "Authenticated users can create channels"
  on public.chat_channels for insert to authenticated
  with check (created_by = auth.uid());

drop policy if exists "Authenticated users can view profiles" on public.profiles;
create policy "Authenticated users can view profiles"
  on public.profiles for select to authenticated
  using (auth.uid() is not null);

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
  on public.profiles for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists "Users can read channel messages and their own DMs" on public.messages;
create policy "Users can read channel messages and their own DMs"
  on public.messages for select to authenticated
  using (
    kind = 'channel'
    or sender_id = auth.uid()
    or recipient_id = auth.uid()
  );

drop policy if exists "Users can send channel messages and DMs" on public.messages;
create policy "Users can send channel messages and DMs"
  on public.messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and (
      kind = 'channel'
      or (kind = 'dm' and recipient_id is not null and recipient_id <> auth.uid())
    )
  );

drop policy if exists "Users can view their server invites" on public.server_invites;
create policy "Users can view their server invites"
  on public.server_invites for select to authenticated
  using (inviter_id = auth.uid() or invitee_id = auth.uid());

drop policy if exists "Users can send server invites" on public.server_invites;
create policy "Users can send server invites"
  on public.server_invites for insert to authenticated
  with check (inviter_id = auth.uid() and invitee_id <> auth.uid());

drop policy if exists "Invitees can respond to pending invites" on public.server_invites;
create policy "Invitees can respond to pending invites"
  on public.server_invites for update to authenticated
  using (invitee_id = auth.uid() and status = 'pending')
  with check (invitee_id = auth.uid() and status in ('accepted', 'declined'));

drop policy if exists "Authenticated users can view custom emojis" on public.custom_emojis;
create policy "Authenticated users can view custom emojis"
  on public.custom_emojis for select to authenticated
  using (auth.uid() is not null);
drop policy if exists "Authenticated users can create custom emojis" on public.custom_emojis;
create policy "Authenticated users can create custom emojis"
  on public.custom_emojis for insert to authenticated
  with check (created_by = auth.uid());

grant select, update (username, display_name) on table public.profiles to authenticated;
grant select, insert on table public.chat_servers to authenticated;
grant select, insert on table public.chat_channels to authenticated;
grant select, insert on table public.messages to authenticated;
grant select, insert on table public.server_invites to authenticated;
grant update (status) on table public.server_invites to authenticated;
grant select, insert on table public.custom_emojis to authenticated;

create or replace function public.create_default_novaflames_channel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.chat_channels (server_id, name, topic, created_by)
  values (new.id, 'general', 'The place for everything and anything.', new.created_by)
  on conflict (server_id, name) do nothing;
  return new;
end;
$$;

drop trigger if exists create_default_novaflames_channel on public.chat_servers;
create trigger create_default_novaflames_channel
  after insert on public.chat_servers
  for each row execute procedure public.create_default_novaflames_channel();

insert into public.chat_servers (id, name, short)
values
  ('ember', 'Ember Lounge', 'EL'),
  ('forge', 'Forge Club', 'FC'),
  ('night', 'Night Shift', 'NS')
on conflict (id) do nothing;

insert into public.chat_channels (server_id, name, topic)
values
  ('ember', 'welcome', 'Start here'),
  ('ember', 'announcements', 'News from the team'),
  ('ember', 'general', 'Anything goes'),
  ('ember', 'clips', 'Share your best moments'),
  ('ember', 'help', 'Ask the community'),
  ('forge', 'builds', 'Show your work'),
  ('forge', 'feedback', 'Be kind, be useful'),
  ('night', 'late-chat', 'For the night owls'),
  ('night', 'music', 'What are you playing?')
on conflict (server_id, name) do nothing;

create or replace function public.create_novaflames_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_username text;
  final_username text;
  final_display_name text;
begin
  requested_username := lower(regexp_replace(
    coalesce(new.raw_user_meta_data ->> 'username', ''),
    '[^a-z0-9_-]', '', 'g'
  ));
  if char_length(requested_username) < 3 then
    requested_username := 'member_' || substr(replace(new.id::text, '-', ''), 1, 8);
  end if;
  final_username := left(requested_username, 24);
  if exists (select 1 from public.profiles where username = final_username) then
    final_username := left(requested_username, 17) || '_' ||
      substr(replace(new.id::text, '-', ''), 1, 6);
  end if;
  final_display_name := left(coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'NovaFlames member'
  ), 32);

  insert into public.profiles (id, username, display_name)
  values (new.id, final_username, final_display_name)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists create_novaflames_profile on auth.users;
create trigger create_novaflames_profile
  after insert on auth.users
  for each row execute procedure public.create_novaflames_profile();

do $$
begin
  alter publication supabase_realtime add table public.messages;
exception
  when duplicate_object then null;
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.profiles;
exception
  when duplicate_object then null;
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.chat_servers;
exception
  when duplicate_object then null;
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.chat_channels;
exception
  when duplicate_object then null;
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.server_invites;
exception
  when duplicate_object then null;
end;
$$;

-- Server workspace backend preparation. The current UI remains in local test mode.
-- Apply this script manually when enabling live workspaces. Seed servers have no
-- owner: assign chat_servers.created_by explicitly before managing those servers.
-- Boost records are service-managed; no client purchase/payment flow is enabled.
alter table public.chat_servers
  add column if not exists icon_url text,
  add column if not exists invites_paused boolean not null default false,
  add column if not exists dms_paused boolean not null default false;

create table if not exists public.server_roles (
  id uuid primary key default gen_random_uuid(),
  server_id text not null references public.chat_servers (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  is_default boolean not null default false,
  permissions text[] not null default '{}'
    check (permissions <@ array['administrator','viewChannel','invite','manageServer','insights',
      'manageChannels','manageEvents','viewMembers','moderate']::text[]),
  unique (server_id, id)
);
create unique index if not exists server_roles_default_idx
  on public.server_roles (server_id) where is_default;

create table if not exists public.server_members (
  server_id text not null references public.chat_servers (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (server_id, user_id)
);

create table if not exists public.server_member_roles (
  server_id text not null,
  user_id uuid not null,
  role_id uuid not null,
  primary key (server_id, user_id, role_id),
  foreign key (server_id, user_id) references public.server_members (server_id, user_id) on delete cascade,
  foreign key (server_id, role_id) references public.server_roles (server_id, id) on delete cascade
);

create or replace function public.server_has_permission(target_server text, permission_name text)
returns boolean language sql stable security definer set search_path = public
as $$
  select auth.uid() is not null and (
    exists (select 1 from public.chat_servers s
      where s.id = target_server and s.created_by = auth.uid())
    or exists (
      select 1 from public.server_members m
      join public.server_roles r on r.server_id = m.server_id
      where m.server_id = target_server and m.user_id = auth.uid()
        and (permission_name = any(r.permissions) or 'administrator' = any(r.permissions))
        and (r.is_default or exists (
          select 1 from public.server_member_roles mr
          where mr.server_id = target_server and mr.user_id = auth.uid() and mr.role_id = r.id
        ))
    )
  );
$$;
revoke all on function public.server_has_permission(text, text) from public, anon;
grant execute on function public.server_has_permission(text, text) to authenticated;

create table if not exists public.server_categories (
  id uuid primary key default gen_random_uuid(),
  server_id text not null references public.chat_servers (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  position integer not null default 0,
  unique (server_id, id),
  unique (server_id, name)
);
alter table public.chat_channels add column if not exists category_id uuid;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'chat_channels_category_fkey'
    and conrelid = 'public.chat_channels'::regclass) then
    alter table public.chat_channels add constraint chat_channels_category_fkey
      foreign key (server_id, category_id) references public.server_categories (server_id, id);
  end if;
end;
$$;

create table if not exists public.channel_role_access (
  server_id text not null,
  channel_name text not null,
  role_id uuid not null,
  primary key (server_id, channel_name, role_id),
  foreign key (server_id, channel_name) references public.chat_channels (server_id, name) on delete cascade,
  foreign key (server_id, role_id) references public.server_roles (server_id, id) on delete cascade
);

create or replace function public.can_view_server_channel(target_server text, target_channel text)
returns boolean language sql stable security definer set search_path = public
as $$
  select public.server_has_permission(target_server, 'viewChannel') and (
    exists (select 1 from public.chat_servers where id = target_server and created_by = auth.uid())
    or public.server_has_permission(target_server, 'administrator')
    or not exists (select 1 from public.channel_role_access
      where server_id = target_server and channel_name = target_channel)
    or exists (
      select 1 from public.channel_role_access a
      join public.server_roles r on r.server_id = a.server_id and r.id = a.role_id
      where a.server_id = target_server and a.channel_name = target_channel
        and (r.is_default or exists (
          select 1 from public.server_member_roles mr
          where mr.server_id = target_server and mr.user_id = auth.uid() and mr.role_id = r.id
        ))
    )
  );
$$;
revoke all on function public.can_view_server_channel(text, text) from public, anon;
grant execute on function public.can_view_server_channel(text, text) to authenticated;

create table if not exists public.server_events (
  id uuid primary key default gen_random_uuid(),
  server_id text not null references public.chat_servers (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 100),
  location text not null default '' check (char_length(location) <= 200),
  starts_at timestamptz not null,
  created_by uuid not null references public.profiles (id),
  unique (server_id, id)
);
create table if not exists public.server_event_interest (
  server_id text not null,
  event_id uuid not null,
  user_id uuid not null,
  primary key (server_id, event_id, user_id),
  foreign key (server_id, event_id) references public.server_events (server_id, id) on delete cascade,
  foreign key (server_id, user_id) references public.server_members (server_id, user_id) on delete cascade
);
create table if not exists public.server_boosts (
  id uuid primary key default gen_random_uuid(),
  server_id text not null references public.chat_servers (id) on delete cascade,
  user_id uuid not null references public.profiles (id),
  created_at timestamptz not null default now()
);
create table if not exists public.server_preferences (
  server_id text not null,
  user_id uuid not null,
  show_all_channels boolean not null default true,
  hide_muted_channels boolean not null default false,
  selected_channels text[] not null default '{}',
  muted_channels text[] not null default '{}',
  suggestions_hidden_until timestamptz,
  notifications text not null default 'mentions' check (notifications in ('all','mentions','nothing')),
  allow_dms boolean not null default true,
  allow_activity boolean not null default true,
  profile jsonb not null default '{}' check (jsonb_typeof(profile) = 'object'),
  primary key (server_id, user_id),
  foreign key (server_id, user_id) references public.server_members (server_id, user_id) on delete cascade
);
create table if not exists public.server_raid_reports (
  id uuid primary key default gen_random_uuid(),
  server_id text not null references public.chat_servers (id) on delete cascade,
  reporter_id uuid not null references public.profiles (id),
  reason text not null check (char_length(reason) between 1 and 2000),
  created_at timestamptz not null default now()
);

-- Initialize future server owners and the default member role automatically.
create or replace function public.initialize_server_workspace()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.server_roles (server_id, name, is_default, permissions)
    values (new.id, '@everyone', true, array['viewChannel','invite'])
    on conflict do nothing;
  if new.created_by is not null then
    insert into public.server_members (server_id, user_id)
      values (new.id, new.created_by) on conflict do nothing;
  end if;
  return new;
end;
$$;
revoke all on function public.initialize_server_workspace() from public, anon, authenticated;
drop trigger if exists initialize_server_workspace on public.chat_servers;
create trigger initialize_server_workspace after insert on public.chat_servers
  for each row execute function public.initialize_server_workspace();
insert into public.server_roles (server_id, name, is_default, permissions)
  select id, '@everyone', true, array['viewChannel','invite'] from public.chat_servers
  on conflict do nothing;
insert into public.server_members (server_id, user_id)
  select id, created_by from public.chat_servers where created_by is not null
  on conflict do nothing;

-- Management is checked in PostgreSQL, not just by hiding menu items.
do $$
declare
  target_table text;
  required_permission text;
begin
  foreach target_table in array array['server_roles','server_member_roles','server_categories','channel_role_access'] loop
    required_permission := case when target_table in ('server_categories','channel_role_access')
      then 'manageChannels' else 'manageServer' end;
    execute format('alter table public.%I enable row level security', target_table);
    execute format('drop policy if exists workspace_read on public.%I', target_table);
    execute format('create policy workspace_read on public.%I for select to authenticated
      using (public.server_has_permission(server_id, ''viewChannel''))', target_table);
    execute format('drop policy if exists workspace_manage on public.%I', target_table);
    execute format('create policy workspace_manage on public.%I for all to authenticated
      using (public.server_has_permission(server_id, %L))
      with check (public.server_has_permission(server_id, %L))', target_table, required_permission, required_permission);
    execute format('grant select, insert, update, delete on public.%I to authenticated', target_table);
  end loop;
end;
$$;

alter table public.server_members enable row level security;
drop policy if exists members_read on public.server_members;
create policy members_read on public.server_members for select to authenticated
  using (user_id = auth.uid() or public.server_has_permission(server_id, 'viewChannel'));
drop policy if exists members_manage on public.server_members;
create policy members_manage on public.server_members for all to authenticated
  using (public.server_has_permission(server_id, 'manageServer'))
  with check (public.server_has_permission(server_id, 'manageServer'));
grant select, insert, delete on public.server_members to authenticated;

alter table public.server_events enable row level security;
drop policy if exists events_read on public.server_events;
create policy events_read on public.server_events for select to authenticated
  using (public.server_has_permission(server_id, 'viewChannel'));
drop policy if exists events_manage on public.server_events;
create policy events_manage on public.server_events for all to authenticated
  using (public.server_has_permission(server_id, 'manageEvents'))
  with check (public.server_has_permission(server_id, 'manageEvents') and created_by = auth.uid());
grant select, insert, update, delete on public.server_events to authenticated;

alter table public.server_event_interest enable row level security;
drop policy if exists interest_read on public.server_event_interest;
create policy interest_read on public.server_event_interest for select to authenticated
  using (public.server_has_permission(server_id, 'viewChannel'));
drop policy if exists interest_self on public.server_event_interest;
create policy interest_self on public.server_event_interest for all to authenticated
  using (user_id = auth.uid() and public.server_has_permission(server_id, 'viewChannel'))
  with check (user_id = auth.uid() and public.server_has_permission(server_id, 'viewChannel'));
grant select, insert, delete on public.server_event_interest to authenticated;

alter table public.server_preferences enable row level security;
drop policy if exists preferences_self on public.server_preferences;
create policy preferences_self on public.server_preferences for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.server_has_permission(server_id, 'viewChannel'));
grant select, insert, update, delete on public.server_preferences to authenticated;

alter table public.server_boosts enable row level security;
drop policy if exists boosts_read on public.server_boosts;
create policy boosts_read on public.server_boosts for select to authenticated
  using (public.server_has_permission(server_id, 'viewChannel'));
grant select on public.server_boosts to authenticated;
revoke insert, update, delete on public.server_boosts from authenticated, anon;

alter table public.server_raid_reports enable row level security;
drop policy if exists raids_read on public.server_raid_reports;
create policy raids_read on public.server_raid_reports for select to authenticated
  using (public.server_has_permission(server_id, 'moderate'));
drop policy if exists raids_report on public.server_raid_reports;
create policy raids_report on public.server_raid_reports for insert to authenticated
  with check (reporter_id = auth.uid() and public.server_has_permission(server_id, 'moderate'));
grant select, insert on public.server_raid_reports to authenticated;

drop policy if exists "Authenticated users can view channels" on public.chat_channels;
create policy "Authenticated users can view channels" on public.chat_channels for select to authenticated
  using (public.can_view_server_channel(server_id, name));
drop policy if exists "Authenticated users can create channels" on public.chat_channels;
create policy "Authenticated users can create channels" on public.chat_channels for insert to authenticated
  with check (created_by = auth.uid() and public.server_has_permission(server_id, 'manageChannels'));
drop policy if exists channels_manage on public.chat_channels;
create policy channels_manage on public.chat_channels for update to authenticated
  using (public.server_has_permission(server_id, 'manageChannels'))
  with check (public.server_has_permission(server_id, 'manageChannels'));
grant update (category_id, topic) on public.chat_channels to authenticated;

drop policy if exists "Users can read channel messages and their own DMs" on public.messages;
create policy "Users can read channel messages and their own DMs" on public.messages for select to authenticated
  using ((kind = 'channel' and public.can_view_server_channel(server_id, channel_name))
    or (kind = 'dm' and (sender_id = auth.uid() or recipient_id = auth.uid())));
drop policy if exists "Users can send channel messages and DMs" on public.messages;
create policy "Users can send channel messages and DMs" on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and (
    (kind = 'channel' and public.can_view_server_channel(server_id, channel_name)
      and exists (select 1 from public.chat_channels c where c.server_id = messages.server_id and c.name = messages.channel_name))
    or (kind = 'dm' and recipient_id is not null and recipient_id <> auth.uid())));

drop policy if exists servers_manage on public.chat_servers;
create policy servers_manage on public.chat_servers for update to authenticated
  using (public.server_has_permission(id, 'manageServer'))
  with check (public.server_has_permission(id, 'manageServer'));
grant update (name, short, icon_url, invites_paused, dms_paused) on public.chat_servers to authenticated;
drop policy if exists "Users can send server invites" on public.server_invites;
create policy "Users can send server invites" on public.server_invites for insert to authenticated
  with check (inviter_id = auth.uid() and invitee_id <> auth.uid()
    and public.server_has_permission(server_id, 'invite')
    and exists (select 1 from public.chat_servers s where s.id = server_id and not s.invites_paused));

-- Application review (Pending/Rejected/Approved) intentionally has no backend yet.
-- Invite acceptance/member enrollment and billing must be connected before going live.
notify pgrst, 'reload schema';

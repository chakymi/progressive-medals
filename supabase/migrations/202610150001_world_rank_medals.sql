begin;

-- Independent of RankUp tables. Execute once in a Supabase project owned by the publisher.
create table if not exists public.map_medals (
  map_uid text primary key check (map_uid ~ '^[A-Za-z0-9_]{20,40}$'),
  map_name text not null check (length(map_name) between 1 and 160),
  map_type text not null check (map_type in ('campaign', 'totd')),
  release_at timestamptz not null,
  status text not null default 'waiting_initial_delay' check (status in (
    'waiting_initial_delay', 'waiting_for_players', 'waiting_extra_hour',
    'ready_to_capture', 'retry_pending', 'published')),
  resume_status text check (resume_status in (
    'waiting_initial_delay', 'waiting_for_players', 'waiting_extra_hour', 'ready_to_capture')),
  eligible_at timestamptz not null,
  threshold_detected_at timestamptz,
  capture_due_at timestamptz,
  checked_at timestamptz,
  player_count integer check (player_count >= 0),
  captured_at timestamptz,
  published_at timestamptz,
  platinum_ms integer check (platinum_ms between 1 and 86400000),
  emerald_ms integer check (emerald_ms between 1 and 86400000),
  diamond_ms integer check (diamond_ms between 1 and 86400000),
  reference_wr_ms integer check (reference_wr_ms between 1 and 86400000),
  calculation_version integer not null default 5 check (calculation_version = 5),
  data_source text,
  capture_evidence jsonb,
  retry_at timestamptz,
  last_error text,
  constraint pm_complete_publication check (
    (status = 'published') = (platinum_ms is not null)
    and (platinum_ms is null and emerald_ms is null and diamond_ms is null and
         captured_at is null and published_at is null and reference_wr_ms is null and capture_evidence is null
      or platinum_ms is not null and emerald_ms is not null and diamond_ms is not null and
         captured_at is not null and published_at is not null and reference_wr_ms is not null and capture_evidence is not null and
         reference_wr_ms <= diamond_ms and diamond_ms <= emerald_ms and emerald_ms <= platinum_ms and
         player_count >= 5000 and threshold_detected_at is not null and capture_due_at is not null and
         captured_at >= capture_due_at and published_at >= captured_at)
  ),
  constraint pm_retry_state check ((status = 'retry_pending') = (resume_status is not null)),
  constraint pm_due_after_threshold check (capture_due_at is null or
    (threshold_detected_at is not null and capture_due_at =
      case when threshold_detected_at <= eligible_at then eligible_at
           else threshold_detected_at + interval '1 hour' end)),
  constraint pm_release_delay check (eligible_at = release_at +
    case when map_type = 'campaign' then interval '7 days' else interval '1 hour' end)
);

alter table public.map_medals enable row level security;
revoke all on public.map_medals from public, anon, authenticated;
-- The REST publisher runs under service_role. The public reads ONLY a curated RPC below.

create table if not exists public.pm_catalog_state (
  singleton boolean primary key default true check (singleton),
  revision integer not null default 5 check (revision between 5 and 2000000000)
);
insert into public.pm_catalog_state(singleton) values (true) on conflict do nothing;
alter table public.pm_catalog_state enable row level security;
revoke all on public.pm_catalog_state from public, anon, authenticated;

create or replace function public.pm_advance_revision() returns trigger
language plpgsql set search_path = '' as $$
begin
  update public.pm_catalog_state set revision = revision + 1 where singleton = true;
  return new;
end;
$$;
drop trigger if exists pm_revision on public.map_medals;
create trigger pm_revision after insert or update on public.map_medals
for each row execute function public.pm_advance_revision();

create index if not exists pm_pending_checks on public.map_medals (checked_at asc nulls first)
where status <> 'published';

create or replace function public.pm_lock_published() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.status = 'published' and (tg_op = 'DELETE' or new is distinct from old) then
    raise exception 'published medals are immutable';
  end if;
  return new;
end;
$$;
drop trigger if exists pm_immutable on public.map_medals;
create trigger pm_immutable before update or delete on public.map_medals
for each row execute function public.pm_lock_published();

create table if not exists public.map_medal_publications (
  map_uid text primary key references public.map_medals(map_uid),
  published_at timestamptz not null,
  snapshot jsonb not null
);
alter table public.map_medal_publications enable row level security;
revoke all on public.map_medal_publications from public, anon, authenticated;

create or replace function public.pm_lock_publication_log() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'publication log is append-only';
end;
$$;
drop trigger if exists pm_audit_immutable on public.map_medal_publications;
create trigger pm_audit_immutable before update or delete on public.map_medal_publications
for each row execute function public.pm_lock_publication_log();

create or replace function public.pm_register(uid text, title text, kind text, released timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.role() <> 'service_role' then raise exception 'publisher only'; end if;
  if uid !~ '^[A-Za-z0-9_]{20,40}$' or length(title) not between 1 and 160 or
     kind not in ('campaign', 'totd') or released is null or released > clock_timestamp() then
    raise exception 'invalid verified map registration';
  end if;
  insert into public.map_medals(map_uid, map_name, map_type, release_at, eligible_at)
  values (uid, title, kind, released, released +
    case when kind = 'campaign' then interval '7 days' else interval '1 hour' end)
  on conflict (map_uid) do nothing;
  if not exists(select 1 from public.map_medals where map_uid = uid and map_name = title and
    map_type = kind and release_at = released) then
    raise exception 'UID metadata conflict; no existing medals changed';
  end if;
end;
$$;

create or replace function public.pm_observe(uid text, players integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m public.map_medals%rowtype; at_time timestamptz := clock_timestamp(); active text;
begin
  if auth.role() <> 'service_role' then raise exception 'publisher only'; end if;
  if players is null or players < 0 then raise exception 'unverified player count'; end if;
  select * into m from public.map_medals where map_uid = uid for update;
  if not found then raise exception 'unregistered map'; end if;
  if m.status = 'published' then return jsonb_build_object('status', 'published'); end if;
  active := case when m.status = 'retry_pending' then m.resume_status else m.status end;
  m.checked_at := at_time;
  m.player_count := players;
  m.retry_at := null;
  m.last_error := null;
  m.resume_status := null;
  if players >= 5000 and m.threshold_detected_at is null then m.threshold_detected_at := at_time; end if;
  if at_time < m.eligible_at then
    m.status := 'waiting_initial_delay';
  elsif players < 5000 then
    m.status := 'waiting_for_players';
  else
    -- If the threshold was already observed before the first deadline, no extra hour.
    -- A first observation AFTER that deadline cannot be backdated.
    m.capture_due_at := case when m.threshold_detected_at <= m.eligible_at
      then m.eligible_at else m.threshold_detected_at + interval '1 hour' end;
    m.status := case when at_time >= m.capture_due_at then 'ready_to_capture' else 'waiting_extra_hour' end;
  end if;
  update public.map_medals set status = m.status, resume_status = null, checked_at = m.checked_at,
    player_count = m.player_count, threshold_detected_at = m.threshold_detected_at,
    capture_due_at = m.capture_due_at, retry_at = null, last_error = null where map_uid = uid;
  return jsonb_build_object('status', m.status, 'capture_due_at', m.capture_due_at);
end;
$$;

create or replace function public.pm_retry(uid text, reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare m public.map_medals%rowtype;
begin
  if auth.role() <> 'service_role' then raise exception 'publisher only'; end if;
  select * into m from public.map_medals where map_uid = uid for update;
  if not found or m.status = 'published' then return; end if;
  update public.map_medals set status = 'retry_pending',
    resume_status = case when m.status = 'retry_pending' then m.resume_status else m.status end,
    retry_at = clock_timestamp() + interval '15 minutes', last_error = left(coalesce(reason, 'supplier unavailable'), 120)
  where map_uid = uid;
end;
$$;

create or replace function public.pm_publish(uid text, platinum integer, emerald integer,
  diamond integer, wr integer, captured timestamptz, source text, evidence jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare m public.map_medals%rowtype; stamp timestamptz := clock_timestamp();
begin
  if auth.role() <> 'service_role' then raise exception 'publisher only'; end if;
  select * into m from public.map_medals where map_uid = uid for update;
  if not found then raise exception 'unregistered map'; end if;
  if m.status = 'published' then return false; end if; -- Idempotent, never overwrite.
  if m.status not in ('ready_to_capture', 'retry_pending') or
     (m.status = 'retry_pending' and m.resume_status <> 'ready_to_capture') or
     m.player_count < 5000 or m.capture_due_at is null or stamp < m.capture_due_at or
     captured < m.capture_due_at or captured > stamp + interval '2 minutes' or
     wr is null or diamond is null or emerald is null or platinum is null or
     not (1 <= wr and wr <= diamond and diamond <= emerald and emerald <= platinum and platinum <= 86400000) or
     source <> 'trackmania.io/world-map-leaderboard' or
     evidence is null or jsonb_typeof(evidence) <> 'object' then
    raise exception 'invalid or premature capture';
  end if;
  update public.map_medals set status = 'published', resume_status = null, retry_at = null,
    captured_at = captured, published_at = stamp,
    platinum_ms = platinum, emerald_ms = emerald, diamond_ms = diamond, reference_wr_ms = wr,
    data_source = source, capture_evidence = evidence, last_error = null where map_uid = uid;
  insert into public.map_medal_publications(map_uid, published_at, snapshot)
  values (uid, stamp, jsonb_build_object('platinumMs', platinum, 'emeraldMs', emerald,
    'diamondMs', diamond, 'wrMs', wr, 'capturedAt', captured, 'evidence', evidence));
  return true;
end;
$$;

-- Only metadata and published goals; no retry logs, account identifiers or raw supplier payload.
create or replace function public.pm_public_catalog()
returns jsonb language sql security definer set search_path = '' stable as $$
  select jsonb_build_object('schema', 3, 'version', (select revision from public.pm_catalog_state where singleton = true), 'maps', coalesce(jsonb_object_agg(map_uid,
    jsonb_build_object('name', map_name, 'mapType', map_type, 'releaseAtUtc', extract(epoch from release_at)::bigint,
      'status', case when status = 'retry_pending' then 'temporarily_unavailable' else status end,
      'eligibleAtUtc', extract(epoch from eligible_at)::bigint,
      'thresholdDetectedAtUtc', case when threshold_detected_at is null then null else extract(epoch from threshold_detected_at)::bigint end,
      'captureDueAtUtc', case when capture_due_at is null then null else extract(epoch from capture_due_at)::bigint end,
      'capturedAtUtc', case when captured_at is null then null else extract(epoch from captured_at)::bigint end,
      'publishedAtUtc', case when published_at is null then null else extract(epoch from published_at)::bigint end,
      'playerCount', player_count, 'calculationVersion', calculation_version,
      'authorMs', null, 'referenceWrMs', reference_wr_ms,
      'timesMs', case when status = 'published' then jsonb_build_array(platinum_ms, emerald_ms, diamond_ms) else null end,
      'source', data_source)), '{}'::jsonb))
  from public.map_medals;
$$;

revoke all on function public.pm_register(text, text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.pm_observe(text, integer) from public, anon, authenticated;
revoke all on function public.pm_retry(text, text) from public, anon, authenticated;
revoke all on function public.pm_publish(text, integer, integer, integer, integer, timestamptz, text, jsonb) from public, anon, authenticated;
revoke all on function public.pm_public_catalog() from public, anon, authenticated;
grant execute on function public.pm_register(text, text, text, timestamptz) to service_role;
grant execute on function public.pm_observe(text, integer) to service_role;
grant execute on function public.pm_retry(text, text) to service_role;
grant execute on function public.pm_publish(text, integer, integer, integer, integer, timestamptz, text, jsonb) to service_role;
grant execute on function public.pm_public_catalog() to anon, authenticated, service_role;
commit;

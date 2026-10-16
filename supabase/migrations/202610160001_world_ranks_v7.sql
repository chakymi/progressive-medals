begin;

-- Revision 7 publishes new exact ranks while preserving every immutable v5
-- Fall/TOTD row and its original append-only evidence. Do NOT replay old WRs.
create table public.pm_revised_medals (like public.map_medals including defaults);
alter table public.pm_revised_medals add primary key (map_uid);
alter table public.pm_revised_medals alter column calculation_version set default 7;
alter table public.pm_revised_medals add constraint pm7_uid check (map_uid ~ '^[A-Za-z0-9_]{20,40}$');
alter table public.pm_revised_medals add constraint pm7_name check (length(map_name) between 1 and 160);
alter table public.pm_revised_medals add constraint pm7_kind check (map_type in ('campaign', 'totd'));
alter table public.pm_revised_medals add constraint pm7_status check (status in (
  'waiting_initial_delay', 'waiting_for_players', 'waiting_extra_hour',
  'ready_to_capture', 'retry_pending', 'published'));
alter table public.pm_revised_medals add constraint pm7_resume_status check (resume_status is null or
  resume_status in ('waiting_initial_delay', 'waiting_for_players', 'waiting_extra_hour', 'ready_to_capture'));
alter table public.pm_revised_medals add constraint pm7_calc check (calculation_version = 7);
alter table public.pm_revised_medals add constraint pm7_players check (player_count is null or player_count >= 0);
alter table public.pm_revised_medals add constraint pm7_times check (
  (platinum_ms is null or platinum_ms between 1 and 86400000) and
  (emerald_ms is null or emerald_ms between 1 and 86400000) and
  (diamond_ms is null or diamond_ms between 1 and 86400000) and
  (reference_wr_ms is null or reference_wr_ms between 1 and 86400000));
alter table public.pm_revised_medals add constraint pm7_retry_state check
  ((status = 'retry_pending') = (resume_status is not null));
alter table public.pm_revised_medals add constraint pm7_release_delay check
  (eligible_at = release_at + case when map_type = 'campaign' then interval '7 days' else interval '1 hour' end);
alter table public.pm_revised_medals add constraint pm7_due check (capture_due_at is null or
  (threshold_detected_at is not null and capture_due_at =
   case when threshold_detected_at <= eligible_at then eligible_at else threshold_detected_at + interval '1 hour' end));
alter table public.pm_revised_medals add constraint pm7_complete check (
  (status = 'published') = (platinum_ms is not null) and
  (platinum_ms is null and emerald_ms is null and diamond_ms is null and
   captured_at is null and published_at is null and reference_wr_ms is null and capture_evidence is null or
   platinum_ms is not null and emerald_ms is not null and diamond_ms is not null and
   captured_at is not null and published_at is not null and reference_wr_ms is not null and capture_evidence is not null and
   reference_wr_ms <= diamond_ms and diamond_ms <= emerald_ms and emerald_ms <= platinum_ms and
   player_count >= 2500 and threshold_detected_at is not null and capture_due_at is not null and
   captured_at >= capture_due_at and published_at >= captured_at)
);
create index pm7_pending_checks on public.pm_revised_medals (checked_at asc nulls first) where status <> 'published';
alter table public.pm_revised_medals enable row level security;
revoke all on public.pm_revised_medals from public, anon, authenticated;
grant select, insert, update on public.pm_revised_medals to service_role;
create trigger pm7_immutable before update or delete on public.pm_revised_medals
for each row execute function public.pm_lock_published();
create trigger pm7_revision after insert or update on public.pm_revised_medals
for each row execute function public.pm_advance_revision();

create table public.pm_revised_medal_publications (
  map_uid text primary key references public.pm_revised_medals(map_uid),
  published_at timestamptz not null,
  snapshot jsonb not null
);
alter table public.pm_revised_medal_publications enable row level security;
revoke all on public.pm_revised_medal_publications from public, anon, authenticated;
grant select on public.pm_revised_medal_publications to service_role;
create trigger pm7_audit_immutable before update or delete on public.pm_revised_medal_publications
for each row execute function public.pm_lock_publication_log();

create function public.pm7_register(uid text, title text, kind text, released timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.role() <> 'service_role' then raise exception 'publisher only'; end if;
  if uid !~ '^[A-Za-z0-9_]{20,40}$' or length(title) not between 1 and 160 or
     kind not in ('campaign', 'totd') or released is null or released > clock_timestamp() then
    raise exception 'invalid verified map registration';
  end if;
  insert into public.pm_revised_medals(map_uid, map_name, map_type, release_at, eligible_at, calculation_version)
  values (uid, title, kind, released,
    released + case when kind = 'campaign' then interval '7 days' else interval '1 hour' end, 7)
  on conflict (map_uid) do nothing;
  if not exists(select 1 from public.pm_revised_medals where map_uid = uid and
    map_name = title and map_type = kind and release_at = released and calculation_version = 7) then
    raise exception 'UID metadata conflict';
  end if;
end;
$$;

create function public.pm7_observe(uid text, players integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m public.pm_revised_medals%rowtype; at_time timestamptz := clock_timestamp();
begin
  if auth.role() <> 'service_role' then raise exception 'publisher only'; end if;
  if players is null or players < 0 then raise exception 'unverified player count'; end if;
  select * into m from public.pm_revised_medals where map_uid = uid for update;
  if not found then raise exception 'unregistered map'; end if;
  if m.status = 'published' then return jsonb_build_object('status', 'published'); end if;
  m.checked_at := at_time;
  m.player_count := players;
  m.retry_at := null;
  m.last_error := null;
  m.resume_status := null;
  if players >= 2500 and m.threshold_detected_at is null then m.threshold_detected_at := at_time; end if;
  if at_time < m.eligible_at then
    m.status := 'waiting_initial_delay';
  elsif players < 2500 then
    m.status := 'waiting_for_players';
  else
    m.capture_due_at := case when m.threshold_detected_at <= m.eligible_at
      then m.eligible_at else m.threshold_detected_at + interval '1 hour' end;
    m.status := case when at_time >= m.capture_due_at then 'ready_to_capture' else 'waiting_extra_hour' end;
  end if;
  update public.pm_revised_medals set status = m.status, resume_status = null, checked_at = m.checked_at,
    player_count = m.player_count, threshold_detected_at = m.threshold_detected_at,
    capture_due_at = m.capture_due_at, retry_at = null, last_error = null where map_uid = uid;
  return jsonb_build_object('status', m.status, 'capture_due_at', m.capture_due_at);
end;
$$;

create function public.pm7_retry(uid text, reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare m public.pm_revised_medals%rowtype;
begin
  if auth.role() <> 'service_role' then raise exception 'publisher only'; end if;
  select * into m from public.pm_revised_medals where map_uid = uid for update;
  if not found or m.status = 'published' then return; end if;
  update public.pm_revised_medals set status = 'retry_pending',
    resume_status = case when m.status = 'retry_pending' then m.resume_status else m.status end,
    retry_at = clock_timestamp() + interval '15 minutes', last_error = left(coalesce(reason, 'supplier unavailable'), 120)
  where map_uid = uid;
end;
$$;

create function public.pm7_publish(uid text, platinum integer, emerald integer,
  diamond integer, wr integer, captured timestamptz, source text, evidence jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare m public.pm_revised_medals%rowtype; stamp timestamptz := clock_timestamp(); emerald_rank integer; diamond_rank integer;
begin
  if auth.role() <> 'service_role' then raise exception 'publisher only'; end if;
  select * into m from public.pm_revised_medals where map_uid = uid for update;
  if not found then raise exception 'unregistered map'; end if;
  if m.status = 'published' then return false; end if;
  emerald_rank := case when m.map_type = 'totd' then 500 else 1000 end;
  diamond_rank := case when m.map_type = 'totd' then 100 else 200 end;
  if m.status not in ('ready_to_capture', 'retry_pending') or
     (m.status = 'retry_pending' and m.resume_status <> 'ready_to_capture') or
     m.player_count < 2500 or m.capture_due_at is null or stamp < m.capture_due_at or
     captured < m.capture_due_at or captured > stamp + interval '2 minutes' or
     wr is null or diamond is null or emerald is null or platinum is null or
     not (1 <= wr and wr <= diamond and diamond <= emerald and emerald <= platinum and platinum <= 86400000) or
     source <> 'trackmania.io/world-map-leaderboard' or
     evidence is null or jsonb_typeof(evidence) <> 'object' or
     not (evidence ?& array['platinum', 'emerald', 'diamond', 'wr']) or
     evidence->'platinum'->>'position' is distinct from '2500' or
     evidence->'emerald'->>'position' is distinct from emerald_rank::text or
     evidence->'diamond'->>'position' is distinct from diamond_rank::text or
     evidence->'wr'->>'position' is distinct from '1' then
    raise exception 'invalid or premature capture';
  end if;
  update public.pm_revised_medals set status = 'published', resume_status = null, retry_at = null,
    captured_at = captured, published_at = stamp,
    platinum_ms = platinum, emerald_ms = emerald, diamond_ms = diamond, reference_wr_ms = wr,
    data_source = source, capture_evidence = evidence, last_error = null where map_uid = uid;
  insert into public.pm_revised_medal_publications(map_uid, published_at, snapshot)
  values (uid, stamp, jsonb_build_object('platinumMs', platinum, 'emeraldMs', emerald,
    'diamondMs', diamond, 'wrMs', wr, 'capturedAt', captured, 'evidence', evidence));
  return true;
end;
$$;

revoke all on function public.pm7_register(text, text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.pm7_observe(text, integer) from public, anon, authenticated;
revoke all on function public.pm7_retry(text, text) from public, anon, authenticated;
revoke all on function public.pm7_publish(text, integer, integer, integer, integer, timestamptz, text, jsonb) from public, anon, authenticated;
grant execute on function public.pm7_register(text, text, text, timestamptz) to service_role;
grant execute on function public.pm7_observe(text, integer) to service_role;
grant execute on function public.pm7_retry(text, text) to service_role;
grant execute on function public.pm7_publish(text, integer, integer, integer, integer, timestamptz, text, jsonb) to service_role;

-- Published v7 takes precedence. While being recaptured, the old frozen v5
-- remains visible. Never replace archived rows or expose private evidence.
create or replace function public.pm_public_catalog()
returns jsonb language sql security definer set search_path = '' stable as $$
  with selected as (
    select r.* from public.pm_revised_medals r where r.status = 'published'
    union all
    select old.* from public.map_medals old where not exists (
      select 1 from public.pm_revised_medals r where r.map_uid = old.map_uid and r.status = 'published')
    union all
    select r.* from public.pm_revised_medals r where r.status <> 'published' and not exists (
      select 1 from public.map_medals old where old.map_uid = r.map_uid)
  )
  select jsonb_build_object('schema', 3, 'version', (select revision from public.pm_catalog_state where singleton = true),
    'maps', coalesce(jsonb_object_agg(map_uid,
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
  from selected;
$$;
revoke all on function public.pm_public_catalog() from public, anon, authenticated;
grant execute on function public.pm_public_catalog() to anon, authenticated, service_role;
commit;

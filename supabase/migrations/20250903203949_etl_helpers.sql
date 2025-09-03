-- =========================================================
-- ETL HELPERS (provider-agnostic upserts + external ID mapping)
-- Target schema: initial_schema.sql
-- =========================================================

-- 1) Resolve or create a provider by code (e.g., 'sleeper')
create or replace function public.ensure_provider(
  p_code text,
  p_name text default null,
  p_meta jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  select id into v_id from providers where code = p_code;
  if v_id is null then
    insert into providers(code, name, meta)
    values (p_code, coalesce(p_name, initcap(p_code)), coalesce(p_meta, '{}'::jsonb))
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- 2) Upsert a mapping row provider/entity/external_id -> internal_id
create or replace function public.link_external_id(
  p_provider_code text,
  p_entity entity_t,
  p_external_id text,
  p_internal_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_provider_id uuid;
begin
  v_provider_id := public.ensure_provider(p_provider_code);
  insert into external_ids(provider_id, entity_type, external_id, internal_id)
  values (v_provider_id, p_entity, p_external_id, p_internal_id)
  on conflict (provider_id, entity_type, external_id)
  do update set internal_id = excluded.internal_id;
end $$;

-- 3) Resolve internal_id for a given external id
create or replace function public.resolve_internal_id(
  p_provider_code text,
  p_entity entity_t,
  p_external_id text
) returns uuid
language sql
stable
set search_path = public
as $$
  select ei.internal_id
  from external_ids ei
  join providers pr on pr.id = ei.provider_id
  where pr.code = p_provider_code
    and ei.entity_type = p_entity
    and ei.external_id = p_external_id
$$;

-- 4) Ensure a TEAM by code
create or replace function public.ensure_team(
  p_code text,
  p_name text,
  p_meta jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  select id into v_id from teams where code = p_code;
  if v_id is null then
    insert into teams(code, name, meta)
    values (p_code, p_name, coalesce(p_meta, '{}'::jsonb))
    returning id into v_id;
  else
    update teams
       set name = coalesce(p_name, name),
           meta = teams.meta || coalesce(p_meta, '{}'::jsonb)
     where id = v_id;
  end if;
  return v_id;
end $$;

-- 5) Upsert a TEAM from an external id
create or replace function public.upsert_team_from_external(
  p_provider_code text,
  p_external_id text,
  p_code text,
  p_name text,
  p_meta jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_internal uuid;
begin
  v_internal := public.resolve_internal_id(p_provider_code, 'team', p_external_id);
  if v_internal is null then
    v_internal := public.ensure_team(p_code, p_name, p_meta);
    perform public.link_external_id(p_provider_code, 'team', p_external_id, v_internal);
  else
    update teams
       set name = coalesce(p_name, name),
           meta = teams.meta || coalesce(p_meta, '{}'::jsonb)
     where id = v_internal;
  end if;
  return v_internal;
end $$;

-- 6) Ensure a PLAYER
create or replace function public.ensure_player(
  p_full_name text,
  p_position text,
  p_team_code text default null,
  p_meta jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
declare v_team_id uuid;
begin
  if p_team_code is not null then
    select id into v_team_id from teams where code = p_team_code;
  end if;

  insert into players(full_name, position, current_team_id, meta)
  values (p_full_name, p_position, v_team_id, coalesce(p_meta, '{}'::jsonb))
  returning id into v_id;

  return v_id;
end $$;

-- 7) Upsert a PLAYER from external id
create or replace function public.upsert_player_from_external(
  p_provider_code text,
  p_external_id text,
  p_full_name text,
  p_position text,
  p_team_code text default null,
  p_meta jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_internal uuid;
declare v_team_id uuid;
begin
  v_internal := public.resolve_internal_id(p_provider_code, 'player', p_external_id);

  if v_internal is null then
    v_internal := public.ensure_player(p_full_name, p_position, p_team_code, p_meta);
    perform public.link_external_id(p_provider_code, 'player', p_external_id, v_internal);
  else
    if p_team_code is not null then
      select id into v_team_id from teams where code = p_team_code;
    end if;
    update players
       set full_name = coalesce(p_full_name, full_name),
           position = coalesce(p_position, position),
           current_team_id = coalesce(v_team_id, current_team_id),
           meta = players.meta || coalesce(p_meta, '{}'::jsonb)
     where id = v_internal;
  end if;
  return v_internal;
end $$;

-- 8) Upsert a LEAGUE from external id
create or replace function public.upsert_league_from_external(
  p_provider_code text,
  p_external_id text,
  p_name text,
  p_season int,
  p_settings jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_internal uuid;
begin
  v_internal := public.resolve_internal_id(p_provider_code, 'league', p_external_id);
  if v_internal is null then
    insert into leagues(name, season, settings)
    values (p_name, p_season, coalesce(p_settings, '{}'::jsonb))
    returning id into v_internal;
    perform public.link_external_id(p_provider_code, 'league', p_external_id, v_internal);
  else
    update leagues
       set name = coalesce(p_name, name),
           season = coalesce(p_season, season),
           settings = leagues.settings || coalesce(p_settings, '{}'::jsonb)
     where id = v_internal;
  end if;
  return v_internal;
end $$;

-- 9) Upsert a DRAFT from external id
create or replace function public.upsert_draft_from_external(
  p_provider_code text,
  p_external_id text,
  p_league_internal_id uuid,
  p_status text default 'pending',
  p_rounds int default 15,
  p_starts_at timestamptz default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_internal uuid;
begin
  v_internal := public.resolve_internal_id(p_provider_code, 'draft', p_external_id);
  if v_internal is null then
    insert into drafts(league_id, status, rounds, starts_at)
    values (p_league_internal_id, coalesce(p_status, 'pending'), coalesce(p_rounds, 15), p_starts_at)
    returning id into v_internal;
    perform public.link_external_id(p_provider_code, 'draft', p_external_id, v_internal);
  else
    update drafts
       set league_id = coalesce(p_league_internal_id, league_id),
           status = coalesce(p_status, status),
           rounds = coalesce(p_rounds, rounds),
           starts_at = coalesce(p_starts_at, starts_at)
     where id = v_internal;
  end if;
  return v_internal;
end $$;

-- 10) Upsert a GAME from external id
create or replace function public.upsert_game_from_external(
  p_provider_code text,
  p_external_id text,
  p_season int,
  p_week int,
  p_home_team_code text,
  p_away_team_code text,
  p_kickoff_at timestamptz default null,
  p_venue text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_internal uuid;
declare v_home uuid;
declare v_away uuid;
begin
  v_internal := public.resolve_internal_id(p_provider_code, 'game', p_external_id);

  if p_home_team_code is not null then
    select id into v_home from teams where code = p_home_team_code;
  end if;
  if p_away_team_code is not null then
    select id into v_away from teams where code = p_away_team_code;
  end if;

  if v_internal is null then
    insert into games(season, week, kickoff_at, home_team_id, away_team_id, venue)
    values (p_season, p_week, p_kickoff_at, v_home, v_away, p_venue)
    returning id into v_internal;
    perform public.link_external_id(p_provider_code, 'game', p_external_id, v_internal);
  else
    update games
       set season = coalesce(p_season, season),
           week = coalesce(p_week, week),
           kickoff_at = coalesce(p_kickoff_at, kickoff_at),
           home_team_id = coalesce(v_home, home_team_id),
           away_team_id = coalesce(v_away, away_team_id),
           venue = coalesce(p_venue, venue)
     where id = v_internal;
  end if;

  return v_internal;
end $$;

-- 11) Upsert a DRAFT PICK
create or replace function public.upsert_draft_pick(
  p_draft_id uuid,
  p_round int,
  p_overall int,
  p_franchise_team_id uuid,
  p_player_id uuid,
  p_made_at timestamptz default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  select id into v_id
  from draft_picks
  where draft_id = p_draft_id
    and overall_pick = p_overall;

  if v_id is null then
    insert into draft_picks(draft_id, round, overall_pick, franchise_team_id, player_id, made_at)
    values (p_draft_id, p_round, p_overall, p_franchise_team_id, p_player_id, p_made_at)
    returning id into v_id;
  else
    update draft_picks
       set round = coalesce(p_round, round),
           franchise_team_id = coalesce(p_franchise_team_id, franchise_team_id),
           player_id = coalesce(p_player_id, player_id),
           made_at = coalesce(p_made_at, made_at)
     where id = v_id;
  end if;

  return v_id;
end $$;
-- =========================================================
-- INITIAL SCHEMA (Personal analytics, provider-agnostic, Sleeper-ready)
-- Read: everyone | Write: service_role or app owner
-- =========================================================

-- Extensions
create extension if not exists "pgcrypto";
create extension if not exists "uuid-ossp";

-- ---------------------------------------------------------
-- Enums
-- ---------------------------------------------------------
do $$ begin
  create type position_t as enum ('QB','RB','WR','TE','K','DST');
exception when duplicate_object then null; end $$;

do $$ begin
  create type scoring_t as enum ('PPR','HALF_PPR','STANDARD');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tx_type_t as enum ('ADD','DROP','TRADE','WAIVER','MOVE','IR');
exception when duplicate_object then null; end $$;

do $$ begin
  create type entity_t as enum ('player','team','game','league','draft');
exception when duplicate_object then null; end $$;

do $$ begin
  create type waiver_type_t as enum ('FAAB','ROLLING','NONE');
exception when duplicate_object then null; end $$;

do $$ begin
  create type trade_review_t as enum ('VETO','COMMISH','NONE');
exception when duplicate_object then null; end $$;

do $$ begin
  create type cmp_t as enum ('>=','>','=','<','<=');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------
-- App owner & helpers (write gate)
-- ---------------------------------------------------------
create table if not exists app_config (
  id int primary key default 1,
  owner_user_id uuid not null
);

create or replace function public.is_app_owner()
returns boolean
language sql
stable
security definer
as $$
  select auth.uid() is not distinct from (select owner_user_id from app_config where id = 1);
$$;

create or replace function public.is_service_role()
returns boolean
language sql
stable
as $$
  select coalesce(auth.role(), '') = 'service_role';
$$;

create or replace function public.can_write()
returns boolean
language sql
stable
as $$
  select public.is_service_role() or public.is_app_owner();
$$;

-- ---------------------------------------------------------
-- Auth-linked identity (profile + optional Sleeper link)
-- ---------------------------------------------------------
create table if not exists public.user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique,
  display_name text,
  created_at timestamptz not null default now()
);
alter table public.user_profiles enable row level security;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.user_profiles (id, username, display_name)
  values (new.id, split_part(new.email, '@', 1), split_part(new.email, '@', 1))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create table if not exists public.user_identities (
  user_id uuid primary key references auth.users(id) on delete cascade,
  provider text not null default 'sleeper',
  sleeper_user_id text,
  sleeper_username text,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.user_identities enable row level security;

-- RLS for profiles/identities (self read, owner/service write)
drop policy if exists "profiles_read_self" on public.user_profiles;
drop policy if exists "profiles_write_owner_service" on public.user_profiles;
create policy "profiles_read_self" on public.user_profiles
  for select using (id = auth.uid() or public.can_write());
create policy "profiles_write_owner_service" on public.user_profiles
  for all using (public.can_write()) with check (public.can_write());

drop policy if exists "ident_read_self" on public.user_identities;
drop policy if exists "ident_write_owner_service" on public.user_identities;
create policy "ident_read_self" on public.user_identities
  for select using (user_id = auth.uid() or public.can_write());
create policy "ident_write_owner_service" on public.user_identities
  for all using (public.can_write()) with check (public.can_write());

-- ---------------------------------------------------------
-- Provider-agnostic dictionary layer
-- ---------------------------------------------------------
create table if not exists providers (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,            -- 'sleeper','fantasypros','sportsdataio','ai-computed'
  name text not null,
  meta jsonb not null default '{}'::jsonb
);
alter table public.providers enable row level security;

create table if not exists metrics_catalog (
  metric_id text primary key,           -- 'fantasy_points_ppr','rush_yds','rec_tgt','td_prob', etc.
  unit text not null,                   -- 'points','yards','count','probability','percent'
  description text
);
alter table public.metrics_catalog enable row level security;

create table if not exists provider_metric_map (
  provider_id uuid references providers(id) on delete cascade,
  provider_key text not null,           -- e.g., 'fp:proj_fp_ppr' or 'sdi:FantasyPointsPPR'
  metric_id text references metrics_catalog(metric_id) on delete restrict,
  transform jsonb not null default '{}'::jsonb,
  primary key (provider_id, provider_key)
);
alter table public.provider_metric_map enable row level security;

-- Canonical entities (UUIDs)
create table if not exists teams (
  id uuid primary key default gen_random_uuid(),
  code text unique,                      -- 'BUF','NYJ'
  name text not null,
  meta jsonb not null default '{}'::jsonb
);
alter table public.teams enable row level security;

create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  position text not null,                -- or swap to position_t if you prefer strictness
  handedness text,
  birthdate date,
  current_team_id uuid references teams(id) on delete set null,
  meta jsonb not null default '{}'::jsonb
);
alter table public.players enable row level security;

create table if not exists games (
  id uuid primary key default gen_random_uuid(),
  season int not null,
  week int not null,
  kickoff_at timestamptz,
  home_team_id uuid references teams(id) on delete restrict,
  away_team_id uuid references teams(id) on delete restrict,
  venue text,
  unique (season, week, home_team_id, away_team_id)
);
alter table public.games enable row level security;

-- External IDs for mapping any provider/entity → internal UUID
create table if not exists external_ids (
  provider_id uuid references providers(id) on delete cascade,
  entity_type entity_t not null,
  external_id text not null,
  internal_id uuid not null,            -- points at players/teams/games/leagues/drafts
  primary key (provider_id, entity_type, external_id)
);
alter table public.external_ids enable row level security;
create index if not exists idx_external_ids_internal on public.external_ids(internal_id);

-- Facts: stats & projections (long/tidy)
create table if not exists player_stats (
  player_id uuid references players(id) on delete cascade,
  season int not null,
  week int not null,
  game_id uuid references games(id) on delete set null, -- null = weekly rollup
  provider_id uuid references providers(id) on delete restrict,
  metric_id text references metrics_catalog(metric_id) on delete restrict,
  value numeric not null,
  observed_at timestamptz not null default now(),
  run_id uuid default gen_random_uuid(),
  primary key (player_id, season, week, provider_id, metric_id, run_id)
);
alter table public.player_stats enable row level security;
create index if not exists idx_player_stats_latest
  on public.player_stats(player_id, season, week, metric_id, observed_at desc);

create table if not exists player_projections (
  player_id uuid references players(id) on delete cascade,
  season int not null,
  week int not null,
  provider_id uuid references providers(id) on delete restrict, -- include 'ai-computed'
  metric_id text references metrics_catalog(metric_id) on delete restrict,
  value numeric not null,
  uncertainty numeric,
  observed_at timestamptz not null default now(),
  run_id uuid default gen_random_uuid(),
  primary key (player_id, season, week, provider_id, metric_id, run_id)
);
alter table public.player_projections enable row level security;
create index if not exists idx_player_proj_latest
  on public.player_projections(player_id, season, week, metric_id, observed_at desc);

create or replace view v_player_projections_latest as
select distinct on (player_id, season, week, metric_id, provider_id)
  player_id, season, week, provider_id, metric_id, value, uncertainty, observed_at, run_id
from player_projections
order by player_id, season, week, metric_id, provider_id, observed_at desc;

-- Raw staging for payloads
create table if not exists stg_ingestions (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid references providers(id) on delete cascade,
  endpoint text not null,
  fetched_at timestamptz not null default now(),
  payload jsonb not null
);
alter table public.stg_ingestions enable row level security;

-- ---------------------------------------------------------
-- App layer: leagues, members, franchise teams, drafts, etc.
-- ---------------------------------------------------------
create table if not exists leagues (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  season int not null,
  scoring scoring_t not null default 'PPR',
  settings jsonb not null default '{}'::jsonb, -- raw provider settings (Sleeper)
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.leagues enable row level security;

create table if not exists league_members (
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member', -- informational
  joined_at timestamptz not null default now(),
  primary key (league_id, user_id)
);
alter table public.league_members enable row level security;

create table if not exists franchise_teams (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  name text not null,
  manager_user_id uuid references auth.users(id) on delete set null,
  ext_hint text, -- e.g., 'sleeper:roster_id=7' (optional)
  unique (league_id, name),
  created_at timestamptz not null default now()
);
alter table public.franchise_teams enable row level security;

create table if not exists drafts (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  status text not null default 'pending',   -- pending | live | complete
  rounds int not null default 15,
  starts_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.drafts enable row level security;

create table if not exists draft_picks (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references public.drafts(id) on delete cascade,
  round int not null,
  overall_pick int not null,
  franchise_team_id uuid references public.franchise_teams(id) on delete set null,
  player_id uuid references public.players(id) on delete set null,
  made_at timestamptz,
  unique (draft_id, overall_pick)
);
alter table public.draft_picks enable row level security;
create index if not exists idx_draft_picks_draft_round on public.draft_picks (draft_id, round);

create table if not exists roster_slots (
  id uuid primary key default gen_random_uuid(),
  franchise_team_id uuid not null references public.franchise_teams(id) on delete cascade,
  week int not null,
  slot text not null,                    -- QB, RB1, RB2, WR1, WR2, TE, FLEX, BENCH, IR, etc.
  player_id uuid references public.players(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (franchise_team_id, week, slot)
);
alter table public.roster_slots enable row level security;

create table if not exists matchups (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  week int not null,
  home_team_id uuid not null references public.franchise_teams(id) on delete cascade,
  away_team_id uuid not null references public.franchise_teams(id) on delete cascade,
  home_points numeric(6,2) not null default 0,
  away_points numeric(6,2) not null default 0,
  unique (league_id, week, home_team_id, away_team_id)
);
alter table public.matchups enable row level security;

create table if not exists transactions (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  week int,
  type tx_type_t not null,
  actor_team_id uuid references public.franchise_teams(id) on delete set null,
  from_team_id uuid references public.franchise_teams(id) on delete set null,
  to_team_id uuid references public.franchise_teams(id) on delete set null,
  player_id uuid references public.players(id) on delete set null,
  created_at timestamptz not null default now(),
  raw jsonb not null default '{}'::jsonb
);
alter table public.transactions enable row level security;

create or replace view public.my_franchise_teams as
select ft.*
from franchise_teams ft
join league_members lm on lm.league_id = ft.league_id
where lm.user_id = auth.uid();

-- ---------------------------------------------------------
-- Normalized League Settings (provider-agnostic)
-- ---------------------------------------------------------
create table if not exists league_roster_slots (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  slot_code text not null,     -- 'QB','RB','WR','TE','FLEX','SUPERFLEX','K','DST','BENCH','IR','TAXI'
  quantity int not null,
  constraints jsonb not null default '{}'::jsonb,  -- e.g., {"flex_pool":["RB","WR","TE"]}
  unique (league_id, slot_code)
);
alter table public.league_roster_slots enable row level security;

create table if not exists league_scoring_rules (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  metric_id text not null references public.metrics_catalog(metric_id) on delete restrict,
  points_per_unit numeric not null,     -- e.g., 1.0 for PPR, 0.1 per yard
  unit text not null,                   -- mirror metrics_catalog.unit
  unique (league_id, metric_id)
);
alter table public.league_scoring_rules enable row level security;

create table if not exists league_scoring_bonuses (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  metric_id text not null references public.metrics_catalog(metric_id) on delete restrict,
  comparator cmp_t not null,            -- '>=','>','='...
  threshold numeric not null,           -- e.g., 100 (yards)
  bonus_points numeric not null,        -- e.g., 3
  meta jsonb not null default '{}'::jsonb
);
alter table public.league_scoring_bonuses enable row level security;

create table if not exists league_waiver_rules (
  league_id uuid primary key references public.leagues(id) on delete cascade,
  waiver_type waiver_type_t not null default 'ROLLING',
  faab_budget int,
  weekly_reset boolean,
  process_day text,
  process_time_utc time,
  meta jsonb not null default '{}'::jsonb
);
alter table public.league_waiver_rules enable row level security;

create table if not exists league_trade_rules (
  league_id uuid primary key references public.leagues(id) on delete cascade,
  review_type trade_review_t not null default 'COMMISH',
  review_days int,
  trade_deadline_week int,
  meta jsonb not null default '{}'::jsonb
);
alter table public.league_trade_rules enable row level security;

create table if not exists league_playoff_rules (
  league_id uuid primary key references public.leagues(id) on delete cascade,
  teams int not null,
  start_week int not null,
  rounds int not null,
  third_place_game boolean default true,
  consolation_bracket boolean default true,
  meta jsonb not null default '{}'::jsonb
);
alter table public.league_playoff_rules enable row level security;

create table if not exists league_divisions (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  name text not null,
  sort_order int,
  unique (league_id, name)
);
alter table public.league_divisions enable row level security;

create table if not exists league_division_members (
  division_id uuid not null references public.league_divisions(id) on delete cascade,
  franchise_team_id uuid not null references public.franchise_teams(id) on delete cascade,
  primary key (division_id, franchise_team_id)
);
alter table public.league_division_members enable row level security;

-- ---------------------------------------------------------
-- RLS: Read-all, Write only if service role OR app owner
-- (No CREATE POLICY IF NOT EXISTS; drop+create for idempotence)
-- ---------------------------------------------------------

-- Dictionary / Entities / Facts
drop policy if exists "providers_read_all"   on public.providers;
drop policy if exists "providers_write_sync" on public.providers;
create policy "providers_read_all"   on public.providers for select using (true);
create policy "providers_write_sync" on public.providers for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "metrics_read_all"     on public.metrics_catalog;
drop policy if exists "metrics_write_sync"   on public.metrics_catalog;
create policy "metrics_read_all"   on public.metrics_catalog for select using (true);
create policy "metrics_write_sync" on public.metrics_catalog for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "map_read_all"         on public.provider_metric_map;
drop policy if exists "map_write_sync"       on public.provider_metric_map;
create policy "map_read_all"   on public.provider_metric_map for select using (true);
create policy "map_write_sync" on public.provider_metric_map for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "players_read_all"     on public.players;
drop policy if exists "players_write_sync"   on public.players;
create policy "players_read_all"   on public.players for select using (true);
create policy "players_write_sync" on public.players for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "teams_read_all"       on public.teams;
drop policy if exists "teams_write_sync"     on public.teams;
create policy "teams_read_all"   on public.teams for select using (true);
create policy "teams_write_sync" on public.teams for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "games_read_all"       on public.games;
drop policy if exists "games_write_sync"     on public.games;
create policy "games_read_all"   on public.games for select using (true);
create policy "games_write_sync" on public.games for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "extids_read_all"      on public.external_ids;
drop policy if exists "extids_write_sync"    on public.external_ids;
create policy "extids_read_all"   on public.external_ids for select using (true);
create policy "extids_write_sync" on public.external_ids for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "stats_read_all"       on public.player_stats;
drop policy if exists "stats_write_sync"     on public.player_stats;
create policy "stats_read_all"   on public.player_stats for select using (true);
create policy "stats_write_sync" on public.player_stats for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "projections_read_all" on public.player_projections;
drop policy if exists "projections_write_sync" on public.player_projections;
create policy "projections_read_all"   on public.player_projections for select using (true);
create policy "projections_write_sync" on public.player_projections for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "stg_read_all"         on public.stg_ingestions;
drop policy if exists "stg_write_sync"       on public.stg_ingestions;
create policy "stg_read_all"   on public.stg_ingestions for select using (true);
create policy "stg_write_sync" on public.stg_ingestions for all    using (public.can_write()) with check (public.can_write());

-- App layer
drop policy if exists "leagues_read_all"     on public.leagues;
drop policy if exists "leagues_write_sync"   on public.leagues;
create policy "leagues_read_all"   on public.leagues for select using (true);
create policy "leagues_write_sync" on public.leagues for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "lm_read_all"          on public.league_members;
drop policy if exists "lm_write_sync"        on public.league_members;
create policy "lm_read_all"   on public.league_members for select using (true);
create policy "lm_write_sync" on public.league_members for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "ft_read_all"          on public.franchise_teams;
drop policy if exists "ft_write_sync"        on public.franchise_teams;
create policy "ft_read_all"   on public.franchise_teams for select using (true);
create policy "ft_write_sync" on public.franchise_teams for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "drafts_read_all"      on public.drafts;
drop policy if exists "drafts_write_sync"    on public.drafts;
create policy "drafts_read_all"   on public.drafts for select using (true);
create policy "drafts_write_sync" on public.drafts for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "picks_read_all"       on public.draft_picks;
drop policy if exists "picks_write_sync"     on public.draft_picks;
create policy "picks_read_all"   on public.draft_picks for select using (true);
create policy "picks_write_sync" on public.draft_picks for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "rosters_read_all"     on public.roster_slots;
drop policy if exists "rosters_write_sync"   on public.roster_slots;
create policy "rosters_read_all"   on public.roster_slots for select using (true);
create policy "rosters_write_sync" on public.roster_slots for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "matchups_read_all"    on public.matchups;
drop policy if exists "matchups_write_sync"  on public.matchups;
create policy "matchups_read_all"   on public.matchups for select using (true);
create policy "matchups_write_sync" on public.matchups for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "tx_read_all"          on public.transactions;
drop policy if exists "tx_write_sync"        on public.transactions;
create policy "tx_read_all"   on public.transactions for select using (true);
create policy "tx_write_sync" on public.transactions for all    using (public.can_write()) with check (public.can_write());

-- Settings
drop policy if exists "lrs_read_all"         on public.league_roster_slots;
drop policy if exists "lrs_write_sync"       on public.league_roster_slots;
create policy "lrs_read_all"   on public.league_roster_slots for select using (true);
create policy "lrs_write_sync" on public.league_roster_slots for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "lsr_read_all"         on public.league_scoring_rules;
drop policy if exists "lsr_write_sync"       on public.league_scoring_rules;
create policy "lsr_read_all"   on public.league_scoring_rules for select using (true);
create policy "lsr_write_sync" on public.league_scoring_rules for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "lsb_read_all"         on public.league_scoring_bonuses;
drop policy if exists "lsb_write_sync"       on public.league_scoring_bonuses;
create policy "lsb_read_all"   on public.league_scoring_bonuses for select using (true);
create policy "lsb_write_sync" on public.league_scoring_bonuses for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "lwr_read_all"         on public.league_waiver_rules;
drop policy if exists "lwr_write_sync"       on public.league_waiver_rules;
create policy "lwr_read_all"   on public.league_waiver_rules for select using (true);
create policy "lwr_write_sync" on public.league_waiver_rules for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "ltr_read_all"         on public.league_trade_rules;
drop policy if exists "ltr_write_sync"       on public.league_trade_rules;
create policy "ltr_read_all"   on public.league_trade_rules for select using (true);
create policy "ltr_write_sync" on public.league_trade_rules for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "lpr_read_all"         on public.league_playoff_rules;
drop policy if exists "lpr_write_sync"       on public.league_playoff_rules;
create policy "lpr_read_all"   on public.league_playoff_rules for select using (true);
create policy "lpr_write_sync" on public.league_playoff_rules for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "ldiv_read_all"        on public.league_divisions;
drop policy if exists "ldiv_write_sync"      on public.league_divisions;
create policy "ldiv_read_all"   on public.league_divisions for select using (true);
create policy "ldiv_write_sync" on public.league_divisions for all    using (public.can_write()) with check (public.can_write());

drop policy if exists "ldivm_read_all"       on public.league_division_members;
drop policy if exists "ldivm_write_sync"     on public.league_division_members;
create policy "ldivm_read_all"   on public.league_division_members for select using (true);
create policy "ldivm_write_sync" on public.league_division_members for all    using (public.can_write()) with check (public.can_write());

-- ---------------------------------------------------------
-- Helpful indexes
-- ---------------------------------------------------------
create index if not exists idx_league_members_user on public.league_members(user_id);
create index if not exists idx_ft_league on public.franchise_teams(league_id);
create index if not exists idx_roster_team_week on public.roster_slots(franchise_team_id, week);
create index if not exists idx_matchups_league_week on public.matchups(league_id, week);

-- ---------------------------------------------------------
-- Seeds
-- ---------------------------------------------------------
insert into providers (code, name) values
  ('sleeper','Sleeper'),
  ('fantasypros','FantasyPros'),
  ('fantasynerds','Fantasy Nerds'),
  ('sportsdataio','SportsDataIO'),
  ('ai-computed','AI Computed')
on conflict (code) do nothing;

insert into metrics_catalog(metric_id, unit, description) values
  ('fantasy_points_ppr','points','PPR fantasy points'),
  ('pass_yds','yards','Passing yards'),
  ('pass_td','count','Passing touchdowns'),
  ('rush_att','count','Rushing attempts'),
  ('rush_yds','yards','Rushing yards'),
  ('rush_td','count','Rushing touchdowns'),
  ('rec_tgt','count','Targets'),
  ('rec_rec','count','Receptions'),
  ('rec_yds','yards','Receiving yards'),
  ('rec_td','count','Receiving touchdowns'),
  ('td_prob','probability','Estimated touchdown probability')
on conflict (metric_id) do nothing;

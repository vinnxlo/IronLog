-- Relational workout facts and shared exercise catalog.
-- Run after confirming public.workouts uses text IDs, UUID user_id,
-- bigint epoch-millisecond timestamps, integer duration, numeric volume,
-- and a jsonb exercises column. Legacy JSON is retained for rollback.

do $$
begin
  if (select data_type from information_schema.columns
      where table_schema = 'public' and table_name = 'workouts' and column_name = 'id') is distinct from 'text'
     or (select data_type from information_schema.columns
         where table_schema = 'public' and table_name = 'workouts' and column_name = 'user_id') is distinct from 'uuid'
     or (select data_type from information_schema.columns
         where table_schema = 'public' and table_name = 'workouts' and column_name = 'start_time') is distinct from 'bigint'
     or (select data_type from information_schema.columns
         where table_schema = 'public' and table_name = 'workouts' and column_name = 'end_time') is distinct from 'bigint'
     or (select data_type from information_schema.columns
         where table_schema = 'public' and table_name = 'workouts' and column_name = 'duration') is distinct from 'integer'
     or (select data_type from information_schema.columns
         where table_schema = 'public' and table_name = 'workouts' and column_name = 'volume') is distinct from 'numeric'
     or (select data_type from information_schema.columns
         where table_schema = 'public' and table_name = 'workouts' and column_name = 'exercises') is distinct from 'jsonb' then
    raise exception 'Unexpected public.workouts schema. Expected text id, UUID user_id, bigint start/end times, integer duration, numeric volume, and jsonb exercises. Review before retrying.';
  end if;
end $$;

create unique index if not exists workouts_id_user_id_uidx
  on public.workouts (id, user_id);

alter table public.workouts enable row level security;
drop policy if exists "Allow public access" on public.workouts;
drop policy if exists "Users can only access their own workouts" on public.workouts;
create policy "Users can only access their own workouts"
  on public.workouts for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create table if not exists public.exercise_listing (
  exercise_listing_id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  description text,
  exercise_type text not null check (exercise_type in ('strength', 'cardio')),
  created_at timestamptz not null default now()
);

create unique index if not exists exercise_listing_shared_name_type_uidx
  on public.exercise_listing (lower(name), exercise_type)
  where user_id is null;
create unique index if not exists exercise_listing_owner_name_type_uidx
  on public.exercise_listing (user_id, lower(name), exercise_type)
  where user_id is not null;

create table if not exists public.muscle_groups (
  muscle_group_id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  include_in_overview boolean not null default true
);

create table if not exists public.exercise_muscle_groups (
  exercise_listing_id uuid not null references public.exercise_listing(exercise_listing_id) on delete cascade,
  muscle_group_id uuid not null references public.muscle_groups(muscle_group_id) on delete cascade,
  primary key (exercise_listing_id, muscle_group_id)
);

create table if not exists public.date_dimension (
  date_key integer primary key,
  calendar_date date not null unique,
  calendar_year smallint not null,
  iso_year smallint not null,
  quarter smallint not null check (quarter between 1 and 4),
  month smallint not null check (month between 1 and 12),
  day_of_month smallint not null check (day_of_month between 1 and 31),
  week_of_year smallint not null check (week_of_year between 1 and 53),
  iso_day_of_week smallint not null check (iso_day_of_week between 1 and 7),
  month_name text not null
);

create table if not exists public.workout_exercises (
  workout_exercise_id uuid primary key default gen_random_uuid(),
  workout_id text not null,
  exercise_listing_id uuid not null references public.exercise_listing(exercise_listing_id),
  owner uuid not null references auth.users(id) on delete cascade,
  exercise_order integer not null check (exercise_order > 0),
  is_completed boolean not null default true check (is_completed),
  duration_minutes numeric,
  distance_km numeric,
  calories integer,
  unique (workout_id, owner, exercise_order),
  unique (workout_exercise_id, owner),
  foreign key (workout_id, owner) references public.workouts(id, user_id) on delete cascade,
  check (duration_minutes is null or duration_minutes >= 0),
  check (distance_km is null or distance_km >= 0),
  check (calories is null or calories >= 0)
);

create table if not exists public.recorded_sets (
  recorded_set_id uuid primary key default gen_random_uuid(),
  workout_id text not null,
  workout_exercise_id uuid not null,
  exercise_listing_id uuid not null references public.exercise_listing(exercise_listing_id),
  owner uuid not null references auth.users(id) on delete cascade,
  date_key integer not null references public.date_dimension(date_key),
  set_number integer not null check (set_number > 0),
  repetitions integer check (repetitions is null or repetitions >= 0),
  weight numeric check (weight is null or weight >= 0),
  weight_unit text not null default 'kg' check (weight_unit in ('kg', 'lb')),
  is_warmup boolean not null default false,
  is_completed boolean not null default true check (is_completed),
  notes text,
  unique (workout_exercise_id, set_number),
  foreign key (workout_id, owner) references public.workouts(id, user_id) on delete cascade,
  foreign key (workout_exercise_id, owner) references public.workout_exercises(workout_exercise_id, owner) on delete cascade
);

create index if not exists workout_exercises_owner_workout_idx
  on public.workout_exercises (owner, workout_id);
create index if not exists recorded_sets_owner_date_idx
  on public.recorded_sets (owner, date_key);
create index if not exists recorded_sets_exercise_date_idx
  on public.recorded_sets (exercise_listing_id, date_key);

create or replace function public.assert_exercise_listing_owner()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_listing_owner uuid;
  v_exercise_type text;
begin
  select user_id, exercise_type into v_listing_owner, v_exercise_type
  from public.exercise_listing
  where exercise_listing_id = new.exercise_listing_id;
  if not found then
    raise exception 'Exercise listing does not exist.';
  end if;
  if v_listing_owner is not null and v_listing_owner <> new.owner then
    raise exception 'A workout can only reference shared exercises or exercises owned by the same user.';
  end if;
  if v_exercise_type = 'strength' and (
    new.duration_minutes is not null or new.distance_km is not null or new.calories is not null
  ) then
    raise exception 'Cardio metrics can only be stored on cardio exercises.';
  end if;
  return new;
end;
$$;

drop trigger if exists workout_exercises_listing_owner_check on public.workout_exercises;
create trigger workout_exercises_listing_owner_check
  before insert or update on public.workout_exercises
  for each row execute function public.assert_exercise_listing_owner();

create or replace function public.assert_recorded_set_consistency()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_occurrence_listing_id uuid;
  v_exercise_type text;
begin
  select we.exercise_listing_id, e.exercise_type
    into v_occurrence_listing_id, v_exercise_type
  from public.workout_exercises we
  join public.exercise_listing e using (exercise_listing_id)
  where we.workout_exercise_id = new.workout_exercise_id
    and we.owner = new.owner
    and we.workout_id = new.workout_id;
  if not found or v_occurrence_listing_id <> new.exercise_listing_id or v_exercise_type <> 'strength' then
    raise exception 'Recorded set workout, exercise, and owner must match its workout exercise.';
  end if;
  return new;
end;
$$;

drop trigger if exists recorded_sets_consistency_check on public.recorded_sets;
create trigger recorded_sets_consistency_check
  before insert or update of workout_id, workout_exercise_id, exercise_listing_id, owner on public.recorded_sets
  for each row execute function public.assert_recorded_set_consistency();

alter table public.exercise_listing enable row level security;
alter table public.muscle_groups enable row level security;
alter table public.exercise_muscle_groups enable row level security;
alter table public.date_dimension enable row level security;
alter table public.workout_exercises enable row level security;
alter table public.recorded_sets enable row level security;

drop policy if exists "Authenticated users read shared and owned exercises" on public.exercise_listing;
create policy "Authenticated users read shared and owned exercises"
  on public.exercise_listing for select to authenticated
  using (user_id is null or user_id = auth.uid());
drop policy if exists "Users create their own exercises" on public.exercise_listing;
create policy "Users create their own exercises"
  on public.exercise_listing for insert to authenticated
  with check (user_id = auth.uid());
drop policy if exists "Users update their own exercises" on public.exercise_listing;
create policy "Users update their own exercises"
  on public.exercise_listing for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "Users delete their own exercises" on public.exercise_listing;
create policy "Users delete their own exercises"
  on public.exercise_listing for delete to authenticated
  using (user_id = auth.uid());

drop policy if exists "Authenticated users read muscle groups" on public.muscle_groups;
create policy "Authenticated users read muscle groups"
  on public.muscle_groups for select to authenticated using (true);
drop policy if exists "Authenticated users read date dimension" on public.date_dimension;
create policy "Authenticated users read date dimension"
  on public.date_dimension for select to authenticated using (true);
drop policy if exists "Authenticated users add calendar dates" on public.date_dimension;
create policy "Authenticated users add calendar dates"
  on public.date_dimension for insert to authenticated with check (true);
drop policy if exists "Authenticated users read visible exercise muscles" on public.exercise_muscle_groups;
create policy "Authenticated users read visible exercise muscles"
  on public.exercise_muscle_groups for select to authenticated
  using (exists (
    select 1 from public.exercise_listing e
    where e.exercise_listing_id = exercise_muscle_groups.exercise_listing_id
      and (e.user_id is null or e.user_id = auth.uid())
  ));

drop policy if exists "Users access their workout exercises" on public.workout_exercises;
create policy "Users access their workout exercises"
  on public.workout_exercises for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());
drop policy if exists "Users access their recorded sets" on public.recorded_sets;
create policy "Users access their recorded sets"
  on public.recorded_sets for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

grant select, insert, update, delete on public.exercise_listing to authenticated;
grant select on public.muscle_groups, public.exercise_muscle_groups, public.date_dimension to authenticated;
grant select on public.workout_exercises, public.recorded_sets to authenticated;
revoke insert, update on public.workouts from anon, authenticated;
revoke insert, update, delete on public.workout_exercises, public.recorded_sets from anon, authenticated;
revoke insert, update, delete on public.date_dimension from anon, authenticated;
grant select, delete on public.workouts to authenticated;

insert into public.exercise_listing (user_id, name, exercise_type)
select null, source.name, source.exercise_type
from (values
  ('Bench Press','strength'),('Incline Bench Press','strength'),('45° Incline Barbell Press','strength'),('Decline Bench Press','strength'),
  ('Dumbbell Fly','strength'),('Bottom-Half DB Flye','strength'),('Cable Fly','strength'),('Cable Crossover','strength'),('Push-ups','strength'),('Dips','strength'),
  ('Overhead Press','strength'),('Arnold Press','strength'),('Machine Shoulder Press','strength'),('Lateral Raises','strength'),
  ('High-Cable Lateral Raise','strength'),('Front Raises','strength'),('Rear Delt Fly','strength'),
  ('Bicep Curls','strength'),('Hammer Curls','strength'),('Preacher Curls','strength'),('EZ-Bar Curl','strength'),('Bayesian Cable Curl','strength'),
  ('Tricep Dips','strength'),('Skull Crushers','strength'),('Tricep Pushdown','strength'),('Overhead Cable Triceps Extension','strength'),('Cable Triceps Kickback','strength'),
  ('Pull-ups','strength'),('Wide-Grip Pull-Up','strength'),('Chin-ups','strength'),('Barbell Rows','strength'),('Pendlay Row','strength'),
  ('Cable Rows','strength'),('Seated Rows','strength'),('Chest-Supported Machine Row','strength'),('Lat Pulldown','strength'),('Neutral-Grip Lat Pulldown','strength'),
  ('Face Pulls','strength'),('Machine Shrug','strength'),
  ('Squat','strength'),('Smith Machine Squat','strength'),('Front Squat','strength'),('Hack Squat','strength'),('DB Bulgarian Split Squat','strength'),
  ('Leg Press','strength'),('Leg Extension','strength'),('Leg Curls','strength'),('Lying Leg Curl','strength'),('Romanian Deadlift','strength'),('Barbell RDL','strength'),
  ('Deadlift','strength'),('Sumo Deadlift','strength'),('Hip Thrust','strength'),('Glute Bridge','strength'),('Calf Raises','strength'),
  ('Seated Calf Raises','strength'),('Machine Hip Adduction','strength'),('Machine Hip Abduction','strength'),
  ('Plank','strength'),('Ab Rollout','strength'),('Crunches','strength'),('Cable Crunch','strength'),('Roman Chair Leg Raise','strength'),
  ('Russian Twists','strength'),('Leg Raises','strength'),
  ('Running','cardio'),('Treadmill Run','cardio'),('Cycling','cardio'),('Stationary Bike','cardio'),('Rowing Machine','cardio'),
  ('Elliptical','cardio'),('Swimming','cardio'),('Jump Rope','cardio'),('Stair Climber','cardio'),('HIIT Sprint','cardio'),('Walking','cardio'),('Hiking','cardio')
) as source(name, exercise_type)
where not exists (
  select 1 from public.exercise_listing e
  where e.user_id is null and lower(e.name) = lower(source.name) and e.exercise_type = source.exercise_type
);

insert into public.muscle_groups (name)
select distinct source.muscle_name
from (values
  ('Chest'),('Triceps'),('Shoulders'),('Biceps'),('Forearms'),('Back'),('Quads'),('Glutes'),('Hamstrings'),('Calves'),('Core')
) as source(muscle_name)
where not exists (select 1 from public.muscle_groups m where m.name = source.muscle_name);
update public.muscle_groups set include_in_overview = false where name = 'Forearms';

insert into public.exercise_muscle_groups (exercise_listing_id, muscle_group_id)
select e.exercise_listing_id, m.muscle_group_id
from (values
  ('Bench Press','Chest'),('Bench Press','Triceps'),('Bench Press','Shoulders'),
  ('Incline Bench Press','Chest'),('Incline Bench Press','Shoulders'),
  ('45° Incline Barbell Press','Chest'),('45° Incline Barbell Press','Shoulders'),
  ('Decline Bench Press','Chest'),('Dumbbell Fly','Chest'),('Bottom-Half DB Flye','Chest'),
  ('Cable Fly','Chest'),('Cable Crossover','Chest'),('Push-ups','Chest'),('Push-ups','Triceps'),
  ('Dips','Chest'),('Dips','Triceps'),('Overhead Press','Shoulders'),('Overhead Press','Triceps'),
  ('Arnold Press','Shoulders'),('Machine Shoulder Press','Shoulders'),('Machine Shoulder Press','Triceps'),
  ('Lateral Raises','Shoulders'),('High-Cable Lateral Raise','Shoulders'),('Front Raises','Shoulders'),('Rear Delt Fly','Shoulders'),
  ('Bicep Curls','Biceps'),('Hammer Curls','Biceps'),('Hammer Curls','Forearms'),('Preacher Curls','Biceps'),
  ('EZ-Bar Curl','Biceps'),('Bayesian Cable Curl','Biceps'),
  ('Tricep Dips','Triceps'),('Skull Crushers','Triceps'),('Tricep Pushdown','Triceps'),
  ('Overhead Cable Triceps Extension','Triceps'),('Cable Triceps Kickback','Triceps'),
  ('Pull-ups','Back'),('Pull-ups','Biceps'),('Wide-Grip Pull-Up','Back'),('Wide-Grip Pull-Up','Biceps'),
  ('Chin-ups','Back'),('Chin-ups','Biceps'),('Barbell Rows','Back'),('Pendlay Row','Back'),
  ('Cable Rows','Back'),('Seated Rows','Back'),('Chest-Supported Machine Row','Back'),
  ('Lat Pulldown','Back'),('Neutral-Grip Lat Pulldown','Back'),('Face Pulls','Back'),('Face Pulls','Shoulders'),
  ('Machine Shrug','Shoulders'),
  ('Squat','Quads'),('Squat','Glutes'),('Smith Machine Squat','Quads'),('Smith Machine Squat','Glutes'),
  ('Front Squat','Quads'),('Hack Squat','Quads'),('DB Bulgarian Split Squat','Quads'),('DB Bulgarian Split Squat','Glutes'),
  ('Leg Press','Quads'),('Leg Press','Glutes'),('Leg Extension','Quads'),('Leg Curls','Hamstrings'),
  ('Lying Leg Curl','Hamstrings'),('Romanian Deadlift','Hamstrings'),('Romanian Deadlift','Glutes'),
  ('Barbell RDL','Hamstrings'),('Barbell RDL','Glutes'),('Deadlift','Back'),('Deadlift','Glutes'),('Deadlift','Hamstrings'),
  ('Sumo Deadlift','Glutes'),('Sumo Deadlift','Quads'),('Hip Thrust','Glutes'),('Glute Bridge','Glutes'),
  ('Calf Raises','Calves'),('Seated Calf Raises','Calves'),('Machine Hip Adduction','Quads'),('Machine Hip Abduction','Glutes'),
  ('Plank','Core'),('Ab Rollout','Core'),('Crunches','Core'),('Cable Crunch','Core'),
  ('Roman Chair Leg Raise','Core'),('Russian Twists','Core'),('Leg Raises','Core')
) as source(exercise_name, muscle_name)
join public.exercise_listing e
  on e.user_id is null and e.name = source.exercise_name and e.exercise_type = 'strength'
join public.muscle_groups m on m.name = source.muscle_name
on conflict do nothing;

-- Preserve historical parents. Only checked strength sets become fact rows.
-- Legacy cardio has no per-entry completion flag; inclusion in a finalized
-- workout is its only available completion signal, so keep those entries.
insert into public.exercise_listing (user_id, name, exercise_type)
select distinct w.user_id, trim(ex->>'name'), lower(coalesce(ex->>'type', 'strength'))
from public.workouts w
cross join lateral jsonb_array_elements(coalesce(w.exercises, '[]'::jsonb)) ex
where w.user_id is not null
  and nullif(trim(ex->>'name'), '') is not null
  and lower(coalesce(ex->>'type', 'strength')) in ('strength', 'cardio')
  and not exists (
    select 1 from public.exercise_listing e
    where lower(e.name) = lower(trim(ex->>'name'))
      and e.exercise_type = lower(coalesce(ex->>'type', 'strength'))
      and (e.user_id is null or e.user_id = w.user_id)
  )
on conflict do nothing;

insert into public.workout_exercises
  (workout_id, exercise_listing_id, owner, exercise_order, is_completed, duration_minutes, distance_km, calories)
select w.id,
       e.exercise_listing_id,
       w.user_id,
       ex.ordinality::integer,
       true,
       nullif(ex.item->>'duration', '')::numeric,
       nullif(ex.item->>'distance', '')::numeric,
       nullif(ex.item->>'calories', '')::integer
from public.workouts w
cross join lateral jsonb_array_elements(coalesce(w.exercises, '[]'::jsonb))
  with ordinality as ex(item, ordinality)
join lateral (
  select exercise_listing_id
  from public.exercise_listing
  where lower(name) = lower(trim(ex.item->>'name'))
    and exercise_type = lower(coalesce(ex.item->>'type', 'strength'))
    and (user_id is null or user_id = w.user_id)
  order by (user_id = w.user_id) desc nulls last
  limit 1
) e on true
where w.user_id is not null
  and (
    lower(coalesce(ex.item->>'type', 'strength')) = 'cardio'
    or exists (
      select 1
      from jsonb_array_elements(coalesce(ex.item->'sets', '[]'::jsonb)) set_item
      where set_item->>'done' = 'true'
    )
  )
on conflict (workout_id, owner, exercise_order) do nothing;

insert into public.date_dimension
  (date_key, calendar_date, calendar_year, iso_year, quarter, month, day_of_month,
   week_of_year, iso_day_of_week, month_name)
select distinct
       to_char((to_timestamp(w.start_time::double precision / 1000) at time zone 'UTC')::date, 'YYYYMMDD')::integer,
       (to_timestamp(w.start_time::double precision / 1000) at time zone 'UTC')::date,
       extract(year from (to_timestamp(w.start_time::double precision / 1000) at time zone 'UTC'))::smallint,
       extract(isoyear from (to_timestamp(w.start_time::double precision / 1000) at time zone 'UTC'))::smallint,
       extract(quarter from (to_timestamp(w.start_time::double precision / 1000) at time zone 'UTC'))::smallint,
       extract(month from (to_timestamp(w.start_time::double precision / 1000) at time zone 'UTC'))::smallint,
       extract(day from (to_timestamp(w.start_time::double precision / 1000) at time zone 'UTC'))::smallint,
       extract(week from (to_timestamp(w.start_time::double precision / 1000) at time zone 'UTC'))::smallint,
       extract(isodow from (to_timestamp(w.start_time::double precision / 1000) at time zone 'UTC'))::smallint,
       to_char((to_timestamp(w.start_time::double precision / 1000) at time zone 'UTC'), 'FMMonth')
from public.workouts w
where w.user_id is not null
on conflict (date_key) do nothing;

insert into public.recorded_sets
  (workout_id, workout_exercise_id, exercise_listing_id, owner, date_key,
   set_number, repetitions, weight, is_warmup, is_completed, notes)
select w.id,
       we.workout_exercise_id,
       we.exercise_listing_id,
       w.user_id,
       to_char((to_timestamp(w.start_time::double precision / 1000) at time zone 'UTC')::date, 'YYYYMMDD')::integer,
       set_item.ordinality::integer,
       nullif(set_item.item->>'reps', '')::integer,
       nullif(set_item.item->>'weight', '')::numeric,
       coalesce((set_item.item->>'isWarmup')::boolean, false),
       true,
       nullif(set_item.item->>'notes', '')
from public.workouts w
cross join lateral jsonb_array_elements(coalesce(w.exercises, '[]'::jsonb))
  with ordinality as ex(item, ordinality)
cross join lateral jsonb_array_elements(coalesce(ex.item->'sets', '[]'::jsonb))
  with ordinality as set_item(item, ordinality)
join public.workout_exercises we
  on we.workout_id = w.id
 and we.owner = w.user_id
 and we.exercise_order = ex.ordinality::integer
where w.user_id is not null
  and lower(coalesce(ex.item->>'type', 'strength')) = 'strength'
  and set_item.item->>'done' = 'true'
on conflict (workout_exercise_id, set_number) do nothing;

update public.workouts w
set volume = coalesce((
  select sum(coalesce(rs.weight, 0) * coalesce(rs.repetitions, 0))
  from public.recorded_sets rs
  where rs.workout_id = w.id and rs.owner = w.user_id
), 0)
where w.user_id is not null;

create or replace function public.save_completed_workout(p_workout jsonb, p_exercises jsonb)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_owner uuid := auth.uid();
  v_exercise jsonb;
  v_set jsonb;
  v_listing_id uuid;
  v_exercise_type text;
  v_has_completed boolean := false;
  v_volume numeric := 0;
  v_workout_id text;
  v_workout_exercise_id uuid;
  v_order integer := 0;
  v_set_number integer;
  v_workout_date date;
  v_date_key integer;
begin
  if v_owner is null then
    raise exception 'Authentication is required to save a workout.';
  end if;
  if jsonb_typeof(p_exercises) <> 'array' then
    raise exception 'Workout exercises must be an array.';
  end if;

  for v_exercise in select value from jsonb_array_elements(p_exercises)
  loop
    v_listing_id := nullif(v_exercise->>'exercise_listing_id', '')::uuid;
    select exercise_type into v_exercise_type
      from public.exercise_listing
      where exercise_listing_id = v_listing_id
        and (user_id is null or user_id = v_owner);
    if not found then
      raise exception 'Exercise is missing or not available to this account.';
    end if;

    if v_exercise_type = 'strength' then
      for v_set in select value from jsonb_array_elements(coalesce(v_exercise->'sets', '[]'::jsonb))
      loop
        if v_set->>'done' = 'true' then
          v_has_completed := true;
          v_volume := v_volume
            + coalesce(nullif(v_set->>'weight', '')::numeric, 0)
            * coalesce(nullif(v_set->>'reps', '')::integer, 0);
        end if;
      end loop;
    elsif v_exercise_type = 'cardio' and v_exercise->>'completed' = 'true' then
      v_has_completed := true;
    end if;
  end loop;

  if not v_has_completed then
    raise exception 'Complete a strength set or mark a cardio entry complete before finishing.';
  end if;

  v_workout_date := (to_timestamp((p_workout->>'start_time')::double precision / 1000) at time zone 'UTC')::date;
  v_date_key := to_char(v_workout_date, 'YYYYMMDD')::integer;
  insert into public.date_dimension
    (date_key, calendar_date, calendar_year, iso_year, quarter, month, day_of_month,
     week_of_year, iso_day_of_week, month_name)
  values
    (v_date_key, v_workout_date, extract(year from v_workout_date)::smallint,
     extract(isoyear from v_workout_date)::smallint,
     extract(quarter from v_workout_date)::smallint, extract(month from v_workout_date)::smallint,
     extract(day from v_workout_date)::smallint, extract(week from v_workout_date)::smallint,
     extract(isodow from v_workout_date)::smallint, to_char(v_workout_date, 'FMMonth'))
  on conflict (date_key) do nothing;

  insert into public.workouts
    (id, user_id, name, start_time, end_time, duration, volume, exercises)
  values
    (p_workout->>'id', v_owner, p_workout->>'name',
     (p_workout->>'start_time')::bigint, (p_workout->>'end_time')::bigint,
     coalesce((p_workout->>'duration')::integer, 0), v_volume, '[]'::jsonb)
  returning id into v_workout_id;

  for v_exercise in select value from jsonb_array_elements(p_exercises)
  loop
    v_listing_id := (v_exercise->>'exercise_listing_id')::uuid;
    select exercise_type into v_exercise_type
      from public.exercise_listing
      where exercise_listing_id = v_listing_id
        and (user_id is null or user_id = v_owner);
    v_order := v_order + 1;

    if v_exercise_type = 'strength' then
      if not exists (
        select 1 from jsonb_array_elements(coalesce(v_exercise->'sets', '[]'::jsonb)) s
        where s->>'done' = 'true'
      ) then
        continue;
      end if;
      insert into public.workout_exercises
        (workout_id, exercise_listing_id, owner, exercise_order, is_completed)
      values (v_workout_id, v_listing_id, v_owner, v_order, true)
      returning workout_exercise_id into v_workout_exercise_id;

      v_set_number := 0;
      for v_set in select value from jsonb_array_elements(coalesce(v_exercise->'sets', '[]'::jsonb))
      loop
        v_set_number := v_set_number + 1;
        if v_set->>'done' is distinct from 'true' then
          continue;
        end if;
        v_set_number := coalesce(nullif(v_set->>'set_number', '')::integer, v_set_number);
        insert into public.recorded_sets
          (workout_id, workout_exercise_id, exercise_listing_id, owner, date_key,
           set_number, repetitions, weight, is_warmup, is_completed, notes)
        values
          (v_workout_id, v_workout_exercise_id, v_listing_id, v_owner,
           v_date_key,
           v_set_number, nullif(v_set->>'reps', '')::integer,
           nullif(v_set->>'weight', '')::numeric,
           coalesce((v_set->>'isWarmup')::boolean, false), true,
           nullif(v_set->>'notes', ''));
      end loop;
    elsif v_exercise_type = 'cardio' and v_exercise->>'completed' = 'true' then
      insert into public.workout_exercises
        (workout_id, exercise_listing_id, owner, exercise_order, is_completed,
         duration_minutes, distance_km, calories)
      values
        (v_workout_id, v_listing_id, v_owner, v_order, true,
         nullif(v_exercise->>'duration', '')::numeric,
         nullif(v_exercise->>'distance', '')::numeric,
         nullif(v_exercise->>'calories', '')::integer);
    end if;
  end loop;

  return v_workout_id::text;
end;
$$;

revoke all on function public.save_completed_workout(jsonb, jsonb) from public, anon;
grant execute on function public.save_completed_workout(jsonb, jsonb) to authenticated;

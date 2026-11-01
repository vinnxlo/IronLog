begin;

do $$
begin
  if to_regclass('public.workout_plans') is null then
    raise exception 'Apply the earlier user workout plans migration before this migration.';
  end if;
end;
$$;

create table if not exists public.plan_workouts (
  user_id uuid not null,
  plan_id text not null,
  id text not null check (length(trim(id)) > 0),
  name text not null check (length(trim(name)) > 0),
  workout_order integer not null check (workout_order >= 0),
  primary key (user_id, plan_id, id),
  unique (user_id, id),
  foreign key (user_id, plan_id)
    references public.workout_plans(user_id, id) on delete cascade
);

create table if not exists public.plan_exercises (
  plan_exercise_id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  plan_id text not null,
  plan_workout_id text not null,
  exercise_listing_id uuid not null references public.exercise_listing(exercise_listing_id),
  exercise_order integer not null check (exercise_order > 0),
  prescription jsonb not null default '{}'::jsonb
    check (jsonb_typeof(prescription) = 'object'),
  unique (user_id, plan_id, plan_workout_id, exercise_order),
  foreign key (user_id, plan_id, plan_workout_id)
    references public.plan_workouts(user_id, plan_id, id) on delete cascade
);

create index if not exists plan_workouts_owner_order_idx
  on public.plan_workouts(user_id, plan_id, workout_order);

create index if not exists plan_exercises_owner_workout_idx
  on public.plan_exercises(user_id, plan_id, plan_workout_id, exercise_order);

alter table public.plan_workouts enable row level security;
alter table public.plan_exercises enable row level security;

drop policy if exists "Users access their own plan workouts" on public.plan_workouts;
create policy "Users access their own plan workouts"
  on public.plan_workouts for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Users access their own plan exercises" on public.plan_exercises;
create policy "Users access their own plan exercises"
  on public.plan_exercises for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

grant select, insert, update, delete on public.plan_workouts, public.plan_exercises to authenticated;

create table if not exists public.bts_exercise_id_map (
  bts_exercise_name text primary key,
  exercise_listing_id uuid not null
);

revoke all on public.bts_exercise_id_map from public, anon, authenticated;

insert into public.bts_exercise_id_map (bts_exercise_name, exercise_listing_id) values
  ('45° Incline Barbell Press', '18aede51-071e-59cd-910b-9489cf429579'),
  ('Barbell RDL', 'f6d6005c-ef62-4b18-96e9-d7f00dbc6edf'),
  ('Bayesian Cable Curl', 'c2c67465-49d4-54be-90c1-5b28b827188e'),
  ('Bench Press', 'd7478359-1866-57fe-99e7-ee0729af8ed6'),
  ('Bicep Curls', '7cf5ffeb-acc6-53f4-957e-17dd2763758c'),
  ('Bottom-Half DB Flye', '4479c5f8-c5e2-4e04-9b52-a33bd2567a70'),
  ('Cable Crossover', 'bbe43faf-34a1-4e5e-b4b4-1ff690a974b3'),
  ('Cable Crunch', '0500b4b4-6cbb-4f47-b3e0-ba5267f44894'),
  ('Cable Triceps Kickback', 'ed37771c-b68a-5922-a2fd-67c24df678d3'),
  ('Calf Raises', 'c7819681-2ea0-5762-ba04-d57ef9d806f4'),
  ('Chest-Supported Machine Row', '5ed15f67-9e2c-4e29-b6c3-616e775dedd4'),
  ('DB Bulgarian Split Squat', '489a41e9-467f-5cac-9133-fb763ae489bf'),
  ('EZ-Bar Curl', '95b2db37-1d98-48af-8424-12329d143cf0'),
  ('Face Pulls', 'bd2e20bf-8574-5a87-b7a4-5d53d904142f'),
  ('High-Cable Lateral Raise', 'ad83b8cd-6803-5568-9d5c-886522873592'),
  ('Leg Extension', 'f071a975-f903-49ed-94f0-0ff86f3aa84e'),
  ('Leg Press', 'd8a04e26-c7b9-43f6-9a46-c168ddeb96f2'),
  ('Lying Leg Curl', '00453f74-ebb7-4c00-adbb-cb2f480c4931'),
  ('Machine Hip Abduction', '2ce5dbac-d6b9-444f-80ba-735047a367c7'),
  ('Machine Hip Adduction', '10bb0915-ed0d-5b0d-93f0-8c68171772ad'),
  ('Machine Shoulder Press', '39266bf8-200b-4cbd-b075-de75bbb5cf9d'),
  ('Machine Shrug', '73f403b7-0614-5b02-b7ab-f520e34228e1'),
  ('Neutral-Grip Lat Pulldown', '80721c17-187e-5be3-9bda-c794ed8c8bd7'),
  ('Overhead Cable Triceps Extension', 'b779b8ab-c4c9-4228-8485-64dd5bccb9d9'),
  ('Pendlay Row', 'e2e0c7ae-0239-4d4b-99b5-6eb34a71e281'),
  ('Roman Chair Leg Raise', 'b48666e7-6dba-5dfa-9384-f9c4f5dbc0e0'),
  ('Seated Rows', 'a32e4204-c125-5138-b897-efc66dfc038e'),
  ('Smith Machine Squat', '2a2b8937-c15e-44a5-9a9a-c52540137eda'),
  ('Wide-Grip Pull-Up', 'fcec4a65-9c3a-58ba-bffd-72e294a7b35c')
on conflict (bts_exercise_name) do update
set exercise_listing_id = excluded.exercise_listing_id;

do $$
declare
  v_invalid text;
begin
  select string_agg(m.bts_exercise_name, ', ' order by m.bts_exercise_name)
    into v_invalid
  from public.bts_exercise_id_map m
  left join public.exercise_listing e
    on e.exercise_listing_id = m.exercise_listing_id
  where e.exercise_listing_id is null
     or e.user_id is not null
     or e.exercise_type <> 'strength'
     or e.is_active is distinct from true;

  if v_invalid is not null then
    raise exception 'BTS catalog mapping is missing, inactive, non-shared, or not strength type: %', v_invalid;
  end if;
end;
$$;

create table if not exists public.user_plan_seed_status (
  user_id uuid primary key references auth.users(id) on delete cascade,
  bts_seeded_at timestamptz not null default now()
);

revoke all on public.user_plan_seed_status from public, anon, authenticated;

create or replace function public.assert_plan_exercise_owner()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_listing_owner uuid;
begin
  select user_id into v_listing_owner
  from public.exercise_listing
  where exercise_listing_id = new.exercise_listing_id;
  if not found then
    raise exception 'Plan exercise references a missing exercise catalog row.';
  end if;
  if v_listing_owner is not null and v_listing_owner <> new.user_id then
    raise exception 'A plan can reference only shared exercises or exercises owned by its user.';
  end if;
  return new;
end;
$$;

drop trigger if exists plan_exercises_listing_owner_check on public.plan_exercises;
create trigger plan_exercises_listing_owner_check
  before insert or update on public.plan_exercises
  for each row execute function public.assert_plan_exercise_owner();

create or replace function public.resolve_plan_exercise_listing_id(
  p_plan_id text,
  p_exercise_name text,
  p_exercise_listing_id text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_owner uuid := auth.uid();
  v_listing_id uuid;
begin
  if v_owner is null then
    raise exception 'Authentication is required to resolve plan exercises.';
  end if;

  if p_plan_id = 'bts_foundation' then
    select exercise_listing_id into v_listing_id
    from public.bts_exercise_id_map
    where bts_exercise_name = p_exercise_name;
    if found then return v_listing_id; end if;
    raise exception 'No approved catalog mapping exists for BTS exercise "%".', p_exercise_name;
  end if;

  if nullif(p_exercise_listing_id, '') is not null then
    begin
      v_listing_id := p_exercise_listing_id::uuid;
    exception when invalid_text_representation then
      raise exception 'Invalid exercise catalog ID for plan exercise "%".', p_exercise_name;
    end;
    if exists (
      select 1 from public.exercise_listing e
      where e.exercise_listing_id = v_listing_id
        and (e.user_id is null or e.user_id = v_owner)
    ) then
      return v_listing_id;
    end if;
    raise exception 'Exercise catalog ID % is unavailable to this account.', v_listing_id;
  end if;

  select e.exercise_listing_id into v_listing_id
  from public.exercise_listing e
  where lower(e.name) = lower(p_exercise_name)
    and e.is_active = true
    and (e.user_id is null or e.user_id = v_owner)
  order by (e.user_id = v_owner) desc nulls last
  limit 1;
  if not found then
    raise exception 'No active exercise catalog entry matches "%". Add or select an exercise before importing this plan.', p_exercise_name;
  end if;
  return v_listing_id;
end;
$$;

create or replace function public.import_user_workout_plans(p_plans jsonb)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_owner uuid := auth.uid();
  v_plan jsonb;
  v_workout jsonb;
  v_exercise jsonb;
  v_plan_id text;
  v_exercise_id uuid;
  v_workout_order integer;
  v_exercise_order integer;
  v_inserted_id text;
begin
  if v_owner is null then raise exception 'Authentication is required to import plans.'; end if;
  if jsonb_typeof(p_plans) <> 'array' then raise exception 'Plans must be supplied as an array.'; end if;

  for v_plan in select value from jsonb_array_elements(p_plans)
  loop
    v_plan_id := nullif(v_plan->>'id', '');
    if v_plan_id is null or nullif(trim(v_plan->>'name'), '') is null then
      raise exception 'An imported plan is missing its ID or name.';
    end if;

    v_inserted_id := null;
    insert into public.workout_plans(user_id, id, name, workouts, plan_order)
    values (v_owner, v_plan_id, trim(v_plan->>'name'), '[]'::jsonb,
      coalesce(nullif(v_plan->>'plan_order', '')::integer, 0))
    on conflict (user_id, id) do nothing
    returning id into v_inserted_id;
    if v_inserted_id is null then continue; end if;

    v_workout_order := 0;
    for v_workout in select value from jsonb_array_elements(coalesce(v_plan->'workouts', '[]'::jsonb))
    loop
      v_workout_order := v_workout_order + 1;
      if nullif(v_workout->>'id', '') is null or nullif(trim(v_workout->>'name'), '') is null then
        raise exception 'An imported workout in plan "%" is missing its ID or name.', v_plan_id;
      end if;
      insert into public.plan_workouts(user_id, plan_id, id, name, workout_order)
      values (v_owner, v_plan_id, v_workout->>'id', trim(v_workout->>'name'), v_workout_order - 1);

      v_exercise_order := 0;
      for v_exercise in select value from jsonb_array_elements(coalesce(v_workout->'exercises', '[]'::jsonb))
      loop
        v_exercise_order := v_exercise_order + 1;
        v_exercise_id := public.resolve_plan_exercise_listing_id(
          v_plan_id, v_exercise->>'name', v_exercise->>'exerciseListingId'
        );
        insert into public.plan_exercises
          (user_id, plan_id, plan_workout_id, exercise_listing_id, exercise_order, prescription)
        values (
          v_owner, v_plan_id, v_workout->>'id', v_exercise_id, v_exercise_order,
          v_exercise - 'name' - 'type' - 'category' - 'exerciseListingId'
        );
      end loop;
    end loop;
  end loop;
end;
$$;

create or replace function public.save_user_workout_plans(p_plans jsonb)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_owner uuid := auth.uid();
  v_plan jsonb;
  v_workout jsonb;
  v_exercise jsonb;
  v_plan_id text;
  v_exercise_id uuid;
  v_plan_order integer := 0;
  v_workout_order integer;
  v_exercise_order integer;
begin
  if v_owner is null then raise exception 'Authentication is required to save plans.'; end if;
  if jsonb_typeof(p_plans) <> 'array' then raise exception 'Plans must be supplied as an array.'; end if;

  for v_plan in select value from jsonb_array_elements(p_plans)
  loop
    v_plan_id := nullif(v_plan->>'id', '');
    if v_plan_id is null or nullif(trim(v_plan->>'name'), '') is null then
      raise exception 'A plan is missing its ID or name.';
    end if;
    insert into public.workout_plans(user_id, id, name, workouts, plan_order, updated_at)
    values (v_owner, v_plan_id, trim(v_plan->>'name'), '[]'::jsonb, v_plan_order, now())
    on conflict (user_id, id) do update
      set name = excluded.name, plan_order = excluded.plan_order, updated_at = now();
    v_plan_order := v_plan_order + 1;
  end loop;

  delete from public.workout_plans p
  where p.user_id = v_owner
    and not exists (
      select 1 from jsonb_array_elements(p_plans) supplied
      where supplied->>'id' = p.id
    );

  delete from public.plan_workouts where user_id = v_owner;

  for v_plan in select value from jsonb_array_elements(p_plans)
  loop
    v_plan_id := v_plan->>'id';
    v_workout_order := 0;
    for v_workout in select value from jsonb_array_elements(coalesce(v_plan->'workouts', '[]'::jsonb))
    loop
      if nullif(v_workout->>'id', '') is null or nullif(trim(v_workout->>'name'), '') is null then
        raise exception 'A workout in plan "%" is missing its ID or name.', v_plan_id;
      end if;
      insert into public.plan_workouts(user_id, plan_id, id, name, workout_order)
      values (v_owner, v_plan_id, v_workout->>'id', trim(v_workout->>'name'), v_workout_order);
      v_workout_order := v_workout_order + 1;

      v_exercise_order := 0;
      for v_exercise in select value from jsonb_array_elements(coalesce(v_workout->'exercises', '[]'::jsonb))
      loop
        v_exercise_order := v_exercise_order + 1;
        v_exercise_id := public.resolve_plan_exercise_listing_id(
          v_plan_id, v_exercise->>'name', v_exercise->>'exerciseListingId'
        );
        insert into public.plan_exercises
          (user_id, plan_id, plan_workout_id, exercise_listing_id, exercise_order, prescription)
        values (
          v_owner, v_plan_id, v_workout->>'id', v_exercise_id, v_exercise_order,
          v_exercise - 'name' - 'type' - 'category' - 'exerciseListingId'
        );
      end loop;
    end loop;
  end loop;
end;
$$;

create or replace function public.ensure_user_bts_workout_plan()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_owner uuid := auth.uid();
  v_plan_id text := 'bts_foundation';
  v_workout record;
  v_exercise record;
  v_exercise_order integer;
begin
  if v_owner is null then raise exception 'Authentication is required to create a workout plan.'; end if;
  if exists (select 1 from public.user_plan_seed_status where user_id = v_owner) then return; end if;

  insert into public.workout_plans(user_id, id, name, workouts, plan_order)
  values (v_owner, v_plan_id, 'BTS — Foundation Block', '[]'::jsonb, -1)
  on conflict (user_id, id) do nothing;

  if not exists (
    select 1 from public.plan_workouts
    where user_id = v_owner and plan_id = v_plan_id
  ) then
    for v_workout in
      select * from (values
        ('bts_upper_str', 'Upper — Strength', 0),
        ('bts_lower_str', 'Lower — Strength', 1),
        ('bts_pull_hyp', 'Pull — Hypertrophy', 2),
        ('bts_push_hyp', 'Push — Hypertrophy', 3),
        ('bts_legs_hyp', 'Legs — Hypertrophy', 4)
      ) as w(id, name, workout_order)
    loop
      insert into public.plan_workouts(user_id, plan_id, id, name, workout_order)
      values (v_owner, v_plan_id, v_workout.id, v_workout.name, v_workout.workout_order);

      v_exercise_order := 0;
      for v_exercise in
        select * from (values
          ('bts_upper_str','45° Incline Barbell Press','1 sec pause at bottom of each rep while maintaining tension on pecs',7,2),
          ('bts_upper_str','Cable Crossover','Ladder: one set low cable, one set medium, one set high position',9,2),
          ('bts_upper_str','Wide-Grip Pull-Up','1.5× shoulder width overhand grip. Slow 2–3 sec negative',9,2),
          ('bts_upper_str','High-Cable Lateral Raise','Focus on squeezing your lateral delt to move the weight',9,2),
          ('bts_upper_str','Pendlay Row','Stand on a bumper plate. Big stretch — touch stomach/chest each rep',7,2),
          ('bts_upper_str','Overhead Cable Triceps Extension','Optionally pause 0.5–1 sec in the stretched position each rep',9,2),
          ('bts_upper_str','Bayesian Cable Curl','If left-right imbalance: do one arm at a time, weaker arm first',9,2),
          ('bts_lower_str','Lying Leg Curl','Set machine for maximum stretch at bottom. Prevent butt from popping up',9,2),
          ('bts_lower_str','Smith Machine Squat','Feet forward 3–6 inches from normal squat position for more quad focus',7,2),
          ('bts_lower_str','Barbell RDL','Stop ~75% of the way to lockout — stay in the bottom ¾ of ROM',7,2),
          ('bts_lower_str','Leg Extension','Grab handles hard to pull butt into seat. 2–3 sec negative',9,2),
          ('bts_lower_str','Calf Raises','1–2 sec pause at bottom. Roll ankle back and forth on balls of feet',7,2),
          ('bts_lower_str','Cable Crunch','Round lower back as you crunch. Mind-muscle with your abs',9,2),
          ('bts_pull_hyp','Neutral-Grip Lat Pulldown','Handle more out in front — cross between pullover and pulldown. Feel the lats',9,2),
          ('bts_pull_hyp','Chest-Supported Machine Row','Flare elbows at ~45°. Squeeze shoulder blades together hard at top',9,2),
          ('bts_pull_hyp','Seated Rows','Focus on squeezing shoulder blades, driving elbows down and back',11,2),
          ('bts_pull_hyp','Face Pulls','Pause 1–2 sec in the squeeze. Contract rear delts hard',11,2),
          ('bts_pull_hyp','Machine Shrug','Brief pause at top. Think about pulling shoulders up to ears',11,2),
          ('bts_pull_hyp','EZ-Bar Curl','Set cable at lowest position. Constant tension on biceps. Slow, controlled',11,2),
          ('bts_pull_hyp','Bicep Curls','Smooth, controlled reps. Strong mind-muscle connection with the biceps',13,1),
          ('bts_push_hyp','Bench Press','Comfortable arch, quick pause on chest, explode up each rep',9,2),
          ('bts_push_hyp','Machine Shoulder Press','Elbows break at least 90°. Mind-muscle with delts. Smooth, controlled',9,2),
          ('bts_push_hyp','Bottom-Half DB Flye','All reps in bottom half of ROM only. Deep stretch in pecs each rep',11,2),
          ('bts_push_hyp','High-Cable Lateral Raise','Focus on squeezing your lateral delt to move the weight',11,2),
          ('bts_push_hyp','Overhead Cable Triceps Extension','Optionally pause 0.5–1 sec in the stretched position each rep',11,2),
          ('bts_push_hyp','Cable Triceps Kickback','Shoulder positioned back behind torso in full squeeze position',13,1),
          ('bts_push_hyp','Roman Chair Leg Raise','Allow lower back to round as you curl legs up. Go until listed RPE',15,2),
          ('bts_legs_hyp','Leg Press','Feet lower on platform for quad focus. Deep as possible without back rounding. Pause at bottom',9,2),
          ('bts_legs_hyp','Lying Leg Curl','Lean forward over machine for maximum hamstring stretch',11,2),
          ('bts_legs_hyp','DB Bulgarian Split Squat','Lower until front thigh is parallel to ground. Drive through front heel',9,2),
          ('bts_legs_hyp','Leg Extension','Grab handles to pull butt into seat. 2–3 sec negative. Feel quads pulling apart',11,2),
          ('bts_legs_hyp','Machine Hip Adduction','Mind-muscle with inner thighs. Push hard — great for front thigh mass',11,2),
          ('bts_legs_hyp','Machine Hip Abduction','Use pads if possible to increase ROM. Lean forward, grab rails to stretch glutes',11,2),
          ('bts_legs_hyp','Calf Raises','1–2 sec pause at bottom. Roll ankle back and forth on balls of feet',11,2)
        ) as e(workout_id, name, notes, reps, set_count)
        where e.workout_id = v_workout.id
      loop
        v_exercise_order := v_exercise_order + 1;
        insert into public.plan_exercises
          (user_id, plan_id, plan_workout_id, exercise_listing_id, exercise_order, prescription)
        select
          v_owner, v_plan_id, v_workout.id, m.exercise_listing_id, v_exercise_order,
          jsonb_build_object(
            'notes', v_exercise.notes,
            'warmupSets', 1,
            'setConfigs', (
              select jsonb_agg(
                jsonb_build_object('mode', 'weight', 'weight', '', 'reps', v_exercise.reps, 'pct1rm', 75)
                order by generated.set_number
              )
              from generate_series(1, v_exercise.set_count) as generated(set_number)
            )
          )
        from public.bts_exercise_id_map m
        where m.bts_exercise_name = v_exercise.name;
        if not found then
          raise exception 'No approved catalog mapping exists for BTS exercise "%".', v_exercise.name;
        end if;
      end loop;
    end loop;
  end if;

  insert into public.user_plan_seed_status(user_id) values (v_owner)
  on conflict (user_id) do nothing;
end;
$$;

create or replace function public.save_completed_workout_with_plan_id(
  p_workout jsonb,
  p_exercises jsonb,
  p_plan_workout_id text
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_owner uuid := auth.uid();
  v_workout_id text;
begin
  if v_owner is null then raise exception 'Authentication is required to save a workout.'; end if;
  if nullif(p_plan_workout_id, '') is not null and not exists (
    select 1 from public.plan_workouts
    where user_id = v_owner and id = p_plan_workout_id
  ) then
    raise exception 'The selected plan workout is not available to this account.';
  end if;

  v_workout_id := public.save_completed_workout(p_workout, p_exercises);
  update public.workouts
    set plan_workout_id = nullif(p_plan_workout_id, '')
    where id = v_workout_id and user_id = v_owner;
  if not found then raise exception 'Could not associate the saved workout with its plan workout.'; end if;
  return v_workout_id;
end;
$$;

revoke all on function public.resolve_plan_exercise_listing_id(text, text, text) from public, anon, authenticated;
revoke all on function public.import_user_workout_plans(jsonb) from public, anon;
revoke all on function public.save_user_workout_plans(jsonb) from public, anon;
revoke all on function public.ensure_user_bts_workout_plan() from public, anon;
revoke all on function public.save_completed_workout_with_plan_id(jsonb, jsonb, text) from public, anon;
revoke all on function public.ensure_bts_workout_plan() from public, anon, authenticated;
grant execute on function public.import_user_workout_plans(jsonb) to authenticated;
grant execute on function public.save_user_workout_plans(jsonb) to authenticated;
grant execute on function public.ensure_user_bts_workout_plan() to authenticated;
grant execute on function public.save_completed_workout_with_plan_id(jsonb, jsonb, text) to authenticated;

do $$
declare
  v_plan record;
  v_workout jsonb;
  v_exercise jsonb;
  v_exercise_id uuid;
  v_workout_order integer;
  v_exercise_order integer;
begin
  for v_plan in
    select user_id, id, workouts
    from public.workout_plans
    where jsonb_typeof(workouts) = 'array'
      and jsonb_array_length(workouts) > 0
  loop
    v_workout_order := 0;
    for v_workout in select value from jsonb_array_elements(v_plan.workouts)
    loop
      insert into public.plan_workouts(user_id, plan_id, id, name, workout_order)
      values (
        v_plan.user_id, v_plan.id, v_workout->>'id', v_workout->>'name', v_workout_order
      )
      on conflict (user_id, plan_id, id) do nothing;
      v_workout_order := v_workout_order + 1;

      v_exercise_order := 0;
      for v_exercise in select value from jsonb_array_elements(coalesce(v_workout->'exercises', '[]'::jsonb))
      loop
        v_exercise_order := v_exercise_order + 1;
        v_exercise_id := null;
        if v_plan.id = 'bts_foundation' then
          select exercise_listing_id into v_exercise_id
          from public.bts_exercise_id_map
          where bts_exercise_name = v_exercise->>'name';
          if not found then
            raise exception 'No approved catalog mapping exists for BTS exercise "%".', v_exercise->>'name';
          end if;
        else
          begin
            v_exercise_id := nullif(v_exercise->>'exerciseListingId', '')::uuid;
          exception when invalid_text_representation then
            v_exercise_id := null;
          end;
          if v_exercise_id is null or not exists (
            select 1 from public.exercise_listing
            where exercise_listing_id = v_exercise_id
              and (user_id is null or user_id = v_plan.user_id)
          ) then
            select exercise_listing_id into v_exercise_id
            from public.exercise_listing
            where lower(name) = lower(v_exercise->>'name')
              and is_active = true
              and (user_id is null or user_id = v_plan.user_id)
            order by (user_id = v_plan.user_id) desc nulls last
            limit 1;
          end if;
        end if;

        if v_exercise_id is null or not exists (
          select 1 from public.exercise_listing
          where exercise_listing_id = v_exercise_id
            and (user_id is null or user_id = v_plan.user_id)
        ) then
          raise exception 'Could not map exercise "%" in existing plan "%" for user %.',
            v_exercise->>'name', v_plan.id, v_plan.user_id;
        end if;

        insert into public.plan_exercises
          (user_id, plan_id, plan_workout_id, exercise_listing_id, exercise_order, prescription)
        values (
          v_plan.user_id, v_plan.id, v_workout->>'id', v_exercise_id, v_exercise_order,
          v_exercise - 'name' - 'type' - 'category' - 'exerciseListingId'
        )
        on conflict (user_id, plan_id, plan_workout_id, exercise_order) do nothing;
      end loop;
    end loop;
    update public.workout_plans set workouts = '[]'::jsonb
    where user_id = v_plan.user_id and id = v_plan.id;
  end loop;
end;
$$;

commit;

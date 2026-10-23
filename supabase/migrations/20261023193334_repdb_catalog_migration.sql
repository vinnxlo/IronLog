-- Apply after 20261023193333_workout_schema.sql and before running scripts/import_repdb_catalog.py.
-- This migration contains schema only; licensed RepDB records are imported locally at runtime.

begin;

do $$
begin
  if to_regclass('public.exercise_listing') is null
     or to_regclass('public.exercise_muscle_groups') is null
     or to_regclass('public.muscle_groups') is null then
    raise exception 'Run 20261023193333_workout_schema.sql before the RepDB catalog migration.';
  end if;
end;
$$;

alter table public.exercise_listing
  add column if not exists source_name text,
  add column if not exists source_exercise_id text,
  add column if not exists category text,
  add column if not exists is_active boolean not null default true,
  add column if not exists equipment text,
  add column if not exists body_part text,
  add column if not exists difficulty text,
  add column if not exists force_type text,
  add column if not exists mechanic text,
  add column if not exists met numeric,
  add column if not exists is_unilateral boolean,
  add column if not exists is_bodyweight boolean,
  add column if not exists goals text[] not null default '{}',
  add column if not exists tags text[] not null default '{}',
  add column if not exists synonyms text[] not null default '{}',
  add column if not exists primary_muscles text[] not null default '{}',
  add column if not exists secondary_muscles text[] not null default '{}',
  add column if not exists localized_names jsonb not null default '{}'::jsonb,
  add column if not exists localized_descriptions jsonb not null default '{}'::jsonb,
  add column if not exists localized_instructions jsonb not null default '{}'::jsonb,
  add column if not exists localized_tips jsonb not null default '{}'::jsonb,
  add column if not exists image_paths jsonb not null default '{}'::jsonb,
  add column if not exists source_data jsonb not null default '{}'::jsonb;

alter table public.exercise_listing
  drop constraint if exists exercise_listing_source_fields_check,
  add constraint exercise_listing_source_fields_check
    check (num_nonnulls(source_name, source_exercise_id) in (0, 2)),
  drop constraint if exists exercise_listing_category_check,
  add constraint exercise_listing_category_check
    check (category is null or category in ('strength', 'cardio', 'olympic', 'plyometrics')),
  drop constraint if exists exercise_listing_category_type_check,
  add constraint exercise_listing_category_type_check
    check (
      category is null
      or (category = 'cardio' and exercise_type = 'cardio')
      or (category in ('strength', 'olympic', 'plyometrics') and exercise_type = 'strength')
    ),
  drop constraint if exists exercise_listing_met_check,
  add constraint exercise_listing_met_check
    check (met is null or met >= 0);

create unique index if not exists exercise_listing_source_id_uidx
  on public.exercise_listing (source_name, source_exercise_id);

alter table public.exercise_muscle_groups
  add column if not exists role text not null default 'primary';

alter table public.exercise_muscle_groups
  drop constraint if exists exercise_muscle_groups_role_check,
  add constraint exercise_muscle_groups_role_check
    check (role in ('primary', 'secondary'));

alter table public.exercise_muscle_groups
  drop constraint if exists exercise_muscle_groups_pkey,
  add constraint exercise_muscle_groups_pkey
    primary key (exercise_listing_id, muscle_group_id, role);

commit;

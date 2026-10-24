alter table public.workouts
  add column if not exists plan_workout_id text;

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
  if v_owner is null then
    raise exception 'Authentication is required to save a workout.';
  end if;

  v_workout_id := public.save_completed_workout(p_workout, p_exercises);
  update public.workouts
    set plan_workout_id = nullif(p_plan_workout_id, '')
    where id = v_workout_id and user_id = v_owner;
  if not found then
    raise exception 'Could not associate the saved workout with its plan workout.';
  end if;

  return v_workout_id;
end;
$$;

revoke all on function public.save_completed_workout_with_plan_id(jsonb, jsonb, text) from public, anon;
grant execute on function public.save_completed_workout_with_plan_id(jsonb, jsonb, text) to authenticated;

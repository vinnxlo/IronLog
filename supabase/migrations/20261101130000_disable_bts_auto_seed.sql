begin;

alter table public.bts_exercise_id_map enable row level security;
alter table public.user_plan_seed_status enable row level security;
revoke all on public.bts_exercise_id_map, public.user_plan_seed_status
  from public, anon, authenticated;

drop function if exists public.ensure_user_bts_workout_plan();
drop function if exists public.ensure_bts_workout_plan();

alter function public.import_user_workout_plans(jsonb) security invoker;
alter function public.save_user_workout_plans(jsonb) security invoker;

grant execute on function public.import_user_workout_plans(jsonb) to authenticated;
grant execute on function public.save_user_workout_plans(jsonb) to authenticated;
grant execute on function public.resolve_plan_exercise_listing_id(text, text, text)
  to authenticated;

commit;

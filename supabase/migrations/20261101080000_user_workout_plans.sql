create table if not exists public.workout_plans (
  user_id uuid not null references auth.users(id) on delete cascade,
  id text not null check (length(trim(id)) > 0),
  name text not null check (length(trim(name)) > 0),
  workouts jsonb not null default '[]'::jsonb
    check (jsonb_typeof(workouts) = 'array'),
  plan_order integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

alter table public.workout_plans enable row level security;

drop policy if exists "Users access their own workout plans" on public.workout_plans;
create policy "Users access their own workout plans"
  on public.workout_plans for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

grant select, insert, update, delete on public.workout_plans to authenticated;

create or replace function public.ensure_bts_workout_plan()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_owner uuid := auth.uid();
begin
  if v_owner is null then
    raise exception 'Authentication is required to create a workout plan.';
  end if;

  insert into public.workout_plans (user_id, id, name, workouts, plan_order)
  values (
    v_owner,
    'bts_foundation',
    'BTS — Foundation Block',
    '[
      {"id":"bts_upper_str","name":"Upper — Strength","exercises":[
        {"name":"45° Incline Barbell Press","type":"strength","notes":"1 sec pause at bottom of each rep while maintaining tension on pecs","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":7,"pct1rm":75},{"mode":"weight","weight":"","reps":7,"pct1rm":75}]},
        {"name":"Cable Crossover","type":"strength","notes":"Ladder: one set low cable, one set medium, one set high position","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"Wide-Grip Pull-Up","type":"strength","notes":"1.5× shoulder width overhand grip. Slow 2–3 sec negative","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"High-Cable Lateral Raise","type":"strength","notes":"Focus on squeezing your lateral delt to move the weight","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"Pendlay Row","type":"strength","notes":"Stand on a bumper plate. Big stretch — touch stomach/chest each rep","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":7,"pct1rm":75},{"mode":"weight","weight":"","reps":7,"pct1rm":75}]},
        {"name":"Overhead Cable Triceps Extension","type":"strength","notes":"Optionally pause 0.5–1 sec in the stretched position each rep","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"Bayesian Cable Curl","type":"strength","notes":"If left-right imbalance: do one arm at a time, weaker arm first","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]}
      ]},
      {"id":"bts_lower_str","name":"Lower — Strength","exercises":[
        {"name":"Lying Leg Curl","type":"strength","notes":"Set machine for maximum stretch at bottom. Prevent butt from popping up","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"Smith Machine Squat","type":"strength","notes":"Feet forward 3–6 inches from normal squat position for more quad focus","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":7,"pct1rm":75},{"mode":"weight","weight":"","reps":7,"pct1rm":75}]},
        {"name":"Barbell RDL","type":"strength","notes":"Stop ~75% of the way to lockout — stay in the bottom ¾ of ROM","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":7,"pct1rm":75},{"mode":"weight","weight":"","reps":7,"pct1rm":75}]},
        {"name":"Leg Extension","type":"strength","notes":"Grab handles hard to pull butt into seat. 2–3 sec negative","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"Calf Raises","type":"strength","notes":"1–2 sec pause at bottom. Roll ankle back and forth on balls of feet","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":7,"pct1rm":75},{"mode":"weight","weight":"","reps":7,"pct1rm":75}]},
        {"name":"Cable Crunch","type":"strength","notes":"Round lower back as you crunch. Mind-muscle with your abs","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]}
      ]},
      {"id":"bts_pull_hyp","name":"Pull — Hypertrophy","exercises":[
        {"name":"Neutral-Grip Lat Pulldown","type":"strength","notes":"Handle more out in front — cross between pullover and pulldown. Feel the lats","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"Chest-Supported Machine Row","type":"strength","notes":"Flare elbows at ~45°. Squeeze shoulder blades together hard at top","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"Seated Rows","type":"strength","notes":"Focus on squeezing shoulder blades, driving elbows down and back","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]},
        {"name":"Face Pulls","type":"strength","notes":"Pause 1–2 sec in the squeeze. Contract rear delts hard","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]},
        {"name":"Machine Shrug","type":"strength","notes":"Brief pause at top. Think about pulling shoulders up to ears","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]},
        {"name":"EZ-Bar Curl","type":"strength","notes":"Set cable at lowest position. Constant tension on biceps. Slow, controlled","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]},
        {"name":"Bicep Curls","type":"strength","notes":"Smooth, controlled reps. Strong mind-muscle connection with the biceps","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":13,"pct1rm":75}]}
      ]},
      {"id":"bts_push_hyp","name":"Push — Hypertrophy","exercises":[
        {"name":"Bench Press","type":"strength","notes":"Comfortable arch, quick pause on chest, explode up each rep","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"Machine Shoulder Press","type":"strength","notes":"Elbows break at least 90°. Mind-muscle with delts. Smooth, controlled","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"Bottom-Half DB Flye","type":"strength","notes":"All reps in bottom half of ROM only. Deep stretch in pecs each rep","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]},
        {"name":"High-Cable Lateral Raise","type":"strength","notes":"Focus on squeezing your lateral delt to move the weight","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]},
        {"name":"Overhead Cable Triceps Extension","type":"strength","notes":"Optionally pause 0.5–1 sec in the stretched position each rep","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]},
        {"name":"Cable Triceps Kickback","type":"strength","notes":"Shoulder positioned back behind torso in full squeeze position","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":13,"pct1rm":75}]},
        {"name":"Roman Chair Leg Raise","type":"strength","notes":"Allow lower back to round as you curl legs up. Go until listed RPE","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":15,"pct1rm":75},{"mode":"weight","weight":"","reps":15,"pct1rm":75}]}
      ]},
      {"id":"bts_legs_hyp","name":"Legs — Hypertrophy","exercises":[
        {"name":"Leg Press","type":"strength","notes":"Feet lower on platform for quad focus. Deep as possible without back rounding. Pause at bottom","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"Lying Leg Curl","type":"strength","notes":"Lean forward over machine for maximum hamstring stretch","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]},
        {"name":"DB Bulgarian Split Squat","type":"strength","notes":"Lower until front thigh is parallel to ground. Drive through front heel","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":9,"pct1rm":75},{"mode":"weight","weight":"","reps":9,"pct1rm":75}]},
        {"name":"Leg Extension","type":"strength","notes":"Grab handles to pull butt into seat. 2–3 sec negative. Feel quads pulling apart","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]},
        {"name":"Machine Hip Adduction","type":"strength","notes":"Mind-muscle with inner thighs. Push hard — great for front thigh mass","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]},
        {"name":"Machine Hip Abduction","type":"strength","notes":"Use pads if possible to increase ROM. Lean forward, grab rails to stretch glutes","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]},
        {"name":"Calf Raises","type":"strength","notes":"1–2 sec pause at bottom. Roll ankle back and forth on balls of feet","warmupSets":1,"setConfigs":[{"mode":"weight","weight":"","reps":11,"pct1rm":75},{"mode":"weight","weight":"","reps":11,"pct1rm":75}]}
      ]}
    ]'::jsonb,
    -1
  )
  on conflict (user_id, id) do nothing;
end;
$$;

revoke all on function public.ensure_bts_workout_plan() from public, anon;
grant execute on function public.ensure_bts_workout_plan() to authenticated;

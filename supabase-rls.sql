alter table workouts enable row level security;

drop policy if exists "Allow public access" on workouts;
drop policy if exists "Users can only access their own workouts" on workouts;

create policy "Users can only access their own workouts"
on workouts
for all
using (auth.uid() = user_id)
with check (auth.uid() = user_id);
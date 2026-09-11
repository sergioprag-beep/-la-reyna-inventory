-- La Reyna Xpress — Cloud Sync
-- Run this in Supabase SQL Editor.
create table if not exists public.lrx_cloud_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.lrx_cloud_data enable row level security;

create policy "LRX users can read own cloud data"
on public.lrx_cloud_data for select
to authenticated
using (auth.uid() = user_id);

create policy "LRX users can insert own cloud data"
on public.lrx_cloud_data for insert
to authenticated
with check (auth.uid() = user_id);

create policy "LRX users can update own cloud data"
on public.lrx_cloud_data for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

-- Optional: keep updated_at current whenever a row changes.
create or replace function public.lrx_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists lrx_cloud_data_updated_at on public.lrx_cloud_data;
create trigger lrx_cloud_data_updated_at
before update on public.lrx_cloud_data
for each row execute function public.lrx_set_updated_at();

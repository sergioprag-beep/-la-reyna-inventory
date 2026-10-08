-- Shared LRX state. Run this in Supabase SQL Editor as project owner.
create table if not exists public.lrx_app_state (
  id text primary key check (id = 'main'),
  payload jsonb not null,
  revision bigint not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

alter table public.lrx_app_state enable row level security;
revoke all on public.lrx_app_state from anon;
grant select, insert, update on public.lrx_app_state to authenticated;

drop policy if exists "Authenticated LRX users can read shared state" on public.lrx_app_state;
create policy "Authenticated LRX users can read shared state"
  on public.lrx_app_state for select to authenticated using (true);
drop policy if exists "Authenticated LRX users can create shared state" on public.lrx_app_state;
create policy "Authenticated LRX users can create shared state"
  on public.lrx_app_state for insert to authenticated with check (id = 'main');
drop policy if exists "Authenticated LRX users can update shared state" on public.lrx_app_state;
create policy "Authenticated LRX users can update shared state"
  on public.lrx_app_state for update to authenticated using (true) with check (id = 'main');

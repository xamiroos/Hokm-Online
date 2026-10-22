-- Run in Supabase SQL Editor. Never expose service_role keys in browser code.
create table if not exists public.player_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,24}$'),
  display_name text not null check (char_length(display_name) between 1 and 24),
  created_at timestamptz not null default now()
);
alter table public.player_profiles enable row level security;
-- No client-side reads/writes by default. Edge Function uses service role for profile lookup.
revoke all on table public.player_profiles from anon, authenticated;
-- No permissive RLS policies are intentionally created.

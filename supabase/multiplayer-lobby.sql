-- Hokm online lobby v1. Run this whole file in Supabase SQL Editor.
-- This creates new, isolated tables so it does not overwrite any existing hokm_rooms tables.
create extension if not exists pgcrypto;

create table if not exists public.hokm_online_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9]{5,6}$'),
  owner_id uuid not null references auth.users(id) on delete cascade,
  is_public boolean not null default false,
  status text not null default 'waiting' check (status in ('waiting','ready','playing','closed')),
  created_at timestamptz not null default now()
);
create table if not exists public.hokm_online_seats (
  room_id uuid not null references public.hokm_online_rooms(id) on delete cascade,
  seat smallint not null check (seat between 0 and 3),
  user_id uuid references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 24),
  team smallint not null check (team in (0,1)),
  is_bot boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key (room_id, seat),
  check ((is_bot and user_id is null) or (not is_bot and user_id is not null))
);
create unique index if not exists hokm_online_one_seat_per_user on public.hokm_online_seats(room_id,user_id) where user_id is not null;
create index if not exists hokm_online_rooms_public_waiting on public.hokm_online_rooms(is_public,created_at) where status='waiting';

alter table public.hokm_online_rooms enable row level security;
alter table public.hokm_online_seats enable row level security;
drop policy if exists hokm_room_read on public.hokm_online_rooms;
create policy hokm_room_read on public.hokm_online_rooms for select to authenticated using (is_public or owner_id=auth.uid() or exists(select 1 from public.hokm_online_seats s where s.room_id=id and s.user_id=auth.uid()));
drop policy if exists hokm_seat_read on public.hokm_online_seats;
create policy hokm_seat_read on public.hokm_online_seats for select to authenticated using (exists(select 1 from public.hokm_online_rooms r where r.id=room_id and (r.is_public or r.owner_id=auth.uid() or exists(select 1 from public.hokm_online_seats mine where mine.room_id=r.id and mine.user_id=auth.uid()))));
revoke insert,update,delete on public.hokm_online_rooms from anon,authenticated;
revoke insert,update,delete on public.hokm_online_seats from anon,authenticated;
grant select on public.hokm_online_rooms, public.hokm_online_seats to authenticated;

create or replace function public.create_hokm_room(p_display_name text, p_is_public boolean default false)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); rid uuid; rcode text; nm text:=left(trim(coalesce(p_display_name,'')),24); tries int:=0;
begin
 if uid is null then raise exception 'برای ساخت روم ابتدا وارد حساب شو.'; end if;
 if nm='' then raise exception 'اسم نمایشی را وارد کن.'; end if;
 loop
  rcode:=upper(substr(encode(gen_random_bytes(5),'hex'),1,5));
  begin
   insert into public.hokm_online_rooms(code,owner_id,is_public) values(rcode,uid,coalesce(p_is_public,false)) returning id into rid;
   exit;
  exception when unique_violation then tries:=tries+1; if tries>10 then raise exception 'ساخت کد روم ناموفق بود؛ دوباره تلاش کن.'; end if;
  end;
 end loop;
 insert into public.hokm_online_seats(room_id,seat,user_id,display_name,team) values(rid,0,uid,nm,0);
 return jsonb_build_object('room_id',rid,'code',rcode,'seat',0,'team',0);
end $$;

create or replace function public.join_hokm_room(p_code text,p_display_name text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); r public.hokm_online_rooms%rowtype; s int; nm text:=left(trim(coalesce(p_display_name,'')),24);
begin
 if uid is null then raise exception 'برای ورود به روم ابتدا وارد حساب شو.'; end if;
 if nm='' then raise exception 'اسم نمایشی را وارد کن.'; end if;
 select * into r from public.hokm_online_rooms where code=upper(trim(p_code)) and status in ('waiting','ready') for update;
 if not found then raise exception 'روم پیدا نشد یا دیگر در حال انتظار نیست.'; end if;
 if exists(select 1 from public.hokm_online_seats where room_id=r.id and user_id=uid) then
  select seat into s from public.hokm_online_seats where room_id=r.id and user_id=uid;
  return jsonb_build_object('room_id',r.id,'code',r.code,'seat',s);
 end if;
 select x into s from generate_series(0,3) x where not exists(select 1 from public.hokm_online_seats where room_id=r.id and seat=x) order by x limit 1;
 if s is null then raise exception 'این روم پر است.'; end if;
 insert into public.hokm_online_seats(room_id,seat,user_id,display_name,team) values(r.id,s,uid,nm,mod(s,2));
 if (select count(*) from public.hokm_online_seats where room_id=r.id)=4 then update public.hokm_online_rooms set status='ready' where id=r.id; end if;
 return jsonb_build_object('room_id',r.id,'code',r.code,'seat',s,'team',mod(s,2));
end $$;

create or replace function public.choose_hokm_seat(p_room_id uuid,p_seat int,p_team int)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); oldname text; r public.hokm_online_rooms%rowtype;
begin
 if uid is null then raise exception 'ابتدا وارد حساب شو.'; end if;
 if p_seat not between 0 and 3 or p_team not in (0,1) then raise exception 'جایگاه یا تیم نامعتبر است.'; end if;
 select * into r from public.hokm_online_rooms where id=p_room_id and status in ('waiting','ready') for update;
 if not found then raise exception 'این روم دیگر امکان تغییر جایگاه ندارد.'; end if;
 select display_name into oldname from public.hokm_online_seats where room_id=p_room_id and user_id=uid;
 if oldname is null then raise exception 'عضو این روم نیستی.'; end if;
 if exists(select 1 from public.hokm_online_seats where room_id=p_room_id and seat=p_seat and user_id is distinct from uid) then raise exception 'این جایگاه قبلاً گرفته شده؛ یکی دیگر را انتخاب کن.'; end if;
 delete from public.hokm_online_seats where room_id=p_room_id and user_id=uid;
 insert into public.hokm_online_seats(room_id,seat,user_id,display_name,team) values(p_room_id,p_seat,uid,oldname,p_team);
 update public.hokm_online_rooms set status=case when (select count(*) from public.hokm_online_seats where room_id=p_room_id)=4 then 'ready' else 'waiting' end where id=p_room_id;
 return jsonb_build_object('seat',p_seat,'team',p_team);
end $$;

create or replace function public.leave_hokm_room(p_room_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); ownerid uuid;
begin
 if uid is null then return false; end if;
 delete from public.hokm_online_seats where room_id=p_room_id and user_id=uid;
 select owner_id into ownerid from public.hokm_online_rooms where id=p_room_id;
 if ownerid=uid then delete from public.hokm_online_rooms where id=p_room_id; else
  update public.hokm_online_rooms set status='waiting' where id=p_room_id and status='ready';
 end if;
 return true;
end $$;

create or replace function public.fill_hokm_bots(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); ownerid uuid; s int; n int:=0;
begin
 select owner_id into ownerid from public.hokm_online_rooms where id=p_room_id and status in ('waiting','ready') for update;
 if ownerid is null or ownerid<>uid then raise exception 'فقط سازندهٔ روم می‌تواند صندلی خالی را با ربات پر کند.'; end if;
 for s in select x from generate_series(0,3) x where not exists(select 1 from public.hokm_online_seats where room_id=p_room_id and seat=x) order by x loop
  insert into public.hokm_online_seats(room_id,seat,user_id,display_name,team,is_bot) values(p_room_id,s,null,'ربات '||s,mod(s,2),true);
  n:=n+1;
 end loop;
 update public.hokm_online_rooms set status=case when (select count(*) from public.hokm_online_seats where room_id=p_room_id)=4 then 'ready' else 'waiting' end where id=p_room_id;
 return jsonb_build_object('bots_added',n);
end $$;

revoke all on function public.create_hokm_room(text,boolean) from public,anon;
revoke all on function public.join_hokm_room(text,text) from public,anon;
revoke all on function public.choose_hokm_seat(uuid,int,int) from public,anon;
revoke all on function public.leave_hokm_room(uuid) from public,anon;
revoke all on function public.fill_hokm_bots(uuid) from public,anon;
grant execute on function public.create_hokm_room(text,boolean) to authenticated;
grant execute on function public.join_hokm_room(text,text) to authenticated;
grant execute on function public.choose_hokm_seat(uuid,int,int) to authenticated;
grant execute on function public.leave_hokm_room(uuid) to authenticated;
grant execute on function public.fill_hokm_bots(uuid) to authenticated;

-- Enable Realtime for the lobby tables. If a table is already in the publication, ignore duplicate_object.
do $$ begin alter publication supabase_realtime add table public.hokm_online_rooms; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.hokm_online_seats; exception when duplicate_object then null; when undefined_object then null; end $$;

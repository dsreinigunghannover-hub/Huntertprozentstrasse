-- 100 PROZENT STRASSE – Supabase Setup
-- Dieses SQL im Supabase SQL Editor komplett ausführen.

create extension if not exists pgcrypto;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  password_hash text not null,
  owner_token text unique not null,
  accent text not null default 'white',
  created_at timestamptz not null default now()
);

create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  room_slug text not null references public.rooms(slug) on delete cascade,
  name text not null,
  message text,
  link text,
  file_path text,
  file_name text,
  file_type text,
  file_size bigint,
  status text not null default 'pending' check(status in ('pending','approved','played')),
  boosts integer not null default 0,
  street_votes integer not null default 0,
  shit_votes integer not null default 0,
  created_at timestamptz not null default now(),
  played_at timestamptz
);

create table if not exists public.votes (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions(id) on delete cascade,
  voter_id text not null,
  vote_type text not null check(vote_type in ('street','shit')),
  created_at timestamptz not null default now(),
  unique(submission_id,voter_id)
);

alter table public.rooms enable row level security;
alter table public.submissions enable row level security;
alter table public.votes enable row level security;

drop policy if exists "rooms public read" on public.rooms;
create policy "rooms public read" on public.rooms for select to anon,authenticated using (true);

drop policy if exists "submissions public read" on public.submissions;
create policy "submissions public read" on public.submissions for select to anon,authenticated using (true);

drop policy if exists "submissions public insert" on public.submissions;
create policy "submissions public insert" on public.submissions for insert to anon,authenticated with check (true);

-- Storage bucket für MP3/WAV bis 50 MB
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('songs','songs',true,52428800,
array['audio/mpeg','audio/wav','audio/x-wav','audio/wave','audio/ogg','audio/mp4','audio/webm'])
on conflict (id) do update set public=true,file_size_limit=52428800,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "songs public upload" on storage.objects;
create policy "songs public upload" on storage.objects for insert to anon,authenticated
with check (bucket_id='songs');

drop policy if exists "songs public read" on storage.objects;
create policy "songs public read" on storage.objects for select to anon,authenticated
using (bucket_id='songs');

create or replace function public.register_room(p_slug text,p_password text)
returns json language plpgsql security definer set search_path=public
as $$
declare t text;
begin
  if length(p_slug)<3 or length(p_password)<4 then
    raise exception 'Raumname mindestens 3 Zeichen, Passwort mindestens 4 Zeichen';
  end if;
  if exists(select 1 from rooms where slug=p_slug) then
    raise exception 'Dieser Raumname ist bereits vergeben';
  end if;
  t:=encode(gen_random_bytes(24),'hex');
  insert into rooms(slug,password_hash,owner_token) values(p_slug,crypt(p_password,gen_salt('bf')),t);
  return json_build_object('slug',p_slug,'owner_token',t);
end $$;

create or replace function public.login_room(p_slug text,p_password text)
returns json language plpgsql security definer set search_path=public
as $$
declare r rooms;
begin
  select * into r from rooms where slug=p_slug;
  if r.id is null or r.password_hash<>crypt(p_password,r.password_hash) then
    raise exception 'Nutzername oder Passwort falsch';
  end if;
  return json_build_object('slug',r.slug,'owner_token',r.owner_token);
end $$;

create or replace function public.owner_room(p_owner_token text)
returns json language plpgsql security definer set search_path=public
as $$
declare r rooms;
begin
  select * into r from rooms where owner_token=p_owner_token;
  if r.id is null then return null; end if;
  return json_build_object('slug',r.slug,'accent',r.accent);
end $$;

create or replace function public.moderate_submission(p_owner_token text,p_submission_id uuid,p_action text)
returns json language plpgsql security definer set search_path=public
as $$
declare r rooms; s submissions;
begin
  select * into s from submissions where id=p_submission_id;
  select * into r from rooms where slug=s.room_slug and owner_token=p_owner_token;
  if r.id is null then raise exception 'Keine Berechtigung'; end if;
  if p_action='approve' then update submissions set status='approved' where id=p_submission_id;
  elsif p_action='reject' or p_action='delete' then delete from submissions where id=p_submission_id;
  elsif p_action='play' then update submissions set status='played',played_at=now() where id=p_submission_id;
  else raise exception 'Ungültige Aktion'; end if;
  return json_build_object('ok',true);
end $$;

create or replace function public.vote_submission(p_submission_id uuid,p_voter_id text,p_vote_type text)
returns json language plpgsql security definer set search_path=public
as $$
declare v votes;
declare s submissions;
begin
  if p_vote_type not in ('street','shit') then raise exception 'Ungültige Bewertung'; end if;
  insert into votes(submission_id,voter_id,vote_type)
  values(p_submission_id,p_voter_id,p_vote_type)
  on conflict(submission_id,voter_id) do update set vote_type=excluded.vote_type;
  select * into s from submissions where id=p_submission_id;
  update submissions set
    street_votes=(select count(*) from votes where submission_id=p_submission_id and vote_type='street'),
    shit_votes=(select count(*) from votes where submission_id=p_submission_id and vote_type='shit')
  where id=p_submission_id;
  select * into s from submissions where id=p_submission_id;
  return json_build_object('street_votes',s.street_votes,'shit_votes',s.shit_votes);
end $$;

create or replace function public.boost_submission(p_submission_id uuid)
returns json language plpgsql security definer set search_path=public
as $$
begin
  update submissions set boosts=boosts+1 where id=p_submission_id;
  return json_build_object('ok',true);
end $$;

grant execute on function public.register_room(text,text) to anon,authenticated;
grant execute on function public.login_room(text,text) to anon,authenticated;
grant execute on function public.owner_room(text) to anon,authenticated;
grant execute on function public.moderate_submission(text,uuid,text) to anon,authenticated;
grant execute on function public.vote_submission(uuid,text,text) to anon,authenticated;
grant execute on function public.boost_submission(uuid) to anon,authenticated;

-- =====================================================================
-- 1학년 3반 사이트 서버 설정
-- Supabase 대시보드 > SQL Editor > New query 에 이 파일 전체를 붙여넣고 Run.
-- 가입 코드: samban1103 (바꾸려면 아래 값을 수정)
-- =====================================================================

-- 0) 반 가입 코드 (API로는 아무도 읽을 수 없게 잠가 둠)
create table if not exists public.class_settings (
  id int primary key default 1 check (id = 1),
  join_code text not null
);
insert into public.class_settings (id, join_code) values (1, 'samban1103')
  on conflict (id) do update set join_code = excluded.join_code;
alter table public.class_settings enable row level security;

-- 1) 회원 정보
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  nickname text not null,
  role text not null default 'student' check (role in ('student','admin')),
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "profiles_read" on public.profiles for select using (true);

-- 가입할 때 가입 코드를 확인하고, 맞으면 회원 정보를 만든다 (틀리면 가입 자체가 취소됨)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare code text;
begin
  select join_code into code from public.class_settings where id = 1;
  if coalesce(new.raw_user_meta_data->>'join_code','') <> code then
    raise exception 'invalid join code';
  end if;
  insert into public.profiles (id, username, nickname)
  values (new.id,
          new.raw_user_meta_data->>'username',
          coalesce(nullif(new.raw_user_meta_data->>'nickname',''), new.raw_user_meta_data->>'username'));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- 2) 게시물 테이블들
create table if not exists public.assessments (
  id uuid primary key default gen_random_uuid(),
  subject text not null, title text not null, due_date date not null,
  period text, is_makeup boolean not null default false,
  description text, criteria text,
  attachments jsonb not null default '[]',
  criteria_attachments jsonb not null default '[]',
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.notes (
  id uuid primary key default gen_random_uuid(),
  subject text not null, title text not null, body text, note_date date,
  attachments jsonb not null default '[]',
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null, date date not null, memo text,
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.links (
  id uuid primary key default gen_random_uuid(),
  category text not null, title text not null, url text not null, description text,
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  title text not null, body text,
  attachments jsonb not null default '[]',
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  body text not null check (char_length(body) between 1 and 500),
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- 3) 권한: 읽기는 누구나(채팅은 로그인한 사람만), 쓰기는 로그인한 사람,
--    수정·삭제는 쓴 사람 본인 또는 관리자
do $$
declare t text;
begin
  foreach t in array array['assessments','notes','events','links','posts','messages'] loop
    execute format('alter table public.%I enable row level security', t);
    if t = 'messages' then
      execute format('create policy "%1$s_read" on public.%1$I for select to authenticated using (true)', t);
    else
      execute format('create policy "%1$s_read" on public.%1$I for select using (true)', t);
    end if;
    execute format('create policy "%1$s_insert" on public.%1$I for insert to authenticated with check (author_id = auth.uid())', t);
    execute format('create policy "%1$s_update" on public.%1$I for update to authenticated using (author_id = auth.uid() or public.is_admin())', t);
    execute format('create policy "%1$s_delete" on public.%1$I for delete to authenticated using (author_id = auth.uid() or public.is_admin())', t);
  end loop;
end $$;

-- 4) 파일 저장소 (사진·PDF, 파일당 20MB)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('uploads','uploads', true, 20971520,
        array['image/png','image/jpeg','image/gif','image/webp','application/pdf'])
on conflict (id) do nothing;

create policy "uploads_insert_own" on storage.objects for insert to authenticated
  with check (bucket_id = 'uploads' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "uploads_delete_own" on storage.objects for delete to authenticated
  using (bucket_id = 'uploads' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- 5) 실시간 채팅
alter publication supabase_realtime add table public.messages;


-- 6) 학급 사진 (로그인한 사람만 볼 수 있음)
create table if not exists public.photos (
  id uuid primary key default gen_random_uuid(),
  title text not null, taken_date date,
  attachments jsonb not null default '[]',
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.photos enable row level security;
create policy "photos_read" on public.photos for select to authenticated using (true);
create policy "photos_insert" on public.photos for insert to authenticated with check (author_id = auth.uid());
create policy "photos_update" on public.photos for update to authenticated using (author_id = auth.uid() or public.is_admin());
create policy "photos_delete" on public.photos for delete to authenticated using (author_id = auth.uid() or public.is_admin());


-- =====================================================================
-- [나중에 필요할 때만] 따로 실행하는 것들
-- =====================================================================

-- 평가 기준 첨부 칸 추가 (2026-11-03 이전에 설정한 경우 한 번만 실행):
-- alter table public.assessments add column if not exists criteria_attachments jsonb not null default '[]';

-- 관리자 지정 (가입한 뒤 본인 아이디로 바꿔서 실행):
-- update public.profiles set role = 'admin' where username = '내아이디';

-- 가입 코드 바꾸기:
-- update public.class_settings set join_code = '새코드' where id = 1;

-- 로그인한 사람만 내용을 볼 수 있게 잠그기:
-- do $$ declare t text; begin
--   foreach t in array array['assessments','notes','events','links','posts','profiles'] loop
--     execute format('drop policy if exists "%1$s_read" on public.%1$I', t);
--     execute format('create policy "%1$s_read" on public.%1$I for select to authenticated using (true)', t);
--   end loop; end $$;

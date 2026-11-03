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


-- 7) 숙제
create table if not exists public.homework (
  id uuid primary key default gen_random_uuid(),
  subject text not null, title text not null, due_date date not null, memo text,
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.homework enable row level security;
drop policy if exists "homework_read" on public.homework;
drop policy if exists "homework_insert" on public.homework;
drop policy if exists "homework_update" on public.homework;
drop policy if exists "homework_delete" on public.homework;
create policy "homework_read" on public.homework for select using (true);
create policy "homework_insert" on public.homework for insert to authenticated with check (author_id = auth.uid());
create policy "homework_update" on public.homework for update to authenticated using (author_id = auth.uid() or public.is_admin());
create policy "homework_delete" on public.homework for delete to authenticated using (author_id = auth.uid() or public.is_admin());


-- 8) 조회수 · 댓글 · 좋아요

-- 1) 조회수 칸
alter table public.assessments add column if not exists views int not null default 0;
alter table public.notes       add column if not exists views int not null default 0;
alter table public.posts       add column if not exists views int not null default 0;
alter table public.photos      add column if not exists views int not null default 0;

-- 조회수 올리기 (글쓴이가 아니어도 숫자만 1 올릴 수 있게)
create or replace function public.increment_view(tbl text, rid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if tbl not in ('assessments','notes','posts','photos') then
    raise exception 'not allowed';
  end if;
  execute format('update public.%I set views = views + 1 where id = $1', tbl) using rid;
end $$;
grant execute on function public.increment_view(text, uuid) to anon, authenticated;

-- 2) 댓글 · 답글 (게시물 댓글 + 멤버 방명록 공용)
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  target_table text not null check (target_table in ('assessments','notes','posts','photos','profiles')),
  target_id uuid not null,
  parent_id uuid references public.comments(id) on delete cascade,
  reply_to text,
  body text not null check (char_length(body) between 1 and 1000),
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists comments_target_idx on public.comments (target_table, target_id);
alter table public.comments enable row level security;
drop policy if exists "comments_read" on public.comments;
drop policy if exists "comments_insert" on public.comments;
drop policy if exists "comments_delete" on public.comments;
create policy "comments_read" on public.comments for select to authenticated using (true);
create policy "comments_insert" on public.comments for insert to authenticated with check (author_id = auth.uid());
create policy "comments_delete" on public.comments for delete to authenticated using (author_id = auth.uid() or public.is_admin());

-- 3) 좋아요 · 응원 (게시물, 댓글, 멤버 공용)
create table if not exists public.likes (
  target_table text not null check (target_table in ('assessments','notes','posts','photos','comments','profiles')),
  target_id uuid not null,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (target_table, target_id, user_id)
);
alter table public.likes enable row level security;
drop policy if exists "likes_read" on public.likes;
drop policy if exists "likes_insert" on public.likes;
drop policy if exists "likes_delete" on public.likes;
create policy "likes_read" on public.likes for select to authenticated using (true);
create policy "likes_insert" on public.likes for insert to authenticated with check (user_id = auth.uid());
create policy "likes_delete" on public.likes for delete to authenticated using (user_id = auth.uid());

-- 9) 급식 순서 기록 (누구나 볼 수 있고, 로그인한 친구가 기록)
create table if not exists public.meal_order (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  order_no int not null check (order_no between 1 and 50),
  eat_time time,
  memo text,
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists meal_order_date_idx on public.meal_order (date);
alter table public.meal_order enable row level security;
drop policy if exists "meal_order_read" on public.meal_order;
drop policy if exists "meal_order_insert" on public.meal_order;
drop policy if exists "meal_order_delete" on public.meal_order;
create policy "meal_order_read" on public.meal_order for select using (true);
create policy "meal_order_insert" on public.meal_order for insert to authenticated with check (author_id = auth.uid());
create policy "meal_order_delete" on public.meal_order for delete to authenticated using (author_id = auth.uid() or public.is_admin());
-- 10) 시간표 변동 (그날만 바뀐 수업) · 로그인한 친구가 기록
create table if not exists public.tt_changes (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  period int not null check (period between 1 and 10),
  subject text,
  note text,
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists tt_changes_date_idx on public.tt_changes (date);
alter table public.tt_changes enable row level security;
drop policy if exists "tt_changes_read" on public.tt_changes;
drop policy if exists "tt_changes_insert" on public.tt_changes;
drop policy if exists "tt_changes_delete" on public.tt_changes;
create policy "tt_changes_read" on public.tt_changes for select using (true);
create policy "tt_changes_insert" on public.tt_changes for insert to authenticated with check (author_id = auth.uid());
create policy "tt_changes_delete" on public.tt_changes for delete to authenticated using (author_id = auth.uid() or public.is_admin());

-- 11) 기본 시간표 (관리자만 사이트에서 수정)
create table if not exists public.class_timetable (
  id int primary key default 1 check (id = 1),
  data jsonb not null,
  author_id uuid default auth.uid() references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table public.class_timetable enable row level security;
drop policy if exists "class_timetable_read" on public.class_timetable;
drop policy if exists "class_timetable_insert" on public.class_timetable;
drop policy if exists "class_timetable_update" on public.class_timetable;
create policy "class_timetable_read" on public.class_timetable for select using (true);
create policy "class_timetable_insert" on public.class_timetable for insert to authenticated with check (public.is_admin());
create policy "class_timetable_update" on public.class_timetable for update to authenticated using (public.is_admin()) with check (public.is_admin());
-- 12) 공지 (회원 누구나 짧게, 날짜 지나면 홈에서 숨김)
create table if not exists public.notices (
  id uuid primary key default gen_random_uuid(),
  body text not null check (char_length(body) between 1 and 200),
  until date,
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.notices enable row level security;
drop policy if exists "notices_read" on public.notices;
drop policy if exists "notices_insert" on public.notices;
drop policy if exists "notices_delete" on public.notices;
create policy "notices_read" on public.notices for select using (true);
create policy "notices_insert" on public.notices for insert to authenticated with check (author_id = auth.uid());
create policy "notices_delete" on public.notices for delete to authenticated using (author_id = auth.uid() or public.is_admin());

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
--   foreach t in array array['assessments','notes','events','links','posts','homework','profiles'] loop
--     execute format('drop policy if exists "%1$s_read" on public.%1$I', t);
--     execute format('create policy "%1$s_read" on public.%1$I for select to authenticated using (true)', t);
--   end loop; end $$;

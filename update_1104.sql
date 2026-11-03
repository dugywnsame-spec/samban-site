-- 11월 4일 업데이트: 조회수 · 댓글 · 답글 · 좋아요 · 멤버 응원/방명록
-- Supabase SQL Editor에서 이 파일 전체를 한 번 실행 (여러 번 실행해도 괜찮아요)

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

-- 4) 급식 순서 기록 (누구나 볼 수 있고, 로그인한 친구가 기록)
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

-- 5) 시간표 변동 (그날만 바뀐 수업) · 로그인한 친구가 기록
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

-- 6) 기본 시간표 (관리자만 사이트에서 수정)
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

-- 7) 공지 (회원 누구나 짧게, 날짜 지나면 홈에서 숨김)
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

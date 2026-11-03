-- 11월 3일 업데이트: 이미 서버를 설정한 경우 이 파일만 SQL Editor에서 한 번 실행
alter table public.assessments add column if not exists criteria_attachments jsonb not null default '[]';

create table if not exists public.photos (
  id uuid primary key default gen_random_uuid(),
  title text not null, taken_date date,
  attachments jsonb not null default '[]',
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.photos enable row level security;
drop policy if exists "photos_read" on public.photos;
drop policy if exists "photos_insert" on public.photos;
drop policy if exists "photos_update" on public.photos;
drop policy if exists "photos_delete" on public.photos;
create policy "photos_read" on public.photos for select to authenticated using (true);
create policy "photos_insert" on public.photos for insert to authenticated with check (author_id = auth.uid());
create policy "photos_update" on public.photos for update to authenticated using (author_id = auth.uid() or public.is_admin());
create policy "photos_delete" on public.photos for delete to authenticated using (author_id = auth.uid() or public.is_admin());

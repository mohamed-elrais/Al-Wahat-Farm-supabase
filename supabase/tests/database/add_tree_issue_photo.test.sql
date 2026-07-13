begin;

create extension if not exists pgtap with schema extensions;

set local search_path = public, extensions;

create schema if not exists test;

create or replace function test.set_auth(p_user_id uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_user_id::text, ''), true);
  perform set_config(
    'request.jwt.claim.role',
    case when p_user_id is null then '' else 'authenticated' end,
    true
  );
end;
$$;

select plan(13);

select has_function(
  'public',
  'add_tree_issue_photo',
  array['uuid', 'text', 'text'],
  'add_tree_issue_photo RPC exists'
);

insert into auth.users (
  id,
  instance_id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  created_at,
  updated_at,
  raw_app_meta_data,
  raw_user_meta_data
)
values
  (
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'issue-reporter@example.test',
    '',
    now(),
    now(),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Issue Reporter"}'::jsonb
  ),
  (
    '00000000-0000-0000-0000-000000000102',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'issue-manager@example.test',
    '',
    now(),
    now(),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Issue Manager"}'::jsonb
  ),
  (
    '00000000-0000-0000-0000-000000000103',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'unrelated-worker@example.test',
    '',
    now(),
    now(),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Unrelated Worker"}'::jsonb
  );

insert into public.farms (
  id,
  name,
  code
)
values (
  '00000000-0000-0000-0000-000000000201',
  'RPC Test Farm',
  'RPC-TEST'
);

insert into public.farm_sections (
  id,
  farm_id,
  code,
  name,
  sort_order
)
values (
  '00000000-0000-0000-0000-000000000301',
  '00000000-0000-0000-0000-000000000201',
  'A',
  'Section A',
  1
);

insert into public.trees (
  id,
  farm_id,
  section_id,
  tree_code,
  row_number,
  tree_number
)
values (
  '00000000-0000-0000-0000-000000000401',
  '00000000-0000-0000-0000-000000000201',
  '00000000-0000-0000-0000-000000000301',
  'T-001',
  1,
  1
);

insert into public.farm_memberships (
  farm_id,
  profile_id,
  role
)
values
  (
    '00000000-0000-0000-0000-000000000201',
    '00000000-0000-0000-0000-000000000101',
    'worker'
  ),
  (
    '00000000-0000-0000-0000-000000000201',
    '00000000-0000-0000-0000-000000000102',
    'agricultural_engineer'
  );

insert into public.tree_issues (
  id,
  farm_id,
  tree_id,
  issue_type,
  severity,
  status,
  description,
  reported_by_profile_id
)
values (
  '00000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000201',
  '00000000-0000-0000-0000-000000000401',
  'tree_damage',
  'medium',
  'in_review',
  'Broken branch',
  '00000000-0000-0000-0000-000000000101'
);

insert into public.tasks (
  id,
  farm_id,
  tree_id,
  related_tree_issue_id,
  task_type,
  title,
  description,
  priority,
  status,
  requires_engineer_review,
  created_by_profile_id
)
values (
  '00000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000201',
  '00000000-0000-0000-0000-000000000401',
  '00000000-0000-0000-0000-000000000501',
  'engineer_review',
  'Engineer review: Tree Damage',
  'Broken branch',
  'medium',
  'needs_engineer_review',
  true,
  '00000000-0000-0000-0000-000000000101'
);

update public.tree_issues
set linked_task_id = '00000000-0000-0000-0000-000000000601'
where id = '00000000-0000-0000-0000-000000000501';

insert into storage.objects (
  bucket_id,
  name,
  owner,
  metadata
)
values
  (
    'farm-evidence',
    '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/reporter.jpg',
    '00000000-0000-0000-0000-000000000101',
    '{"mimetype":"image/jpeg"}'::jsonb
  ),
  (
    'farm-evidence',
    '00000000-0000-0000-0000-000000000102/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/manager.jpg',
    '00000000-0000-0000-0000-000000000102',
    '{"mimetype":"image/jpeg"}'::jsonb
  ),
  (
    'farm-evidence',
    '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/conflict.jpg',
    '00000000-0000-0000-0000-000000000101',
    '{"mimetype":"image/jpeg"}'::jsonb
  );

select test.set_auth(null);

select throws_ok(
  $$
    select public.add_tree_issue_photo(
      '00000000-0000-0000-0000-000000000501',
      '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/reporter.jpg',
      null
    )
  $$,
  '42501',
  'Authentication is required',
  'unauthenticated callers are rejected'
);

select test.set_auth('00000000-0000-0000-0000-000000000101');

create temporary table test_photo_results (
  label text primary key,
  photo_id uuid not null
) on commit drop;

insert into test_photo_results (label, photo_id)
select
  'reporter',
  public.add_tree_issue_photo(
    '00000000-0000-0000-0000-000000000501',
    '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/reporter.jpg',
    'Reporter photo'
  );

select ok(
  (select photo_id is not null from test_photo_results where label = 'reporter'),
  'reporter can add a tree issue photo'
);

select is(
  (
    select count(*)::integer
    from public.task_photos tp
    where tp.task_id = '00000000-0000-0000-0000-000000000601'
      and tp.storage_path = '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/reporter.jpg'
      and tp.photo_type = 'issue'
      and tp.uploaded_by_profile_id = '00000000-0000-0000-0000-000000000101'
  ),
  1,
  'successful call creates one issue task_photos row'
);

select is(
  (
    select count(*)::integer
    from public.task_activity_log tal
    where tal.task_id = '00000000-0000-0000-0000-000000000601'
      and tal.action = 'photo_added'
      and tal.actor_profile_id = '00000000-0000-0000-0000-000000000101'
      and tal.metadata ->> 'tree_issue_id' = '00000000-0000-0000-0000-000000000501'
      and tal.metadata ->> 'photo_type' = 'issue'
  ),
  1,
  'successful call creates one photo_added activity entry'
);

insert into test_photo_results (label, photo_id)
select
  'reporter_retry',
  public.add_tree_issue_photo(
    '00000000-0000-0000-0000-000000000501',
    '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/reporter.jpg',
    'Retry caption ignored'
  );

select is(
  (select photo_id from test_photo_results where label = 'reporter_retry'),
  (select photo_id from test_photo_results where label = 'reporter'),
  'idempotent retry returns the existing photo id'
);

select is(
  (
    select count(*)::integer
    from public.task_photos tp
    where tp.storage_path = '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/reporter.jpg'
  ),
  1,
  'idempotent retry does not create duplicate task_photos'
);

select is(
  (
    select count(*)::integer
    from public.task_activity_log tal
    where tal.metadata ->> 'storage_path' = '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/reporter.jpg'
      and tal.action = 'photo_added'
  ),
  1,
  'idempotent retry does not create duplicate activity rows'
);

select test.set_auth('00000000-0000-0000-0000-000000000102');

insert into test_photo_results (label, photo_id)
select
  'manager',
  public.add_tree_issue_photo(
    '00000000-0000-0000-0000-000000000501',
    '00000000-0000-0000-0000-000000000102/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/manager.jpg',
    'Manager photo'
  );

select ok(
  (select photo_id is not null from test_photo_results where label = 'manager'),
  'operational farm manager can add a tree issue photo'
);

select test.set_auth('00000000-0000-0000-0000-000000000103');

select throws_ok(
  $$
    select public.add_tree_issue_photo(
      '00000000-0000-0000-0000-000000000501',
      '00000000-0000-0000-0000-000000000103/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/unrelated.jpg',
      null
    )
  $$,
  '42501',
  'You do not have access to this farm',
  'unrelated worker is rejected'
);

select test.set_auth('00000000-0000-0000-0000-000000000101');

select throws_ok(
  $$
    select public.add_tree_issue_photo(
      '00000000-0000-0000-0000-000000000501',
      '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/not-a-task/invalid.jpg',
      null
    )
  $$,
  '23514',
  'Photo path must follow {auth_user_uuid}/{farm_id}/{task_id}/filename',
  'invalid path is rejected'
);

select throws_ok(
  $$
    select public.add_tree_issue_photo(
      '00000000-0000-0000-0000-000000000501',
      '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/missing.jpg',
      null
    )
  $$,
  'P0002',
  'Storage object not found in farm-evidence bucket',
  'missing Storage object is rejected'
);

insert into public.task_photos (
  task_id,
  storage_path,
  photo_type,
  caption,
  uploaded_by_profile_id
)
values (
  '00000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/conflict.jpg',
  'evidence',
  'Existing evidence registration',
  '00000000-0000-0000-0000-000000000101'
);

select throws_ok(
  $$
    select public.add_tree_issue_photo(
      '00000000-0000-0000-0000-000000000501',
      '00000000-0000-0000-0000-000000000101/00000000-0000-0000-0000-000000000201/00000000-0000-0000-0000-000000000601/conflict.jpg',
      null
    )
  $$,
  '23505',
  'Storage path is already registered to different task evidence',
  'path already registered to different evidence is rejected'
);

select * from finish();

rollback;

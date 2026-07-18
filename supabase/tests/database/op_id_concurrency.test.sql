create extension if not exists pgtap with schema extensions;
create extension if not exists dblink with schema extensions;

set search_path = public, extensions;

select plan(16);

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
    '20000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'concurrent-manager@example.test',
    '',
    now(),
    now(),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Concurrent Manager"}'::jsonb
  ),
  (
    '20000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'concurrent-worker@example.test',
    '',
    now(),
    now(),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Concurrent Worker"}'::jsonb
  );

insert into public.farms (id, name, code)
values (
  '20000000-0000-0000-0000-000000000010',
  'Concurrent Op Test Farm',
  'OP-CONCURRENT'
);

insert into public.farm_sections (id, farm_id, code, name, sort_order)
values (
  '20000000-0000-0000-0000-000000000020',
  '20000000-0000-0000-0000-000000000010',
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
  '20000000-0000-0000-0000-000000000030',
  '20000000-0000-0000-0000-000000000010',
  '20000000-0000-0000-0000-000000000020',
  'CONCURRENT-TREE-001',
  1,
  1
);

insert into public.farm_memberships (farm_id, profile_id, role)
values
  (
    '20000000-0000-0000-0000-000000000010',
    '20000000-0000-0000-0000-000000000001',
    'agricultural_engineer'
  ),
  (
    '20000000-0000-0000-0000-000000000010',
    '20000000-0000-0000-0000-000000000002',
    'worker'
  );

select dblink_connect(
  'op_create_a',
  'host=host.docker.internal port=54322 dbname=postgres user=postgres password=postgres'
);
select dblink_connect(
  'op_create_b',
  'host=host.docker.internal port=54322 dbname=postgres user=postgres password=postgres'
);

select dblink_exec('op_create_a', 'set role authenticated');
select dblink_exec('op_create_b', 'set role authenticated');
select dblink_exec('op_create_a', $$set request.jwt.claim.sub = '20000000-0000-0000-0000-000000000001'$$);
select dblink_exec('op_create_b', $$set request.jwt.claim.sub = '20000000-0000-0000-0000-000000000001'$$);
select dblink_exec('op_create_a', 'begin');
select dblink_exec('op_create_b', 'begin');

select dblink_send_query(
  'op_create_a',
  $$
    select public.create_farm_task(
      p_farm_id => '20000000-0000-0000-0000-000000000010',
      p_task_type => 'irrigation',
      p_title => 'Concurrent create task',
      p_assignee_profile_ids => array['20000000-0000-0000-0000-000000000002'::uuid],
      p_op_id => '20000000-0000-0000-0000-000000000101'
    )
  $$
);

create temporary table concurrent_results (
  label text primary key,
  result_id uuid not null
);

insert into concurrent_results (label, result_id)
select 'create_a', result_id
from dblink_get_result('op_create_a') as result(result_id uuid);

select count(*)
from dblink_get_result('op_create_a') as result(result_id uuid);

select dblink_send_query(
  'op_create_b',
  $$
    select public.create_farm_task(
      p_farm_id => '20000000-0000-0000-0000-000000000010',
      p_task_type => 'irrigation',
      p_title => 'Concurrent create task',
      p_assignee_profile_ids => array['20000000-0000-0000-0000-000000000002'::uuid],
      p_op_id => '20000000-0000-0000-0000-000000000101'
    )
  $$
);

select is(
  dblink_is_busy('op_create_b'),
  1,
  'the concurrent create replay waits on the uncommitted unique operation ID'
);

select dblink_exec('op_create_a', 'commit');

insert into concurrent_results (label, result_id)
select 'create_b', result_id
from dblink_get_result('op_create_b') as result(result_id uuid);

select count(*)
from dblink_get_result('op_create_b') as result(result_id uuid);

select dblink_exec('op_create_b', 'commit');

select is(
  (select result_id from concurrent_results where label = 'create_b'),
  (select result_id from concurrent_results where label = 'create_a'),
  'concurrent create calls return the same task id'
);

select is(
  (select count(*)::integer from public.tasks where client_operation_id = '20000000-0000-0000-0000-000000000101'),
  1,
  'concurrent create calls leave one task'
);

select is(
  (
    select count(*)::integer
    from public.task_activity_log
    where task_id = (select result_id from concurrent_results where label = 'create_a')
  ),
  2,
  'concurrent create calls leave one created and one assigned activity'
);

select is(
  (
    select count(*)::integer
    from public.task_assignments
    where task_id = (select result_id from concurrent_results where label = 'create_a')
  ),
  1,
  'concurrent create calls leave one assignment'
);

select dblink_disconnect('op_create_a');
select dblink_disconnect('op_create_b');

select dblink_connect(
  'op_report_a',
  'host=host.docker.internal port=54322 dbname=postgres user=postgres password=postgres'
);
select dblink_connect(
  'op_report_b',
  'host=host.docker.internal port=54322 dbname=postgres user=postgres password=postgres'
);

select dblink_exec('op_report_a', 'set role authenticated');
select dblink_exec('op_report_b', 'set role authenticated');
select dblink_exec('op_report_a', $$set request.jwt.claim.sub = '20000000-0000-0000-0000-000000000001'$$);
select dblink_exec('op_report_b', $$set request.jwt.claim.sub = '20000000-0000-0000-0000-000000000001'$$);
select dblink_exec('op_report_a', 'begin');
select dblink_exec('op_report_b', 'begin');

select dblink_send_query(
  'op_report_a',
  $$
    select *
    from public.report_tree_issue(
      p_tree_id => '20000000-0000-0000-0000-000000000030',
      p_issue_type => 'clogged_dripper',
      p_severity => 'high',
      p_description => 'Concurrent report',
      p_op_id => '20000000-0000-0000-0000-000000000102'
    )
  $$
);

create temporary table concurrent_report_results (
  label text primary key,
  tree_issue_id uuid not null,
  task_id uuid not null
);

insert into concurrent_report_results (label, tree_issue_id, task_id)
select 'report_a', tree_issue_id, task_id
from dblink_get_result('op_report_a')
  as result(tree_issue_id uuid, task_id uuid);

select count(*)
from dblink_get_result('op_report_a')
  as result(tree_issue_id uuid, task_id uuid);

select dblink_send_query(
  'op_report_b',
  $$
    select *
    from public.report_tree_issue(
      p_tree_id => '20000000-0000-0000-0000-000000000030',
      p_issue_type => 'clogged_dripper',
      p_severity => 'high',
      p_description => 'Concurrent report',
      p_op_id => '20000000-0000-0000-0000-000000000102'
    )
  $$
);

select is(
  dblink_is_busy('op_report_b'),
  1,
  'the concurrent issue replay waits on the uncommitted unique operation ID'
);

select dblink_exec('op_report_a', 'commit');

insert into concurrent_report_results (label, tree_issue_id, task_id)
select 'report_b', tree_issue_id, task_id
from dblink_get_result('op_report_b')
  as result(tree_issue_id uuid, task_id uuid);

select count(*)
from dblink_get_result('op_report_b')
  as result(tree_issue_id uuid, task_id uuid);

select dblink_exec('op_report_b', 'commit');

select is(
  (select tree_issue_id from concurrent_report_results where label = 'report_b'),
  (select tree_issue_id from concurrent_report_results where label = 'report_a'),
  'concurrent issue calls return the same issue id'
);

select is(
  (select task_id from concurrent_report_results where label = 'report_b'),
  (select task_id from concurrent_report_results where label = 'report_a'),
  'concurrent issue calls return the same linked task id'
);

select is(
  (
    select count(*)::integer
    from public.tree_issues
    where client_operation_id = '20000000-0000-0000-0000-000000000102'
  ),
  1,
  'concurrent issue calls leave one issue'
);

select is(
  (
    select count(*)::integer
    from public.tasks
    where related_tree_issue_id = (
      select tree_issue_id
      from concurrent_report_results
      where label = 'report_a'
    )
  ),
  1,
  'concurrent issue calls leave one linked review task'
);

select is(
  (
    select count(*)::integer
    from public.task_activity_log
    where task_id = (
      select task_id
      from concurrent_report_results
      where label = 'report_a'
    )
      and action = 'created'
  ),
  1,
  'concurrent issue calls leave one created activity'
);

select dblink_disconnect('op_report_a');
select dblink_disconnect('op_report_b');

select dblink_connect(
  'op_review_a',
  'host=host.docker.internal port=54322 dbname=postgres user=postgres password=postgres'
);
select dblink_connect(
  'op_review_b',
  'host=host.docker.internal port=54322 dbname=postgres user=postgres password=postgres'
);

select dblink_exec('op_review_a', 'set role authenticated');
select dblink_exec('op_review_b', 'set role authenticated');
select dblink_exec('op_review_a', $$set request.jwt.claim.sub = '20000000-0000-0000-0000-000000000001'$$);
select dblink_exec('op_review_b', $$set request.jwt.claim.sub = '20000000-0000-0000-0000-000000000001'$$);
select dblink_exec('op_review_a', 'begin');
select dblink_exec('op_review_b', 'begin');

select dblink_send_query(
  'op_review_a',
  format(
    $query$
      select public.review_task(
        p_task_id => %L,
        p_decision => 'approved',
        p_notes => 'Concurrent review',
        p_op_id => '20000000-0000-0000-0000-000000000103'
      )
    $query$,
    (
      select task_id
      from concurrent_report_results
      where label = 'report_a'
    )
  )
);

create temporary table concurrent_review_results (
  label text primary key,
  review_id uuid not null
);

insert into concurrent_review_results (label, review_id)
select 'review_a', review_id
from dblink_get_result('op_review_a') as result(review_id uuid);

select count(*)
from dblink_get_result('op_review_a') as result(review_id uuid);

select dblink_send_query(
  'op_review_b',
  format(
    $query$
      select public.review_task(
        p_task_id => %L,
        p_decision => 'approved',
        p_notes => 'Concurrent review',
        p_op_id => '20000000-0000-0000-0000-000000000103'
      )
    $query$,
    (
      select task_id
      from concurrent_report_results
      where label = 'report_a'
    )
  )
);

select is(
  dblink_is_busy('op_review_b'),
  1,
  'the concurrent review replay waits on the task row lock'
);

select dblink_exec('op_review_a', 'commit');

insert into concurrent_review_results (label, review_id)
select 'review_b', review_id
from dblink_get_result('op_review_b') as result(review_id uuid);

select count(*)
from dblink_get_result('op_review_b') as result(review_id uuid);

select dblink_exec('op_review_b', 'commit');

select is(
  (select review_id from concurrent_review_results where label = 'review_b'),
  (select review_id from concurrent_review_results where label = 'review_a'),
  'concurrent review calls return the same review id'
);

select is(
  (
    select count(*)::integer
    from public.engineer_reviews
    where client_operation_id = '20000000-0000-0000-0000-000000000103'
  ),
  1,
  'concurrent review calls leave one engineer review'
);

select is(
  (
    select count(*)::integer
    from public.task_activity_log
    where task_id = (
      select task_id
      from concurrent_report_results
      where label = 'report_a'
    )
      and action = 'reviewed_approved'
  ),
  1,
  'concurrent review calls leave one review activity'
);

select is(
  (
    select status::text
    from public.tasks
    where id = (
      select task_id
      from concurrent_report_results
      where label = 'report_a'
    )
  ),
  'approved',
  'concurrent review calls apply the task transition once'
);

select dblink_disconnect('op_review_a');
select dblink_disconnect('op_review_b');

select * from finish();

delete from private.applied_operations
where op_id::text like '20000000-%';

delete from public.farms
where id = '20000000-0000-0000-0000-000000000010';

delete from auth.users
where id in (
  '20000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000002'
);

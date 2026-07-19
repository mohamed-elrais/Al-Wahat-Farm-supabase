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

select plan(42);

select has_function(
  'public',
  'create_farm_task',
  array[
    'uuid', 'task_type', 'text', 'text', 'uuid', 'uuid', 'uuid',
    'date', 'time without time zone', 'integer', 'timestamp with time zone',
    'task_priority', 'jsonb', 'boolean', 'uuid', 'uuid[]', 'uuid', 'jsonb'
  ],
  'create_farm_task has one op-ID-aware signature'
);

select has_function(
  'public',
  'report_tree_issue',
  array['uuid', 'tree_issue_type', 'issue_severity', 'text', 'text', 'uuid'],
  'report_tree_issue has one op-ID-aware signature'
);

select has_function(
  'public',
  'review_task',
  array['uuid', 'engineer_review_decision', 'text', 'text', 'uuid'],
  'review_task has one op-ID-aware signature'
);

select has_function(
  'public',
  'set_task_assignments',
  array['uuid', 'uuid[]', 'uuid'],
  'set_task_assignments has one op-ID-aware signature'
);

select has_function(
  'public',
  'start_assigned_task',
  array['uuid', 'text', 'uuid'],
  'start_assigned_task has one op-ID-aware signature'
);

select has_function(
  'public',
  'complete_task',
  array['uuid', 'text', 'boolean', 'uuid'],
  'complete_task has one op-ID-aware signature'
);

select is(
  (
    select count(*)::integer
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any (
        array[
          'create_farm_task',
          'report_tree_issue',
          'review_task',
          'set_task_assignments',
          'start_assigned_task',
          'complete_task'
        ]
      )
  ),
  6,
  'no legacy overloads remain'
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
    '10000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'op-manager@example.test',
    '',
    now(),
    now(),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Op Manager"}'::jsonb
  ),
  (
    '10000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'op-worker@example.test',
    '',
    now(),
    now(),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Op Worker"}'::jsonb
  );

insert into public.farms (id, name, code)
values (
  '10000000-0000-0000-0000-000000000010',
  'Op ID Test Farm',
  'OP-ID-TEST'
);

insert into public.farm_sections (id, farm_id, code, name, sort_order)
values (
  '10000000-0000-0000-0000-000000000020',
  '10000000-0000-0000-0000-000000000010',
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
  '10000000-0000-0000-0000-000000000030',
  '10000000-0000-0000-0000-000000000010',
  '10000000-0000-0000-0000-000000000020',
  'OP-TREE-001',
  1,
  1
);

insert into public.farm_memberships (farm_id, profile_id, role)
values
  (
    '10000000-0000-0000-0000-000000000010',
    '10000000-0000-0000-0000-000000000001',
    'agricultural_engineer'
  ),
  (
    '10000000-0000-0000-0000-000000000010',
    '10000000-0000-0000-0000-000000000002',
    'worker'
  );

select test.set_auth('10000000-0000-0000-0000-000000000001');

create temporary table op_results (
  label text primary key,
  first_id uuid,
  second_id uuid,
  first_related_id uuid,
  second_related_id uuid
) on commit drop;

insert into op_results (label, first_id, second_id)
select
  'create',
  public.create_farm_task(
    p_farm_id => '10000000-0000-0000-0000-000000000010',
    p_task_type => 'irrigation',
    p_title => 'Idempotent create task',
    p_assignee_profile_ids => array['10000000-0000-0000-0000-000000000002'::uuid],
    p_op_id => '10000000-0000-0000-0000-000000000101'
  ),
  public.create_farm_task(
    p_farm_id => '10000000-0000-0000-0000-000000000010',
    p_task_type => 'irrigation',
    p_title => 'Idempotent create task',
    p_assignee_profile_ids => array['10000000-0000-0000-0000-000000000002'::uuid],
    p_op_id => '10000000-0000-0000-0000-000000000101'
  );

select is(
  (select second_id from op_results where label = 'create'),
  (select first_id from op_results where label = 'create'),
  'create_farm_task replay returns the original task id'
);

select is(
  (select count(*)::integer from public.tasks where client_operation_id = '10000000-0000-0000-0000-000000000101'),
  1,
  'create_farm_task replay leaves one task'
);

select is(
  (
    select count(*)::integer
    from public.task_activity_log
    where task_id = (select first_id from op_results where label = 'create')
  ),
  2,
  'create_farm_task replay does not duplicate created or assigned activity'
);

select is(
  (
    select count(*)::integer
    from public.task_assignments
    where task_id = (select first_id from op_results where label = 'create')
  ),
  1,
  'create_farm_task replay does not duplicate assignments'
);

insert into op_results (label, first_id, second_id)
select
  'create_null',
  public.create_farm_task(
    p_farm_id => '10000000-0000-0000-0000-000000000010',
    p_task_type => 'general',
    p_title => 'Legacy null create task',
    p_op_id => null
  ),
  public.create_farm_task(
    p_farm_id => '10000000-0000-0000-0000-000000000010',
    p_task_type => 'general',
    p_title => 'Legacy null create task',
    p_op_id => null
  );

select isnt(
  (select second_id from op_results where label = 'create_null'),
  (select first_id from op_results where label = 'create_null'),
  'create_farm_task keeps legacy non-deduplicating null behavior'
);

select is(
  (select count(*)::integer from public.tasks where title = 'Legacy null create task'),
  2,
  'null create operation IDs create two task rows'
);

insert into op_results (
  label,
  first_id,
  first_related_id,
  second_id,
  second_related_id
)
with first_call as (
  select *
  from public.report_tree_issue(
    p_tree_id => '10000000-0000-0000-0000-000000000030',
    p_issue_type => 'clogged_dripper',
    p_severity => 'high',
    p_description => 'Idempotent issue report',
    p_op_id => '10000000-0000-0000-0000-000000000102'
  )
),
second_call as (
  select *
  from public.report_tree_issue(
    p_tree_id => '10000000-0000-0000-0000-000000000030',
    p_issue_type => 'clogged_dripper',
    p_severity => 'high',
    p_description => 'Idempotent issue report',
    p_op_id => '10000000-0000-0000-0000-000000000102'
  )
)
select
  'report',
  first_call.tree_issue_id,
  first_call.task_id,
  second_call.tree_issue_id,
  second_call.task_id
from first_call
cross join second_call;

select is(
  (select second_id from op_results where label = 'report'),
  (select first_id from op_results where label = 'report'),
  'report_tree_issue replay returns the original issue id'
);

select is(
  (select second_related_id from op_results where label = 'report'),
  (select first_related_id from op_results where label = 'report'),
  'report_tree_issue replay returns the original linked task id'
);

select is(
  (select count(*)::integer from public.tree_issues where client_operation_id = '10000000-0000-0000-0000-000000000102'),
  1,
  'report_tree_issue replay leaves one issue'
);

select is(
  (
    select count(*)::integer
    from public.tasks
    where related_tree_issue_id = (select first_id from op_results where label = 'report')
  ),
  1,
  'report_tree_issue replay leaves one linked review task'
);

select is(
  (
    select count(*)::integer
    from public.task_activity_log
    where task_id = (select first_related_id from op_results where label = 'report')
      and action = 'created'
  ),
  1,
  'report_tree_issue replay does not duplicate activity'
);

insert into op_results (
  label,
  first_id,
  first_related_id,
  second_id,
  second_related_id
)
with first_call as (
  select *
  from public.report_tree_issue(
    p_tree_id => '10000000-0000-0000-0000-000000000030',
    p_issue_type => 'other',
    p_severity => 'low',
    p_description => 'Legacy null issue report',
    p_op_id => null
  )
),
second_call as (
  select *
  from public.report_tree_issue(
    p_tree_id => '10000000-0000-0000-0000-000000000030',
    p_issue_type => 'other',
    p_severity => 'low',
    p_description => 'Legacy null issue report',
    p_op_id => null
  )
)
select
  'report_null',
  first_call.tree_issue_id,
  first_call.task_id,
  second_call.tree_issue_id,
  second_call.task_id
from first_call
cross join second_call;

select isnt(
  (select second_id from op_results where label = 'report_null'),
  (select first_id from op_results where label = 'report_null'),
  'report_tree_issue keeps legacy non-deduplicating null behavior'
);

select is(
  (select count(*)::integer from public.tree_issues where description = 'Legacy null issue report'),
  2,
  'null report operation IDs create two issue rows'
);

insert into op_results (label, first_id, second_id)
select
  'review',
  public.review_task(
    p_task_id => (select first_related_id from op_results where label = 'report'),
    p_decision => 'approved',
    p_notes => 'Idempotent approval',
    p_op_id => '10000000-0000-0000-0000-000000000103'
  ),
  public.review_task(
    p_task_id => (select first_related_id from op_results where label = 'report'),
    p_decision => 'approved',
    p_notes => 'Idempotent approval',
    p_op_id => '10000000-0000-0000-0000-000000000103'
  );

select is(
  (select second_id from op_results where label = 'review'),
  (select first_id from op_results where label = 'review'),
  'review_task replay returns the original review id'
);

select is(
  (select count(*)::integer from public.engineer_reviews where client_operation_id = '10000000-0000-0000-0000-000000000103'),
  1,
  'review_task replay leaves one engineer review'
);

select is(
  (
    select count(*)::integer
    from public.task_activity_log
    where task_id = (select first_related_id from op_results where label = 'report')
      and action = 'reviewed_approved'
  ),
  1,
  'review_task replay does not duplicate review activity'
);

select is(
  (
    select status::text
    from public.tree_issues
    where id = (select first_id from op_results where label = 'report')
  ),
  'resolved',
  'review_task replay preserves the original issue transition'
);

insert into op_results (label, first_id, second_id)
select
  'review_null',
  public.review_task(
    p_task_id => (select first_related_id from op_results where label = 'report_null'),
    p_decision => 'follow_up_required',
    p_notes => 'First legacy review',
    p_op_id => null
  ),
  public.review_task(
    p_task_id => (select first_related_id from op_results where label = 'report_null'),
    p_decision => 'follow_up_required',
    p_notes => 'Second legacy review',
    p_op_id => null
  );

select isnt(
  (select second_id from op_results where label = 'review_null'),
  (select first_id from op_results where label = 'review_null'),
  'review_task keeps legacy non-deduplicating null behavior'
);

select is(
  (
    select count(*)::integer
    from public.engineer_reviews
    where task_id = (select first_related_id from op_results where label = 'report_null')
  ),
  2,
  'null review operation IDs create two review rows'
);

insert into public.tasks (
  id,
  farm_id,
  task_type,
  title,
  status,
  created_by_profile_id
)
values
  (
    '10000000-0000-0000-0000-000000000201',
    '10000000-0000-0000-0000-000000000010',
    'general',
    'Assignment replay task',
    'draft',
    '10000000-0000-0000-0000-000000000001'
  ),
  (
    '10000000-0000-0000-0000-000000000202',
    '10000000-0000-0000-0000-000000000010',
    'general',
    'Start replay task',
    'assigned',
    '10000000-0000-0000-0000-000000000001'
  ),
  (
    '10000000-0000-0000-0000-000000000203',
    '10000000-0000-0000-0000-000000000010',
    'general',
    'Complete replay task',
    'in_progress',
    '10000000-0000-0000-0000-000000000001'
  );

insert into public.task_assignments (
  task_id,
  assignee_profile_id,
  assigned_by_profile_id
)
values
  (
    '10000000-0000-0000-0000-000000000202',
    '10000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000001'
  ),
  (
    '10000000-0000-0000-0000-000000000203',
    '10000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000001'
  );

select public.set_task_assignments(
  '10000000-0000-0000-0000-000000000201',
  array['10000000-0000-0000-0000-000000000002'::uuid],
  '10000000-0000-0000-0000-000000000104'
);

select public.set_task_assignments(
  '10000000-0000-0000-0000-000000000201',
  array['10000000-0000-0000-0000-000000000002'::uuid],
  '10000000-0000-0000-0000-000000000104'
);

select is(
  (
    select count(*)::integer
    from public.task_assignments
    where task_id = '10000000-0000-0000-0000-000000000201'
  ),
  1,
  'set_task_assignments replay does not duplicate assignments'
);

select is(
  (
    select count(*)::integer
    from public.task_activity_log
    where task_id = '10000000-0000-0000-0000-000000000201'
      and action = 'assigned'
  ),
  1,
  'set_task_assignments replay does not duplicate activity'
);

select test.set_auth('10000000-0000-0000-0000-000000000002');

select public.start_assigned_task(
  '10000000-0000-0000-0000-000000000202',
  'Start once',
  '10000000-0000-0000-0000-000000000105'
);

select public.start_assigned_task(
  '10000000-0000-0000-0000-000000000202',
  'Start once',
  '10000000-0000-0000-0000-000000000105'
);

select is(
  (select status::text from public.tasks where id = '10000000-0000-0000-0000-000000000202'),
  'in_progress',
  'start_assigned_task replay is a successful no-op'
);

select is(
  (
    select count(*)::integer
    from public.task_activity_log
    where task_id = '10000000-0000-0000-0000-000000000202'
      and action = 'started'
  ),
  1,
  'start_assigned_task replay does not duplicate activity'
);

select public.complete_task(
  '10000000-0000-0000-0000-000000000203',
  'Complete once',
  false,
  '10000000-0000-0000-0000-000000000106'
);

select public.complete_task(
  '10000000-0000-0000-0000-000000000203',
  'Complete once',
  false,
  '10000000-0000-0000-0000-000000000106'
);

select is(
  (select status::text from public.tasks where id = '10000000-0000-0000-0000-000000000203'),
  'completed',
  'complete_task replay is a successful no-op'
);

select is(
  (
    select count(*)::integer
    from public.task_activity_log
    where task_id = '10000000-0000-0000-0000-000000000203'
      and action = 'completed'
  ),
  1,
  'complete_task replay does not duplicate activity'
);

select is(
  (
    select count(*)::integer
    from private.applied_operations
    where op_id = any (
      array[
        '10000000-0000-0000-0000-000000000104'::uuid,
        '10000000-0000-0000-0000-000000000105'::uuid,
        '10000000-0000-0000-0000-000000000106'::uuid
      ]
    )
  ),
  3,
  'transition operations are claimed once in the private ledger'
);

insert into public.tasks (
  id,
  farm_id,
  task_type,
  title,
  status,
  created_by_profile_id
)
values (
  '10000000-0000-0000-0000-000000000204',
  '10000000-0000-0000-0000-000000000010',
  'general',
  'Rejected transition retry task',
  'completed',
  '10000000-0000-0000-0000-000000000001'
);

insert into public.task_assignments (
  task_id,
  assignee_profile_id,
  assigned_by_profile_id
)
values (
  '10000000-0000-0000-0000-000000000204',
  '10000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000001'
);

select throws_ok(
  $$
    select public.complete_task(
      '10000000-0000-0000-0000-000000000204',
      null,
      false,
      '10000000-0000-0000-0000-000000000107'
    )
  $$,
  '23514',
  'This task cannot be completed from its current status',
  'a rejected transition still raises its original validation error'
);

select is(
  (
    select count(*)::integer
    from private.applied_operations
    where op_id = '10000000-0000-0000-0000-000000000107'
  ),
  0,
  'a rejected transition rolls back its ledger claim'
);

update public.tasks
set status = 'in_progress'
where id = '10000000-0000-0000-0000-000000000204';

select lives_ok(
  $$
    select public.complete_task(
      '10000000-0000-0000-0000-000000000204',
      null,
      false,
      '10000000-0000-0000-0000-000000000107'
    )
  $$,
  'a previously rejected operation can be retried after correction'
);

select is(
  (
    select count(*)::integer
    from private.applied_operations
    where op_id = '10000000-0000-0000-0000-000000000107'
  ),
  1,
  'the corrected retry claims its operation ID once'
);

select test.set_auth(null);

select throws_ok(
  $$
    select public.create_farm_task(
      p_farm_id => '10000000-0000-0000-0000-000000000010',
      p_task_type => 'general',
      p_title => 'Unauthorized replay',
      p_op_id => '10000000-0000-0000-0000-000000000101'
    )
  $$,
  '42501',
  'Authentication is required',
  'operation IDs do not bypass authentication on replay'
);

select is(
  (
    select pg_get_function_result(p.oid)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'report_tree_issue'
  ),
  'TABLE(tree_issue_id uuid, task_id uuid)',
  'report_tree_issue return columns remain unchanged'
);

select is(
  (
    select pg_get_function_result(p.oid)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'create_farm_task'
  ),
  'uuid',
  'create_farm_task return type remains uuid'
);

select is(
  (
    select pg_get_function_result(p.oid)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'review_task'
  ),
  'uuid',
  'review_task return type remains uuid'
);

select is(
  (
    select count(*)::integer
    from information_schema.columns
    where table_schema = 'public'
      and table_name in ('tasks', 'tree_issues', 'engineer_reviews')
      and column_name = 'client_operation_id'
      and data_type = 'uuid'
      and is_nullable = 'YES'
  ),
  3,
  'all three create-result tables have nullable UUID operation IDs'
);

select * from finish();

rollback;

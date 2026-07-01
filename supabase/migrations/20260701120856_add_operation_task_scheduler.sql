-- ============================================================
-- Al-Wahat Farm
-- Operation task scheduler
-- ============================================================

create table public.operation_task_generation_logs (
  id uuid primary key default gen_random_uuid(),

  farm_id uuid
    references public.farms(id)
    on delete set null,

  operation_date date,

  started_at timestamptz not null,
  completed_at timestamptz,
  generated_task_count integer not null default 0,
  status text not null,
  error_message text,
  created_at timestamptz not null default now(),

  constraint operation_task_generation_logs_status_check
    check (status in ('running', 'completed', 'failed')),

  constraint operation_task_generation_logs_generated_count_check
    check (generated_task_count >= 0)
);

create index operation_task_generation_logs_farm_id_idx
  on public.operation_task_generation_logs (farm_id);

create index operation_task_generation_logs_operation_date_idx
  on public.operation_task_generation_logs (operation_date);

create index operation_task_generation_logs_started_at_idx
  on public.operation_task_generation_logs (started_at desc);

create index operation_task_generation_logs_status_idx
  on public.operation_task_generation_logs (status);

create or replace function private.can_view_operation_task_generation_log(
  p_log_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.operation_task_generation_logs log
    where log.id = p_log_id
      and log.farm_id is not null
      and private.is_operational_manager(log.farm_id)
  );
$$;

revoke all on function private.can_view_operation_task_generation_log(uuid)
from public, anon;

grant execute on function private.can_view_operation_task_generation_log(uuid)
to authenticated;

create or replace function private.generate_due_operation_tasks()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_farm record;
  v_operation_date date;
  v_log_id uuid;
  v_generated_task_count integer;
  v_error_message text;
  v_farm_local_date date;
begin
  for v_farm in
    select
      f.id,
      coalesce(nullif(f.timezone, ''), 'Africa/Cairo') as timezone
    from public.farms f
    order by f.id
  loop
    begin
      v_farm_local_date := (now() at time zone v_farm.timezone)::date;

      foreach v_operation_date in array array[
        v_farm_local_date,
        v_farm_local_date + 1
      ]
      loop
        v_log_id := null;
        v_generated_task_count := 0;

        insert into public.operation_task_generation_logs (
          farm_id,
          operation_date,
          started_at,
          status
        )
        values (
          v_farm.id,
          v_operation_date,
          now(),
          'running'
        )
        returning id into v_log_id;

        begin
          select count(*)::integer
          into v_generated_task_count
          from public.generate_operation_tasks_for_date(
            v_farm.id,
            v_operation_date
          );

          update public.operation_task_generation_logs
          set
            completed_at = now(),
            generated_task_count = v_generated_task_count,
            status = 'completed'
          where id = v_log_id;
        exception
          when others then
            v_error_message := sqlerrm;

            update public.operation_task_generation_logs
            set
              completed_at = now(),
              status = 'failed',
              error_message = v_error_message
            where id = v_log_id;
        end;
      end loop;
    exception
      when others then
        insert into public.operation_task_generation_logs (
          farm_id,
          operation_date,
          started_at,
          completed_at,
          status,
          error_message
        )
        values (
          v_farm.id,
          null,
          now(),
          now(),
          'failed',
          sqlerrm
        );
    end;
  end loop;
end;
$$;

revoke all on function private.generate_due_operation_tasks()
from public, anon, authenticated;

grant execute on function private.generate_due_operation_tasks()
to service_role;

revoke all on table public.operation_task_generation_logs
from anon;

revoke all on table public.operation_task_generation_logs
from authenticated;

grant select on table public.operation_task_generation_logs
to authenticated;

grant all on table public.operation_task_generation_logs
to service_role;

alter table public.operation_task_generation_logs enable row level security;

create policy "operation_task_generation_logs_select_managers"
on public.operation_task_generation_logs
for select
to authenticated
using (
  private.can_view_operation_task_generation_log(id)
);

-- ------------------------------------------------------------
-- Optional Supabase Cron / pg_cron schedule.
-- The scheduler function calculates farm-local dates itself, so the
-- cron expression is intentionally hourly rather than Cairo-midnight.
-- ------------------------------------------------------------

do $$
begin
  begin
    execute 'create extension if not exists pg_cron with schema extensions';
  exception
    when insufficient_privilege or undefined_file or feature_not_supported then
      null;
  end;
end;
$$;

do $$
begin
  if to_regnamespace('cron') is not null
    and to_regprocedure('cron.schedule(text,text,text)') is not null
    and to_regprocedure('cron.unschedule(text)') is not null then
    begin
      perform cron.unschedule('al_wahat_generate_operation_tasks_hourly');
    exception
      when others then
        null;
    end;

    perform cron.schedule(
      'al_wahat_generate_operation_tasks_hourly',
      '0 * * * *',
      'select private.generate_due_operation_tasks();'
    );
  end if;
exception
  when others then
    null;
end;
$$;

-- Database role for the SmartCrop application to read/write Frost data.
--   docker compose exec -T postgres psql -U postgres -d frost < migrations/002_smartcrop_app_role.sql
-- (runs as the postgres superuser: creating a role needs it)
-- Change the password before running. Connection from the SmartCrop app:
--   host=127.0.0.1 port=5433 dbname=frost user=smartcrop_app password=...

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'smartcrop_app') then
    create role smartcrop_app with login password 'CHANGE-ME';
  end if;
end $$;

grant connect on database frost to smartcrop_app;
grant usage on schema public to smartcrop_app;

-- Full CRUD on what the UI manages
grant select, insert, update, delete on companies, ranches, sensors, subscribers, subscriptions to smartcrop_app;
grant usage, select on all sequences in schema public to smartcrop_app;

-- Read-only on what the ingest produces
grant select on sensor_status, readings, alerts, alert_state to smartcrop_app;

-- Future tables created by role frost inherit the same grants
alter default privileges for role frost in schema public grant select on tables to smartcrop_app;
alter default privileges for role frost in schema public grant usage, select on sequences to smartcrop_app;

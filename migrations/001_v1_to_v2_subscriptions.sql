-- SmartCrop Frost: migrate the v1 schema (thresholds on sensors, subscribers.ranch)
-- to v2 (companies, ranches, subscriptions with per-subscriber thresholds).
--
-- Run ONCE against an existing v1 database:
--   docker compose exec -T postgres psql -U frost -d frost < migrations/001_v1_to_v2_subscriptions.sql
--
-- Fresh installs never need this; 002-init-frost.sh creates v2 directly.
-- Safe to re-run: every step checks whether it already happened.

begin;

-- ---------------------------------------------------------------- companies
create table if not exists companies (
    id          serial primary key,
    name        text not null unique,
    tenant_id   uuid unique,
    created_at  timestamptz default now()
);
insert into companies (name) values ('Northern Fruit') on conflict (name) do nothing;

-- ------------------------------------------------------------------ ranches
create table if not exists ranches (
    id          serial primary key,
    company_id  integer not null references companies(id),
    name        text not null,
    unique (company_id, name)
);
do $$ begin
  if exists (select 1 from information_schema.columns where table_name='sensors' and column_name='ranch') then
    insert into ranches (company_id, name)
    select c.id, s.ranch
      from (select distinct ranch from sensors where ranch is not null) s
      cross join (select id from companies where name = 'Northern Fruit') c
    on conflict (company_id, name) do nothing;
  end if;
end $$;

-- ------------------------------------------------------------------ sensors
alter table sensors add column if not exists company_id integer references companies(id);
alter table sensors add column if not exists ranch_id   integer references ranches(id);

update sensors s
   set company_id = (select id from companies where name = 'Northern Fruit')
 where s.company_id is null;

do $$ begin
  if exists (select 1 from information_schema.columns where table_name='sensors' and column_name='ranch') then
    update sensors s set ranch_id = r.id from ranches r
     where s.ranch_id is null and r.name = s.ranch and r.company_id = s.company_id;
  end if;
end $$;

-- --------------------------------------------------------------- sensor_status
create table if not exists sensor_status (
    dev_eui         text primary key references sensors(dev_eui),
    last_seen       timestamptz,
    last_temp_c     numeric(6,2),
    last_battery_v  numeric(4,2),
    updated_at      timestamptz default now()
);
do $$ begin
  if exists (select 1 from information_schema.columns where table_name='alert_state' and column_name='last_seen') then
    insert into sensor_status (dev_eui, last_seen) select dev_eui, last_seen from alert_state
    on conflict (dev_eui) do nothing;
  end if;
end $$;

-- -------------------------------------------------------------- subscribers
alter table subscribers add column if not exists company_id  integer references companies(id);
alter table subscribers add column if not exists quiet_start time;
alter table subscribers add column if not exists quiet_end   time;
alter table subscribers add column if not exists created_at  timestamptz default now();

update subscribers
   set company_id = (select id from companies where name = 'Northern Fruit')
 where company_id is null;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'subscribers_channel_address_key') then
    alter table subscribers add constraint subscribers_channel_address_key unique (channel, address);
  end if;
end $$;

-- ------------------------------------------------------------ subscriptions
create table if not exists subscriptions (
    id              serial primary key,
    subscriber_id   integer not null references subscribers(id) on delete cascade,
    ranch_id        integer references ranches(id) on delete cascade,
    dev_eui         text references sensors(dev_eui) on delete cascade,
    low_temp_c      numeric(5,2) not null default -2.0,
    clear_temp_c    numeric(5,2) not null default -1.0,
    notify_offline  boolean not null default true,
    offline_minutes integer not null default 30,
    enabled         boolean default true,
    created_at      timestamptz default now(),
    check ((ranch_id is not null) <> (dev_eui is not null)),
    check (clear_temp_c >= low_temp_c)
);
create index if not exists subscriptions_ranch on subscriptions (ranch_id);
create index if not exists subscriptions_dev on subscriptions (dev_eui);

-- v1 subscribers with ranch = X  -> one subscription on that ranch
-- v1 subscribers with ranch NULL -> one subscription per ranch in their company
-- Thresholds: the v1 per-sensor values if they were all the same, else defaults.
do $$ begin
  if exists (select 1 from information_schema.columns where table_name='subscribers' and column_name='ranch') then
    insert into subscriptions (subscriber_id, ranch_id, low_temp_c, clear_temp_c, offline_minutes)
    select sub.id, r.id,
           coalesce((select low_temp_c      from sensors group by 1 having count(*) = (select count(*) from sensors) limit 1), -2.0),
           coalesce((select clear_temp_c    from sensors group by 1 having count(*) = (select count(*) from sensors) limit 1), -1.0),
           coalesce((select offline_minutes from sensors group by 1 having count(*) = (select count(*) from sensors) limit 1), 30)
      from subscribers sub
      join ranches r on r.company_id = sub.company_id and (sub.ranch is null or sub.ranch = r.name)
     where not exists (select 1 from subscriptions x where x.subscriber_id = sub.id and x.ranch_id = r.id);
  end if;
end $$;

-- -------------------------------------------------------------- alert_state
-- v1 keyed on dev_eui; v2 keyed on (subscription_id, dev_eui). Start clean.
do $$ begin
  if exists (select 1 from information_schema.columns
              where table_name = 'alert_state' and column_name = 'last_seen') then
    drop table alert_state;
  end if;
end $$;
create table if not exists alert_state (
    subscription_id  integer not null references subscriptions(id) on delete cascade,
    dev_eui          text not null references sensors(dev_eui) on delete cascade,
    low_active       boolean default false,
    offline_active   boolean default false,
    updated_at       timestamptz default now(),
    primary key (subscription_id, dev_eui)
);

-- ------------------------------------------------------------------- alerts
alter table alerts add column if not exists subscription_id integer references subscriptions(id) on delete set null;
alter table alerts add column if not exists subscriber_id   integer references subscribers(id) on delete set null;
alter table alerts add column if not exists delivered       boolean;
alter table alerts drop column if exists sent_to;
create index if not exists alerts_sent on alerts (sent_at desc);

-- ------------------------------------------------------- drop v1 columns
alter table sensors     drop column if exists ranch;
alter table sensors     drop column if exists block;
alter table sensors     drop column if exists low_temp_c;
alter table sensors     drop column if exists clear_temp_c;
alter table sensors     drop column if exists offline_minutes;
alter table subscribers drop column if exists ranch;
alter table subscribers alter column company_id set not null;
alter table sensors     alter column company_id set not null;

commit;

-- ------------------------------------------------------------------- check
select s.dev_eui, s.name, r.name as ranch, s.placement
  from sensors s left join ranches r on r.id = s.ranch_id order by s.name;
select sub.name, sub.channel, sub.address, r.name as ranch, x.low_temp_c, x.clear_temp_c, x.offline_minutes
  from subscriptions x
  join subscribers sub on sub.id = x.subscriber_id
  left join ranches r on r.id = x.ranch_id
 order by sub.name, r.name;

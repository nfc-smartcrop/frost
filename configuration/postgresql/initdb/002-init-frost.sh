#!/usr/bin/env bash
set -e

# SmartCrop Frost schema (v2): thresholds live on subscriptions, not sensors.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    create role frost with login password 'frost';
    create database frost with owner frost;
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname frost <<-EOSQL
    set role frost;

    -- A customer. tenant_id = the ChirpStack tenant UUID (fill in once known).
    create table companies (
        id          serial primary key,
        name        text not null unique,
        tenant_id   uuid unique,
        created_at  timestamptz default now()
    );

    -- A ranch belongs to a company.
    create table ranches (
        id          serial primary key,
        company_id  integer not null references companies(id),
        name        text not null,
        unique (company_id, name)
    );

    -- Physical sensor. dev_eui = LoRaWAN DevEUI, lowercase hex.
    create table sensors (
        dev_eui     text primary key,
        company_id  integer not null references companies(id),
        ranch_id    integer references ranches(id),      -- null = not yet assigned
        name        text not null,
        placement   text,                                -- 'low spot', 'mid-block', ...
        enabled     boolean default true,
        created_at  timestamptz default now()
    );

    -- Rolling status per sensor (last reading, offline detection).
    create table sensor_status (
        dev_eui         text primary key references sensors(dev_eui),
        last_seen       timestamptz,
        last_temp_c     numeric(6,2),
        last_battery_v  numeric(4,2),
        updated_at      timestamptz default now()
    );

    -- Every uplink that carried a reading.
    create table readings (
        id          bigserial primary key,
        dev_eui     text not null references sensors(dev_eui),
        ts          timestamptz not null,
        temp_c      numeric(6,2),
        battery_v   numeric(4,2),
        rssi        integer,
        snr         numeric(5,2),
        gateway_id  text,
        f_cnt       integer,
        raw         jsonb
    );
    create index readings_dev_ts on readings (dev_eui, ts desc);

    -- A person (or system) that can receive alerts. Belongs to a company.
    create table subscribers (
        id           serial primary key,
        company_id   integer not null references companies(id),
        name         text not null,
        channel      text not null check (channel in ('sms','email','webhook')),
        address      text not null,          -- +1 phone, email, or webhook URL
        quiet_start  time,                   -- optional quiet hours (local server time)
        quiet_end    time,
        enabled      boolean default true,
        created_at   timestamptz default now(),
        unique (channel, address)
    );

    -- What a subscriber wants: a scope (ranch OR one sensor) and their own rule.
    create table subscriptions (
        id              serial primary key,
        subscriber_id   integer not null references subscribers(id) on delete cascade,
        ranch_id        integer references ranches(id) on delete cascade,
        dev_eui         text references sensors(dev_eui) on delete cascade,
        low_temp_c      numeric(5,2) not null default -2.0,   -- alert at or below
        clear_temp_c    numeric(5,2) not null default -1.0,   -- clear at or above
        notify_offline  boolean not null default true,
        offline_minutes integer not null default 30,
        enabled         boolean default true,
        created_at      timestamptz default now(),
        check ((ranch_id is not null) <> (dev_eui is not null)),
        check (clear_temp_c >= low_temp_c)
    );
    create index subscriptions_ranch on subscriptions (ranch_id);
    create index subscriptions_dev on subscriptions (dev_eui);

    -- Per (subscription, sensor) state so each person's rule tracks independently.
    create table alert_state (
        subscription_id  integer not null references subscriptions(id) on delete cascade,
        dev_eui          text not null references sensors(dev_eui) on delete cascade,
        low_active       boolean default false,
        offline_active   boolean default false,
        updated_at       timestamptz default now(),
        primary key (subscription_id, dev_eui)
    );

    -- History of every alert sent.
    create table alerts (
        id               bigserial primary key,
        subscription_id  integer references subscriptions(id) on delete set null,
        subscriber_id    integer references subscribers(id) on delete set null,
        dev_eui          text references sensors(dev_eui),
        kind             text not null,     -- low_temp, low_temp_clear, offline, back_online
        temp_c           numeric(6,2),
        message          text,
        delivered        boolean,
        sent_at          timestamptz default now()
    );
    create index alerts_sent on alerts (sent_at desc);
EOSQL

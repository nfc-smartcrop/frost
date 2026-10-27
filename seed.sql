-- SmartCrop Frost — seed for the Northern Fruit / Blue Heron POC (schema v2)
--   docker compose exec -T postgres psql -U frost -d frost < seed.sql
-- Safe to re-run.

insert into companies (name) values ('Northern Fruit') on conflict (name) do nothing;

insert into ranches (company_id, name)
select id, 'Blue Heron' from companies where name = 'Northern Fruit'
on conflict (company_id, name) do nothing;

insert into sensors (dev_eui, company_id, ranch_id, name, placement, enabled)
select v.dev_eui, c.id, r.id, v.name, v.placement, true
  from (values
    ('a8404146fe5fbe4f', 'Blue Heron - Sensor1', 'low spot'),
    ('a84041ca265fbe42', 'Blue Heron - Sensor2', 'mid-block')
  ) as v(dev_eui, name, placement)
  cross join companies c
  join ranches r on r.company_id = c.id and r.name = 'Blue Heron'
 where c.name = 'Northern Fruit'
on conflict (dev_eui) do update
   set company_id = excluded.company_id, ranch_id = excluded.ranch_id,
       name = excluded.name, placement = excluded.placement, enabled = excluded.enabled;

-- People. Edit before running.
insert into subscribers (company_id, name, channel, address)
select c.id, v.name, v.channel, v.address
  from (values
    ('Juan', 'sms',   '+15095550100'),
    ('Juan', 'email', 'juan@northernfruit.com')
  ) as v(name, channel, address)
  cross join companies c where c.name = 'Northern Fruit'
on conflict (channel, address) do update set name = excluded.name;

-- What each person wants. One row per (subscriber, ranch or sensor).
-- Example: Juan gets both Blue Heron sensors at -2 °C, clears at -1 °C, offline after 30 min.
insert into subscriptions (subscriber_id, ranch_id, low_temp_c, clear_temp_c, notify_offline, offline_minutes)
select sub.id, r.id, -2.0, -1.0, true, 30
  from subscribers sub
  join companies c on c.id = sub.company_id and c.name = 'Northern Fruit'
  join ranches r on r.company_id = c.id and r.name = 'Blue Heron'
 where sub.address in ('+15095550100', 'juan@northernfruit.com')
   and not exists (select 1 from subscriptions x where x.subscriber_id = sub.id and x.ranch_id = r.id);

-- Example of a per-sensor rule with a different threshold (uncomment to use):
-- insert into subscriptions (subscriber_id, dev_eui, low_temp_c, clear_temp_c)
-- select id, 'a8404146fe5fbe4f', 0.0, 1.0 from subscribers where address = '+15095550100';

select s.name, r.name as ranch, s.placement from sensors s left join ranches r on r.id = s.ranch_id order by 1;
select sub.name, sub.channel, sub.address, coalesce(r.name, s.name) as scope, x.low_temp_c, x.clear_temp_c, x.offline_minutes
  from subscriptions x join subscribers sub on sub.id = x.subscriber_id
  left join ranches r on r.id = x.ranch_id left join sensors s on s.dev_eui = x.dev_eui order by 1, 4;

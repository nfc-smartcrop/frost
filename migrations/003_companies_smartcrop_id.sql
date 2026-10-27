-- Link Frost companies to SmartCrop companies.
--   docker compose exec -T postgres psql -U frost -d frost < migrations/003_companies_smartcrop_id.sql
--
-- smartcrop_company_id = the company's primary key in SmartCrop's own database.
-- The SmartCrop app filters everything by this column, never by Frost's own id.

alter table companies add column if not exists smartcrop_company_id integer unique;

-- One-time backfill for the first customer. Replace 1 with Northern Fruit's id in SmartCrop.
update companies set smartcrop_company_id = 1 where name = 'Northern Fruit' and smartcrop_company_id is null;

-- Convenience for the app: resolve a SmartCrop company id to the Frost company row.
create or replace view v_company_by_smartcrop as
select smartcrop_company_id, id as frost_company_id, name, tenant_id from companies;

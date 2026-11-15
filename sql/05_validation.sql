-- =====================================================================
-- 05_validation.sql — SOURCE DATA VALIDATION (runs on staging, before any cleaning)
--
-- What:  one row per source table describing grain, key integrity, coverage and FK health.
-- Why:   the brief claims ~12 months of data and gives no data dictionary; every later
--        decision (period analysed, keys, joins) must rest on what the files actually contain.
-- Tables: all 17 stg.* tables.
-- Business question: "Which data can we trust, for which period?"
-- =====================================================================
create schema if not exists val;

-- V1 Inventory: the 17 tables the assignment says to expect vs what was delivered
create or replace table val.inventory as
with expected(table_name) as (values ('borrowers'),('accounts'),('agents'),('agent_sessions'),('campaigns'),
     ('daily_targeting'),('calls'),('call_attempts'),('call_dispositions'),('whatsapp_events'),('sms_events'),
     ('field_visits'),('promises_to_pay'),('payments'),('vendor_telephony'),('complaints'),('account_status_history'))
select e.table_name, t.table_name is not null as delivered
from expected e left join information_schema.tables t
  on t.table_schema = 'raw' and t.table_name = e.table_name
order by 1;

-- V2 Grain, primary-key integrity and coverage (event tables use their IST event time)
create or replace table val.table_profile as
with p as (
  select 'payments' tbl, 'payment_id' pk, count(*) n_rows, count(distinct payment_id) n_pk, min(event_at_ist) first_ts, max(event_at_ist) last_ts from stg.payments
  union all select 'calls','call_id', count(*), count(distinct call_id), min(event_at_ist), max(event_at_ist) from stg.calls
  union all select 'call_attempts','attempt_id', count(*), count(distinct attempt_id), min(event_at_ist), max(event_at_ist) from stg.call_attempts
  union all select 'call_dispositions','disposition_id', count(*), count(distinct disposition_id), min(event_at_ist), max(event_at_ist) from stg.call_dispositions
  union all select 'whatsapp_events','whatsapp_event_id', count(*), count(distinct event_id), min(event_at_ist), max(event_at_ist) from stg.whatsapp_events
  union all select 'sms_events','sms_event_id', count(*), count(distinct event_id), min(event_at_ist), max(event_at_ist) from stg.sms_events
  union all select 'field_visits','visit_id', count(*), count(distinct visit_id), min(event_at_ist), max(event_at_ist) from stg.field_visits
  union all select 'promises_to_pay','ptp_id', count(*), count(distinct ptp_id), min(event_at_ist), max(event_at_ist) from stg.promises_to_pay
  union all select 'complaints','complaint_id', count(*), count(distinct complaint_id), min(event_at_ist), max(event_at_ist) from stg.complaints
  union all select 'account_status_history','history_id', count(*), count(distinct history_id), min(event_at_ist), max(event_at_ist) from stg.account_status_history
  union all select 'agent_sessions','session_id', count(*), count(distinct session_id), min(login_at_ist), max(logout_at_ist) from stg.agent_sessions
  union all select 'daily_targeting','target_id', count(*), count(distinct target_id), min(target_date)::timestamp, max(target_date)::timestamp from stg.daily_targeting
  union all select 'campaigns (start..end)','campaign_id', count(*), count(distinct campaign_id), min(start_at), max(end_at) from stg.campaigns
  union all select 'accounts (opened_at)','account_id', count(*), count(distinct account_id), min(opened_at_local), max(opened_at_local) from stg.accounts
  union all select 'borrowers (created..updated)','borrower_id', count(*), count(distinct borrower_id), min(created_at), max(updated_at) from stg.borrowers
  union all select 'agents (joined..updated)','agent_id', count(*), count(distinct agent_id), min(joined_at), max(updated_at) from stg.agents
  union all select 'vendor_telephony','vendor_id', count(*), count(distinct vendor_id), null, null from stg.vendor_telephony)
select *, n_rows - n_pk as duplicate_pk_rows,
       date_diff('day', first_ts, last_ts) + 1 as span_days
from p;

-- V3 Complete calendar months covered by the money table and the activity tables.
--     A month is "complete" only if every calendar day has at least one event.
create or replace table val.month_completeness as
with days as (select d::date d from range(date '2025-12-01', date '2026-09-01', interval 1 day) t(d)),
ev as (
  select 'payments' tbl, event_at_ist::date d from stg.payments
  union all select 'calls', event_at_ist::date from stg.calls
  union all select 'whatsapp_events', event_at_ist::date from stg.whatsapp_events
  union all select 'field_visits', event_at_ist::date from stg.field_visits),
cov as (select tbl, d, count(*) n from ev group by all)
select t.tbl, date_trunc('month', days.d)::date month_start,
       count(*) calendar_days, count(cov.n) days_with_events,
       count(*) = count(cov.n) as is_complete
from days cross join (select distinct tbl from ev) t
left join cov on cov.tbl = t.tbl and cov.d = days.d
group by all having count(cov.n) > 0 order by 1, 2;

-- V4 Foreign-key health: does every event's account exist? (orphans would silently drop in inner joins)
create or replace table val.fk_health as
select 'payments.account_id -> accounts' fk, count(*) n, count(*) filter (where a.account_id is null) orphans from stg.payments x left join stg.accounts a using(account_id)
union all select 'calls.account_id -> accounts', count(*), count(*) filter (where a.account_id is null) from stg.calls x left join stg.accounts a using(account_id)
union all select 'promises_to_pay.account_id -> accounts', count(*), count(*) filter (where a.account_id is null) from stg.promises_to_pay x left join stg.accounts a using(account_id)
union all select 'calls.agent_id -> agents', count(*) filter (where x.agent_id is not null), count(*) filter (where x.agent_id is not null and not exists (select 1 from stg.agents g where g.agent_id=x.agent_id)) from stg.calls x
union all select 'calls.campaign_id -> campaigns', count(*), count(*) filter (where c.campaign_id is null) from stg.calls x left join stg.campaigns c using(campaign_id)
union all select 'calls.vendor_id -> vendor_telephony', count(*), count(*) filter (where v.vendor_id is null) from stg.calls x left join stg.vendor_telephony v using(vendor_id)
union all select 'accounts.borrower_id -> borrowers', count(*), count(*) filter (where x.borrower_id is null or not exists (select 1 from stg.borrowers b where b.borrower_id=x.borrower_id)) from stg.accounts x
union all select 'call_attempts.call_id -> calls', count(*), count(*) filter (where not exists (select 1 from stg.calls c where c.call_id=x.call_id)) from stg.call_attempts x
union all select 'call_attempts (call_id, account_id) -> calls', count(*), count(*) filter (where not exists (select 1 from stg.calls c where c.call_id=x.call_id and c.account_id=x.account_id)) from stg.call_attempts x
union all select 'call_dispositions (call_id, account_id) -> calls', count(*), count(*) filter (where not exists (select 1 from stg.calls c where c.call_id=x.call_id and c.account_id=x.account_id)) from stg.call_dispositions x
union all select 'payments.borrower_id = accounts.borrower_id', count(*), count(*) filter (where a.borrower_id is distinct from x.borrower_id) from stg.payments x join stg.accounts a using(account_id);

-- V5 Null profile of the columns analysis depends on
create or replace table val.null_profile as
select 'payments.payment_reference' col, count(*) filter (where payment_reference is null) nulls, count(*) n from stg.payments
union all select 'accounts.borrower_id', count(*) filter (where borrower_id is null), count(*) from stg.accounts
union all select 'calls.agent_id', count(*) filter (where agent_id is null), count(*) from stg.calls
union all select 'call_attempts.vendor_id', count(*) filter (where vendor_id='UNKNOWN'), count(*) from stg.call_attempts
union all select 'field_visits.scheduled_at', count(*) filter (where scheduled_at is null), count(*) from stg.field_visits
union all select 'borrowers.phone', count(*) filter (where phone is null), count(*) from stg.borrowers
union all select 'borrowers.email', count(*) filter (where email is null), count(*) from stg.borrowers;

-- V6 Schema versions present (changed schemas) and whether their mix moves over time
create or replace table val.schema_versions as
select 'accounts.schema_version' field, schema_version version, count(*) n from stg.accounts group by all
union all select 'call_dispositions.disposition_version', disposition_version, count(*) from stg.call_dispositions group by all
union all select 'vendor_telephony.schema_version', schema_version, count(*) from stg.vendor_telephony group by all
union all select 'campaigns.strategy_version', strategy_version, count(*) from stg.campaigns group by all
order by 1, 2;

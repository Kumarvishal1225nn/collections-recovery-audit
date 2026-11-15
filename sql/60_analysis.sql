-- =====================================================================
-- 60_analysis.sql  —  Analytical queries used by the notebook
-- =====================================================================
create schema if not exists ana;

-- 1. Segment x month outcomes (portfolio-level drivers) on the fixed-cohort panel
create or replace table ana.segment_month as
with long as (
    select month_start, is_complete, paid_flag, collected, outstanding_amount, 'dpd_bucket' dim, dpd_bucket lvl from gld.account_month
    union all select month_start, is_complete, paid_flag, collected, outstanding_amount, 'loan_type', loan_type from gld.account_month
    union all select month_start, is_complete, paid_flag, collected, outstanding_amount, 'risk_segment', risk_segment from gld.account_month
    union all select month_start, is_complete, paid_flag, collected, outstanding_amount, 'state', state from gld.account_month
    union all select month_start, is_complete, paid_flag, collected, outstanding_amount, 'account_timezone', account_timezone from gld.account_month
    union all select month_start, is_complete, paid_flag, collected, outstanding_amount, 'snapshot_status', snapshot_status from gld.account_month)
select dim, lvl, month_start, count(*) accounts, sum(paid_flag::int) paying_accounts,
       100.0*avg(paid_flag::int) paying_rate_pct, sum(collected) collected,
       100*sum(collected)/sum(outstanding_amount) recovery_rate_pct
from long where is_complete group by all order by all;

-- 2. Calling-time effectiveness (IST hour)
create or replace table ana.call_hour as
select hour(event_at_ist) hour_ist, count(*) calls, 100.0*avg(is_contact::int) answer_rate_pct
from cln.calls where direction='OUTBOUND' group by 1 order by 1;

-- 3. Telephony vendor effectiveness
create or replace table ana.vendor as
select v.vendor_id, v.vendor_name, v.schema_version, v.status vendor_status, count(*) calls,
       100.0*avg(c.is_contact::int) answer_rate_pct, avg(c.duration_sec) avg_duration_sec
from cln.calls c join cln.dim_vendor v using (vendor_id) where c.direction='OUTBOUND'
group by all order by answer_rate_pct desc;

-- 4. Agent performance with as-of (SCD-2) tenure
create or replace table ana.agent_call_tenure as
select c.call_id, c.agent_id, c.event_at_ist, c.is_contact,
       date_diff('day', s.joined_at, c.event_at_ist)/30.4 as tenure_months_asof,
       s.team as team_asof
from cln.calls c
join cln.dim_agent_scd s on s.agent_id = c.agent_id
 and c.event_at_ist >= s.valid_from and c.event_at_ist < s.valid_to
where c.agent_id is not null and c.direction='OUTBOUND';

create or replace table ana.agent_halves as   -- split-half reliability of agent "skill"
select agent_id,
       avg(is_ptp::int) filter (where event_at_ist <  timestamp '2026-04-20') ptp_rate_h1,
       avg(is_ptp::int) filter (where event_at_ist >= timestamp '2026-04-20') ptp_rate_h2,
       count(*) filter (where event_at_ist <  timestamp '2026-04-20') n_h1,
       count(*) filter (where event_at_ist >= timestamp '2026-04-20') n_h2
from cln.call_dispositions group by 1;

create or replace table ana.agent_ptp_verified as
select agent_id, count(*) filter (where is_due) due_ptps,
       avg(verified_kept::int) filter (where is_due) verified_kept_rate,
       avg((reported_status='KEPT')::int) reported_kept_rate
from gld.fct_ptp group by 1;

-- 5. Attempt frequency (per account-month) vs payment
create or replace table ana.attempt_frequency as
select case when n_dial_attempts = 0 then '0' when n_dial_attempts <= 2 then '1-2'
            when n_dial_attempts <= 5 then '3-5' else '6+' end as attempts_bucket,
       count(*) account_months, 100.0*avg(paid_flag::int) paying_rate_pct,
       avg(collected) collected_per_account_month
from gld.account_month where is_complete group by 1 order by 1;

-- 6. Channel conversion: P(payment within 7 days after a touch) vs a random-day baseline
create or replace table ana.channel_conversion as
with t as (select * from gld.fct_touch where event_at_ist < timestamp '2026-08-01'),
conv as (
    select t.channel, t.touch_id, t.is_engaged,
           exists (select 1 from gld.fct_payment p where p.account_id = t.account_id
                   and p.event_at_ist > t.event_at_ist and p.event_at_ist <= t.event_at_ist + interval 7 day) as paid_7d
    from t)
select channel, count(*) touches, 100.0*avg(paid_7d::int) pay_within_7d_pct,
       100.0*avg(paid_7d::int) filter (where is_engaged) pay_within_7d_engaged_pct,
       100.0*avg(paid_7d::int) filter (where not is_engaged) pay_within_7d_not_engaged_pct
from conv group by 1 order by 1;

-- Baseline: P(payment within 7 days) after a RANDOM account-day (no touch condition)
create or replace table ana.channel_baseline as
with days as (select a.account_id, d::timestamp + interval 12 hour as ts
              from (select account_id from cln.dim_account using sample 3000 rows (reservoir, 7)) a,
                   generate_series(date '2026-01-01', date '2026-07-24', interval 7 day) g(d))
select 100.0*avg((exists (select 1 from gld.fct_payment p where p.account_id = days.account_id
                  and p.event_at_ist > days.ts and p.event_at_ist <= days.ts + interval 7 day))::int) baseline_pay_within_7d_pct,
       count(*) sampled_account_days
from days;

-- =====================================================================
-- v2 additions
-- =====================================================================

-- 7. Campaign / strategy performance.
--    What: P(payment within 7 days after an account is targeted) by campaign attributes.
--    Why: the brief asks for campaign-level drivers; calls->dispositions cannot be linked
--         (broken call_id), so targeting -> payment on the same account is the cleanest test.
--    Tables: cln.daily_targeting, cln.dim_campaign, gld.fct_payment
--    Business question: "Do some campaigns/strategies convert better than others?"
create or replace table ana.campaign_targeting as
with t as (
    select t.target_id, t.account_id, t.target_date, t.status target_status, t.recommended_channel,
           c.campaign_name, c.channel campaign_channel, c.strategy_version, c.strategy_generation, c.target_definition,
           exists (select 1 from gld.fct_payment p where p.account_id = t.account_id
                   and p.event_at_ist >= t.target_date::timestamp
                   and p.event_at_ist <  t.target_date::timestamp + interval 7 day) as paid_7d
    from cln.daily_targeting t join cln.dim_campaign c using (campaign_id)
    where t.target_date <= date '2026-07-31')
select * from t;

create or replace table ana.campaign_summary as
select 'strategy_version' dim, strategy_version lvl, count(*) targetings, 100.0*avg(paid_7d::int) pay_within_7d_pct from ana.campaign_targeting group by all
union all select 'target_definition', target_definition, count(*), 100.0*avg(paid_7d::int) from ana.campaign_targeting group by all
union all select 'campaign_name', campaign_name, count(*), 100.0*avg(paid_7d::int) from ana.campaign_targeting group by all
union all select 'campaign_channel', campaign_channel, count(*), 100.0*avg(paid_7d::int) from ana.campaign_targeting group by all
union all select 'recommended_channel', recommended_channel, count(*), 100.0*avg(paid_7d::int) from ana.campaign_targeting group by all
union all select 'target_status', target_status, count(*), 100.0*avg(paid_7d::int) from ana.campaign_targeting group by all
order by 1, 2;

-- 8. Account-level collections funnel per month (account counts, not linked call chains).
--    Why account level: call_id links between calls / attempts / dispositions are broken
--    (val.fk_health), so a call-level funnel would be fabricated.
--    Business question: "Where in the funnel do accounts drop out?"
create or replace table ana.funnel_monthly as
select month_start,
       count(*)                                         accounts_in_book,
       count(*) filter (where n_calls > 0)              accounts_dialled,
       count(*) filter (where n_calls_answered > 0)     accounts_answered,
       count(*) filter (where n_rpc > 0)                accounts_rpc,
       count(*) filter (where n_ptps > 0)               accounts_with_ptp,
       count(*) filter (where paid_flag)                accounts_paid,
       count(*) filter (where paid_flag and n_touches = 0) accounts_paid_without_any_touch
from gld.account_month where is_complete group by 1 order by 1;

-- 9. Agent-level outcomes for the funnel-plot test (is any agent outside binomial noise?)
create or replace table ana.agent_outcomes as
with c as (select agent_id, count(*) outbound_calls, sum(is_contact::int) answered
           from cln.calls where agent_id is not null and direction='OUTBOUND' group by 1),
d as (select agent_id, count(*) dispositions, sum(is_ptp::int) ptp_dispositions from cln.call_dispositions group by 1),
p as (select agent_id, count(*) filter (where is_due) due_ptps, sum((is_due and verified_kept)::int) kept_verified from gld.fct_ptp group by 1)
select * from c full join d using (agent_id) full join p using (agent_id);

-- 10. Daily KPI mart (for trend tests and the visualisation phase)
create or replace table mart.kpi_daily as
with d as (select range::date as dt from range(date '2026-01-01', date '2026-08-09', interval 1 day))
select d.dt as day_ist, dayname(d.dt) weekday, date_trunc('month', d.dt)::date month_start,
       coalesce(p.net_collections,0) net_collections, coalesce(p.n_payments,0) n_payments,
       coalesce(r.reported_success_with_dups,0) reported_success_with_dups
from d
left join (select event_at_ist::date dt, sum(net_amount) net_collections, count(*) n_payments from gld.fct_payment group by 1) p using (dt)
left join (select event_at_raw::date dt, sum(amount) filter (where payment_status='SUCCESS') reported_success_with_dups from stg.payments group by 1) r using (dt)
order by 1;

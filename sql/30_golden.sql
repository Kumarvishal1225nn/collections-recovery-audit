-- =====================================================================
-- 30_golden.sql  —  GOLDEN layer (the analytical source of truth)
--   gld.fct_touch          one row per borrower contact attempt, any channel, IST
--   gld.fct_payment        one row per recognised payment + attribution columns
--   gld.fct_ptp            PTPs with cash-verified outcome
--   gld.account_month      fixed-cohort panel: 30,000 accounts x months
--   gld.calendar_month     month metadata (days, complete flag)
-- =====================================================================
create schema if not exists gld;

create or replace table gld.calendar_month as
select m::date as month_start, last_day(m::date) as month_end,
       day(last_day(m::date)) as days_in_month,
       m::date < date '2026-08-01' as is_complete      -- data ends 2026-08-08
from generate_series(date '2026-01-01', date '2026-08-01', interval 1 month) t(m);

-- ---------------------------------------------------------------------
create or replace table gld.fct_touch as
select 'CALL' as channel, call_id as touch_id, account_id, event_at_ist, agent_id, campaign_id,
       vendor_id, is_contact as is_engaged, call_status as outcome
from cln.calls where direction = 'OUTBOUND'
union all
select 'WHATSAPP', message_id || '|' || account_id, account_id, min(event_at_ist), null, null,
       any_value(provider_id),
       bool_or(event_type in ('READ','REPLIED','PAYMENT_CLICK')), string_agg(distinct event_type, ',')
from cln.whatsapp_events group by message_id, account_id
union all
select 'SMS', message_id || '|' || account_id, account_id, min(event_at_ist), null, null,
       any_value(provider_id), bool_or(event_type = 'CLICKED'), string_agg(distinct event_type, ',')
from cln.sms_events group by message_id, account_id
union all
select 'FIELD', visit_id, account_id, event_at_ist, agent_id, null, null,
       outcome in ('CONTACTED','PTP','PAID','REFUSED'), outcome
from cln.field_visits;

-- ---------------------------------------------------------------------
-- Payments + attribution
--   attr_7d_*     : last touch in the 7 days BEFORE the payment (our rule)
--   naive_*       : "latest campaign on the account" as of report run (any time,
--                   can be AFTER the payment) -> what a snapshot-based report does
-- ---------------------------------------------------------------------
create or replace table gld.fct_payment as
with p as (select * from cln.payments where is_recognised),
last7 as (
    select p.payment_id, arg_max(t.channel, t.event_at_ist) as attr_7d_channel,
           max(t.event_at_ist) as attr_7d_touch_at
    from p join gld.fct_touch t
      on t.account_id = p.account_id
     and t.event_at_ist <  p.event_at_ist
     and t.event_at_ist >= p.event_at_ist - interval 7 day
    group by 1),
latest_call as (
    select account_id, arg_max(campaign_id, event_at_ist) as naive_campaign_id,
           max(event_at_ist) as naive_campaign_touch_at
    from cln.calls group by 1),
any_prior as (
    select p.payment_id, max(t.event_at_ist) as last_prior_touch_at
    from p join gld.fct_touch t on t.account_id = p.account_id and t.event_at_ist < p.event_at_ist
    group by 1)
select p.payment_id, p.account_id, p.event_at_ist, date_trunc('month', p.event_at_ist)::date as month_start,
       p.net_amount, p.payment_method, p.provider_id, p.flag_shared_reference,
       coalesce(l7.attr_7d_channel, 'NO_TOUCH_7D') as attr_7d_channel, l7.attr_7d_touch_at,
       lc.naive_campaign_id, lc.naive_campaign_touch_at,
       lc.naive_campaign_touch_at > p.event_at_ist as naive_touch_after_payment,
       date_diff('day', ap.last_prior_touch_at, p.event_at_ist) as days_since_last_touch
from p left join last7 l7 using (payment_id)
       left join latest_call lc using (account_id)
       left join any_prior ap using (payment_id);

-- ---------------------------------------------------------------------
create or replace table gld.fct_ptp as
select ptp_id, account_id, event_at_ist, date_trunc('month', event_at_ist)::date as month_start,
       agent_id, source, promised_amount, promised_date, reported_status, is_due,
       verified_kept, paid_in_window, flag_kept_before_due
from cln.promises_to_pay;

-- ---------------------------------------------------------------------
-- ACCOUNT-MONTH PANEL (fixed cohort: every account in the book, every month)
-- Denominator never shrinks: an account that is written off is still in the panel.
-- ---------------------------------------------------------------------
create or replace table gld.account_month as
with grid as (
    select a.account_id, c.month_start, c.month_end, c.days_in_month, c.is_complete
    from cln.dim_account a cross join gld.calendar_month c),
pay as (select account_id, month_start, count(*) n_payments, sum(net_amount) collected
        from gld.fct_payment group by all),
tch as (select account_id, date_trunc('month', event_at_ist)::date month_start,
               count(*) filter (where channel='CALL')     n_calls,
               count(*) filter (where channel='CALL' and is_engaged) n_calls_answered,
               count(*) filter (where channel='WHATSAPP') n_whatsapp,
               count(*) filter (where channel='SMS')      n_sms,
               count(*) filter (where channel='FIELD')    n_field_visits,
               count(*) n_touches
        from gld.fct_touch group by all),
att as (select account_id, date_trunc('month', event_at_ist)::date month_start, count(*) n_dial_attempts
        from cln.call_attempts group by all),
rpc as (select account_id, date_trunc('month', event_at_ist)::date month_start,
               count(*) filter (where is_rpc) n_rpc, count(*) filter (where is_ptp) n_ptp_dispositions
        from cln.call_dispositions group by all),
ptp as (select account_id, month_start, count(*) n_ptps from gld.fct_ptp group by all),
tgt as (select account_id, date_trunc('month', target_date)::date month_start, count(*) n_target_days,
               bool_or(strategy_generation = 'NEW') targeted_new_strategy,
               bool_or(strategy_generation = 'OLD') targeted_old_strategy
        from cln.daily_targeting group by all),
cmp as (select account_id, date_trunc('month', event_at_ist)::date month_start, count(*) n_complaints
        from cln.complaints group by all),
st as (  -- status as known at the START of the month (for the denominator-manipulation test)
    select g.account_id, g.month_start,
           arg_max(h.status, h.event_at_ist) as status_at_month_start
    from grid g join cln.account_status_history h
      on h.account_id = g.account_id and h.event_at_ist < g.month_start
    group by all)
select g.account_id, g.month_start, g.days_in_month, g.is_complete,
       a.loan_type, a.dpd, a.dpd_bucket, a.risk_segment, a.snapshot_status, a.outstanding_amount,
       a.principal_amount, coalesce(a.state,'UNKNOWN') as state, coalesce(a.city,'UNKNOWN') as city,
       a.account_timezone, a.flag_geo_conflict,
       coalesce(pay.n_payments,0) n_payments, coalesce(pay.collected,0) collected,
       coalesce(pay.n_payments,0) > 0 as paid_flag,
       coalesce(tch.n_calls,0) n_calls, coalesce(tch.n_calls_answered,0) n_calls_answered,
       coalesce(tch.n_whatsapp,0) n_whatsapp, coalesce(tch.n_sms,0) n_sms,
       coalesce(tch.n_field_visits,0) n_field_visits, coalesce(tch.n_touches,0) n_touches,
       coalesce(att.n_dial_attempts,0) n_dial_attempts,
       coalesce(rpc.n_rpc,0) n_rpc, coalesce(rpc.n_ptp_dispositions,0) n_ptp_dispositions,
       coalesce(ptp.n_ptps,0) n_ptps,
       coalesce(tgt.n_target_days,0) n_target_days,
       coalesce(tgt.targeted_new_strategy,false) targeted_new_strategy,
       coalesce(tgt.targeted_old_strategy,false) targeted_old_strategy,
       coalesce(cmp.n_complaints,0) n_complaints,
       coalesce(st.status_at_month_start,'NO_HISTORY') status_at_month_start
from grid g
join cln.dim_account a using (account_id)
left join pay using (account_id, month_start)
left join tch using (account_id, month_start)
left join att using (account_id, month_start)
left join rpc using (account_id, month_start)
left join ptp using (account_id, month_start)
left join tgt using (account_id, month_start)
left join cmp using (account_id, month_start)
left join st  using (account_id, month_start);

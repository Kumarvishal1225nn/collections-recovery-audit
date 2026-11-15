-- =====================================================================
-- 50_forensics.sql  —  Data-forensics tests (Part 2 A–G + reconstruction of "11%")
-- Every table here is exported to outputs/forensics/*.csv by run_pipeline.py
-- =====================================================================
create schema if not exists fx;

-- F0  Reconstruct the reported "+11% MoM".
--     Candidate definitions are computed side by side; the one that reproduces 11.0%
--     is: SUM(amount) WHERE status='SUCCESS', raw rows (duplicates included),
--     calendar month, Mar-2026 vs Feb-2026.
create or replace table fx.f0_reported_mom as
with m as (
    select date_trunc('month', event_at_raw)::date month_start,
           sum(amount)                                         all_rows,
           sum(amount) filter (where payment_status='SUCCESS')  success_with_dups,
           sum(amount) filter (where payment_status in ('SUCCESS','PENDING')) success_plus_pending,
           count(*)    filter (where payment_status='SUCCESS')  success_count
    from stg.payments group by 1)
select m.*, c.days_in_month,
       100*(success_with_dups/lag(success_with_dups) over w - 1)       as mom_success_with_dups_pct,
       100*(all_rows/lag(all_rows) over w - 1)                         as mom_all_rows_pct,
       100*(success_plus_pending/lag(success_plus_pending) over w - 1) as mom_success_plus_pending_pct,
       100*(success_count/lag(success_count) over w - 1)               as mom_success_count_pct
from m join gld.calendar_month c using (month_start)
window w as (order by month_start) order by 1;

-- A  Duplicate payments
create or replace table fx.a_duplicate_payments as
with d as (select payment_id, count(*) n, any_value(amount) amount, any_value(payment_status) status,
                  date_trunc('month', any_value(event_at_raw))::date month_start
           from stg.payments group by 1 having count(*) > 1)
select month_start, count(*) duplicated_ids, sum(n-1) extra_rows,
       sum(case when status='SUCCESS' then amount*(n-1) else 0 end) inflated_success_inr
from d group by 1 order by 1;

-- B  Attribution
create or replace table fx.b_attribution as
select count(*) payments,
       sum(net_amount) amount,
       count(*) filter (where naive_touch_after_payment)                            naive_campaign_touch_after_payment,
       sum(net_amount) filter (where naive_touch_after_payment)                     naive_after_payment_inr,
       count(*) filter (where attr_7d_channel='NO_TOUCH_7D')                        no_touch_in_7d,
       sum(net_amount) filter (where attr_7d_channel='NO_TOUCH_7D')                 no_touch_in_7d_inr,
       count(*) filter (where days_since_last_touch is null)                        never_touched_before_payment,
       median(days_since_last_touch)                                                median_days_since_last_touch
from gld.fct_payment;

create or replace table fx.b_attribution_by_channel as
select attr_7d_channel, count(*) payments, sum(net_amount) amount_inr,
       100.0*count(*)/sum(count(*)) over () pct_of_payments
from gld.fct_payment group by 1 order by 2 desc;

-- C  Timezones
create or replace table fx.c_timezone_calls as
select src_timezone, count(*) calls,
       count(*) filter (where hour(event_at_local) <> hour(event_at_ist))            hour_changed,
       count(*) filter (where event_at_local::date <> event_at_ist::date)            date_changed,
       count(*) filter (where date_trunc('month',event_at_local) <> date_trunc('month',event_at_ist)) month_changed,
       100.0*count(*) filter (where hour(event_at_local) not between 8 and 18)/count(*) pct_outside_8_19_raw_clock,
       100.0*count(*) filter (where hour(event_at_ist)   not between 8 and 18)/count(*) pct_outside_8_19_ist
from cln.calls group by 1 order by 1;

create or replace table fx.c_call_tz_vs_vendor_tz as
select c.src_timezone call_row_tz, v.vendor_timezone, count(*) calls
from cln.calls c join cln.dim_vendor v using (vendor_id) group by all order by all;

-- Payment clock sensitivity: payments have no tz column. If they were really UTC
-- (or Dubai) how much would month totals move?
create or replace table fx.c_payment_clock_sensitivity as
with p as (select net_amount, event_at_ist from cln.payments where is_recognised)
select m.month_start, i.assume_ist, u.assume_utc, d.assume_dubai,
       100*(u.assume_utc/i.assume_ist - 1) as utc_vs_ist_pct
from gld.calendar_month m
left join (select date_trunc('month', event_at_ist)::date month_start, sum(net_amount) assume_ist from p group by 1) i using (month_start)
left join (select date_trunc('month', to_ist(event_at_ist,'UTC'))::date month_start, sum(net_amount) assume_utc from p group by 1) u using (month_start)
left join (select date_trunc('month', to_ist(event_at_ist,'Asia/Dubai'))::date month_start, sum(net_amount) assume_dubai from p group by 1) d using (month_start)
order by 1;

-- D  Vendor / disposition code mapping changes
create or replace table fx.d_disposition_version_by_month as
select date_trunc('month', event_at_ist)::date month_start, disposition_version, count(*) n,
       100.0*count(*) filter (where is_rpc)/count(*) rpc_pct,
       100.0*count(*) filter (where disposition_code_raw='PTP')/count(*) short_ptp_code_pct,
       100.0*count(*) filter (where disposition_code_raw='PROMISE_TO_PAY')/count(*) long_ptp_code_pct
from cln.call_dispositions group by all order by all;

create or replace table fx.d_vendor_answer_rate_by_month as
select v.vendor_name, v.schema_version, date_trunc('month', c.event_at_ist)::date month_start,
       count(*) calls, 100.0*avg(c.is_contact::int) answer_rate_pct
from cln.calls c join cln.dim_vendor v using (vendor_id) where c.direction='OUTBOUND'
group by all order by all;

-- E  Agent identity
create or replace table fx.e_agent_identity as
select 'versions per agent_id' metric, avg(n)::double avg_v, min(n) min_v, max(n) max_v from
   (select agent_id, count(*) n from cln.dim_agent_scd group by 1)
union all select 'distinct employee_codes per agent_id', avg(n), min(n), max(n) from
   (select agent_id, count(distinct employee_code) n from cln.dim_agent_scd group by 1)
union all select 'distinct agent_ids per employee_code', avg(n), min(n), max(n) from
   (select employee_code, count(distinct agent_id) n from cln.dim_agent_scd group by 1)
union all select 'distinct names per agent_id', avg(n), min(n), max(n) from
   (select agent_id, count(distinct agent_name) n from cln.dim_agent_scd group by 1)
union all select 'distinct joined_at per agent_id', avg(n), min(n), max(n) from
   (select agent_id, count(distinct joined_at) n from cln.dim_agent_scd group by 1);

-- F  Portfolio mix
create or replace table fx.f_portfolio_vintage as
select date_trunc('quarter', opened_at_local)::date opened_quarter, count(*) accounts,
       sum(outstanding_amount) outstanding
from cln.dim_account group by 1 order by 1;

create or replace table fx.f_paying_mix_by_dpd as
select month_start, dpd_bucket, count(*) filter (where paid_flag) paying_accounts,
       sum(collected) collected, count(*) filter (where n_touches>0) worked_accounts
from gld.account_month group by all order by all;

-- G  Denominator manipulation
create or replace table fx.g_denominator as
select month_start, recovery_rate_pct as fixed_cohort_rate_pct,
       recovery_rate_survivor_denominator_pct, active_accounts
from mart.kpi_monthly order by 1;

-- Extra: PTP label integrity
create or replace table fx.h_ptp_integrity as
select reported_status, count(*) ptps, count(*) filter (where is_due) due,
       count(*) filter (where flag_kept_before_due) kept_before_due,
       100.0*count(*) filter (where is_due and verified_kept)/nullif(count(*) filter (where is_due),0) verified_kept_pct
from gld.fct_ptp group by 1 order by 1;

-- Extra: campaign definition integrity
create or replace table fx.i_campaign_integrity as
select c.target_definition, count(*) targetings,
       100.0*avg(case when c.target_definition='DPD>=30' then (a.dpd>=30)::int
                      when c.target_definition='DPD>=60' then (a.dpd>=60)::int
                      when c.target_definition='NPA'     then (a.dpd>=90)::int end) pct_matching_definition
from cln.daily_targeting t join cln.dim_campaign c using (campaign_id) join cln.dim_account a using (account_id)
group by 1 order by 1;

create or replace table fx.i_calls_outside_campaign_window as
select count(*) calls, count(*) filter (where c.event_at_ist not between k.start_at and k.end_at) outside_window,
       100.0*count(*) filter (where c.event_at_ist not between k.start_at and k.end_at)/count(*) pct_outside
from cln.calls c join cln.dim_campaign k using (campaign_id);

-- Extra: relational integrity (IDs on events vs master)
create or replace table fx.j_relational_integrity as
select 'call_attempts.account_id <> calls.account_id for same call_id' test,
       count(*) filter (where a.account_id <> c.account_id) failures, count(*) total
from cln.call_attempts a join cln.calls c using (call_id)
union all
select 'call_dispositions.account_id <> calls.account_id for same call_id',
       count(*) filter (where d.account_id <> c.account_id), count(*)
from cln.call_dispositions d join cln.calls c using (call_id)
union all
select 'payments.borrower_id <> accounts.borrower_id',
       count(*) filter (where p.borrower_id <> a.borrower_id), count(*)
from stg.payments p join cln.dim_account a using (account_id);


-- =====================================================================
-- v3 additions
-- =====================================================================

-- A2  Duplicate payments classified by evidence (never deleted on the ID alone)
create or replace table fx.a_duplicate_payment_classes as
select duplicate_class, payment_status, count(*) groups, sum(n_rows - 1) extra_rows,
       sum(amount * (n_rows - 1)) extra_amount_inr,
       bool_and(is_same_payment) all_provably_same_payment,
       min(last_src_row) min_row_of_second_copy, max(last_src_row) max_row_of_second_copy
from cln.payment_duplicate_groups group by all order by all;

-- A3  Other duplicate / retry patterns that would inflate cash if present
create or replace table fx.a_retry_patterns as
select 'same account + same amount, different payment_id' pattern,
       (select count(*) from (select account_id, amount from cln.payments group by all having count(*) > 1)) n
union all select 'same account + same reference, different payment_id',
       (select count(*) from (select account_id, payment_reference from cln.payments where payment_reference is not null group by all having count(*) > 1))
union all select 'two payments on one account within 10 minutes',
       (select count(*) from (select date_diff('second', lag(event_at_ist) over (partition by account_id order by event_at_ist), event_at_ist) gap from cln.payments) where gap <= 600)
union all select 'FAILED then SUCCESS on same account within 24h (possible retry; both rows legitimate)',
       (select count(*) from cln.payments a join cln.payments b on a.account_id=b.account_id and a.payment_status='FAILED'
          and b.payment_status='SUCCESS' and b.event_at_ist > a.event_at_ist and b.event_at_ist <= a.event_at_ist + interval 1 day)
union all select 'shared payment_reference groups with a matching amount or timestamp inside the group',
       (select count(*) from (select payment_reference from cln.payments where payment_reference is not null
          group by 1 having count(*) > 1 and (count(distinct amount) < count(*) or count(distinct event_at_ist) < count(*))));

-- K  Late-arriving / re-dated events: what the data lets us measure
create or replace table fx.k_late_arrival as
select 'account_status_history: recorded_at - event_at (hours), min' metric, min(date_diff('minute', event_at_ist, recorded_at))/60.0 val from cln.account_status_history
union all select 'account_status_history: recorded_at - event_at (hours), max', max(date_diff('minute', event_at_ist, recorded_at))/60.0 from cln.account_status_history
union all select 'account_status_history: rows recorded >24h after event', count(*) filter (where date_diff('hour', event_at_ist, recorded_at) > 24) from cln.account_status_history
union all select 'calls: duplicate call_ids whose copies are dated whole days apart', count(*) filter (where flag_conflicting_timestamp) from cln.calls
union all select 'calls: events dated outside the common window (before 1 Jan or after 8 Aug, IST)', count(*) filter (where event_at_ist < timestamp '2026-01-01' or event_at_ist >= timestamp '2026-08-09') from cln.calls
union all select 'payments: ingestion timestamp available (0 = no, lateness not measurable)', 0;

-- L  Payments versus the account balance (is outstanding_amount a pre- or post-payment figure?)
create or replace table fx.l_paid_vs_outstanding as
with s as (select account_id, sum(net_amount) paid from gld.fct_payment group by 1)
select count(*) paying_accounts,
       count(*) filter (where s.paid > a.outstanding_amount) accounts_paid_more_than_outstanding,
       sum(greatest(s.paid - a.outstanding_amount, 0)) excess_inr,
       sum(s.paid) total_paid_inr,
       count(*) filter (where a.flag_outstanding_gt_principal) payers_with_outstanding_gt_principal
from s join cln.dim_account a using (account_id);

-- M  Cash by account snapshot status (does status mean anything?)
create or replace table fx.m_cash_by_snapshot_status as
select a.snapshot_status, count(*) payments, sum(p.net_amount) inr,
       100.0*sum(p.net_amount)/sum(sum(p.net_amount)) over () pct_of_cash
from gld.fct_payment p join cln.dim_account a using (account_id) group by 1 order by 1;

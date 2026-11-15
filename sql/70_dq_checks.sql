-- =====================================================================
-- 70_dq_checks.sql  —  Data-quality assertions (run after every build)
-- Each row = one check. status = PASS / FAIL. Pipeline exits non-zero on any
-- FAIL whose severity = 'BLOCK'. 'WARN' failures are reported, not blocking.
-- =====================================================================
create schema if not exists dq;

create or replace table dq.results as
with t as (
  select 'gld.fct_payment PK unique' check_name, 'BLOCK' severity,
         (select count(*) - count(distinct payment_id) from gld.fct_payment) observed, 0 threshold
  union all select 'cln.calls PK unique', 'BLOCK',
         (select count(*) - count(distinct call_id) from cln.calls), 0
  union all select 'gld.account_month grain unique', 'BLOCK',
         (select count(*) - count(distinct (account_id, month_start)) from gld.account_month), 0
  union all select 'payments reconcile: golden = clean SUCCESS', 'BLOCK',
         (select abs((select sum(net_amount) from gld.fct_payment) - (select sum(net_amount) from cln.payments))), 1
  union all select 'panel reconcile: account_month = fct_payment', 'BLOCK',
         (select abs((select sum(collected) from gld.account_month) - (select sum(net_amount) from gld.fct_payment))), 1
  union all select 'gld.fct_touch PK unique (channel, touch_id)', 'BLOCK',
         (select count(*) - count(distinct (channel, touch_id)) from gld.fct_touch), 0
  union all select 'account_month rows = accounts x months (no fan-out / loss)', 'BLOCK',
         (select abs((select count(*) from gld.account_month) - (select count(*) from cln.dim_account)*(select count(*) from gld.calendar_month))), 0
  union all select 'PTP allocated cash <= recognised cash (no double claim)', 'BLOCK',
         (select greatest(0, (select sum(paid_in_window) from cln.promises_to_pay) - (select sum(net_amount) from cln.payments where is_recognised))), 0
  union all select 'golden payment rows = clean SUCCESS rows', 'BLOCK',
         (select abs((select count(*) from gld.fct_payment) - (select count(*) from cln.payments where is_recognised))), 0
  union all select 'duplicate payment groups not provably the same payment', 'BLOCK',
         (select count(*) from cln.payment_duplicate_groups where not is_same_payment), 0
  union all select 'no negative / null payment amounts', 'BLOCK',
         (select count(*) from gld.fct_payment where net_amount is null or net_amount <= 0), 0
  union all select 'every payment maps to an account', 'BLOCK',
         (select count(*) from gld.fct_payment p where not exists (select 1 from cln.dim_account a where a.account_id=p.account_id)), 0
  union all select 'all IST timestamps parsed (calls)', 'BLOCK',
         (select count(*) from cln.calls where event_at_ist is null), 0
  union all select 'duplicate payment rate in raw (%)', 'WARN',
         (select 100.0*(count(*)-count(distinct payment_id))/count(*) from stg.payments), 1
  union all select 'calls missing agent (%)', 'WARN',
         (select 100.0*avg(flag_missing_agent::int) from cln.calls), 1
  union all select 'calls outside 08:00-19:00 IST (%)', 'WARN',
         (select 100.0*avg(flag_outside_8am_7pm_ist::int) from cln.calls), 5
  union all select 'PTP marked KEPT before due date', 'WARN',
         (select count(*) from gld.fct_ptp where flag_kept_before_due), 0
  union all select 'accounts without resolvable borrower (%)', 'WARN',
         (select 100.0*avg((flag_missing_borrower or flag_orphan_borrower)::int) from cln.dim_account), 2
)
select *, case when observed <= threshold then 'PASS' else 'FAIL' end as status from t;

-- =====================================================================
-- 20_clean.sql  —  CLEAN layer
-- Deduplication, entity resolution, history handling, exclusion flags.
-- Every rule writes to cln.rejection_log so Raw -> Rejected/Corrected -> Clean
-- is fully auditable (see outputs/cleaning_waterfall.csv).
-- =====================================================================
create schema if not exists cln;

create or replace table cln.rejection_log (
    table_name varchar, rule_id varchar, rule varchar, action varchar,
    rows_affected bigint, amount_inr double);

-- ---------------------------------------------------------------------
-- PAYMENTS
--   Evidence examined before deleting anything (fx.a_duplicate_payment_classes):
--     500 payment_ids appear twice. In every group the two rows agree on account, borrower,
--     amount, timestamp (to the second), status, method and provider. The second copy always
--     sits in the last 500 rows of the file (an appended block = re-ingestion).
--       * 486 groups: every column identical                      -> class IDENTICAL
--       * 14 groups: identical except one copy has a NULL payment_reference -> class REFERENCE_DROPPED
--     No group has two different references, amounts, times or statuses, so none is ambiguous:
--     each group is one payment recorded twice.
--   R-PAY-1a/b  keep ONE row per payment_id; survivor = the copy that still carries the reference
--               (v3 fix: v2 kept the first row, which kept the reference-less copy in 3 groups)
--   R-PAY-2     payment_reference shared by different accounts/amounts -> NOT a duplicate
--   R-PAY-3     only SUCCESS is cash. PENDING/FAILED/REVERSED excluded from recovery
-- ---------------------------------------------------------------------
create or replace table cln.payment_duplicate_groups as
select payment_id, count(*) n_rows,
       case when count(distinct coalesce(payment_reference,'<NULL>')) = 1 then 'IDENTICAL' else 'REFERENCE_DROPPED' end as duplicate_class,
       count(distinct account_id)=1 and count(distinct amount)=1 and count(distinct event_at_raw)=1
         and count(distinct payment_status)=1 and count(distinct payment_method)=1
         and count(distinct provider_id)=1 and count(distinct payment_reference) <= 1 as is_same_payment,
       any_value(payment_status) payment_status, any_value(amount) amount,
       min(_src_row) first_src_row, max(_src_row) last_src_row
from stg.payments group by 1 having count(*) > 1;

create or replace table cln.payments as
with ranked as (
    select *, row_number() over (partition by payment_id
                                 order by (payment_reference is null), _src_row) as rn
    from stg.payments)
select payment_id, account_id, borrower_id, event_at_ist, payment_reference, amount,
       payment_status, payment_method, provider_id,
       (payment_status = 'SUCCESS')                                  as is_recognised,
       case when payment_status = 'SUCCESS' then amount else 0 end   as net_amount,
       count(*) over (partition by payment_reference) > 1 and payment_reference is not null
                                                                     as flag_shared_reference,
       payment_reference is null                                     as flag_missing_reference,
       _src_row
from ranked where rn = 1;

insert into cln.rejection_log
select 'payments','R-PAY-1a','duplicate payment_id, every column identical','1 copy removed per group',
       count(*), sum(amount) filter (where payment_status='SUCCESS')
from cln.payment_duplicate_groups where duplicate_class='IDENTICAL';
insert into cln.rejection_log
select 'payments','R-PAY-1b','duplicate payment_id, identical except reference missing on one copy','reference-less copy removed',
       count(*), sum(amount) filter (where payment_status='SUCCESS')
from cln.payment_duplicate_groups where duplicate_class='REFERENCE_DROPPED';
insert into cln.rejection_log
select 'payments','R-PAY-1c','duplicate payment_id groups that are NOT provably the same payment','none found (would be quarantined, not deleted)',
       count(*), null from cln.payment_duplicate_groups where not is_same_payment;
insert into cln.rejection_log
select 'payments','R-PAY-2','payment_reference reused across different accounts','kept + flagged',
       count(*) filter (where flag_shared_reference), null from cln.payments;
insert into cln.rejection_log
select 'payments','R-PAY-3','status not SUCCESS (FAILED/PENDING/REVERSED)','excluded from recovery',
       count(*) filter (where not is_recognised), sum(amount) filter (where not is_recognised)
from cln.payments;
insert into cln.rejection_log
select 'payments','R-PAY-4','missing payment_reference','kept + flagged',
       count(*) filter (where flag_missing_reference), sum(net_amount) filter (where flag_missing_reference)
from cln.payments;

-- ---------------------------------------------------------------------
-- CALLS
--   R-CALL-1 duplicate call_id: keep the copy WITH an agent, then the EARLIEST timestamp
--            (later copies are re-ingestions whose date was shifted by whole days)
-- ---------------------------------------------------------------------
create or replace table cln.calls as
with ranked as (
    select *, row_number() over (partition by call_id
                 order by (agent_id is null), event_at_ist, _src_row) as rn,
           count(*) over (partition by call_id) as n_copies,
           count(distinct event_at_ist) over (partition by call_id) as n_ts
    from stg.calls)
select call_id, account_id, event_at_local, src_timezone, event_at_ist, agent_id, campaign_id,
       direction, vendor_id, call_status, duration_sec,
       call_status = 'ANSWERED'                   as is_contact,
       n_ts > 1                                   as flag_conflicting_timestamp,
       agent_id is null                           as flag_missing_agent,
       hour(event_at_ist) not between 8 and 18    as flag_outside_8am_7pm_ist,
       _src_row
from ranked where rn = 1;

insert into cln.rejection_log
select 'calls','R-CALL-1','duplicate call_id rows','removed (kept agent-bearing, earliest copy)',
       (select count(*) from stg.calls) - (select count(*) from cln.calls), null;
insert into cln.rejection_log
select 'calls','R-CALL-2','duplicate call_id with timestamps 1-5 days apart','earliest kept, flagged',
       count(*) filter (where flag_conflicting_timestamp), null from cln.calls;
insert into cln.rejection_log
select 'calls','R-CALL-3','missing agent_id','kept; excluded from agent metrics',
       count(*) filter (where flag_missing_agent), null from cln.calls;
insert into cln.rejection_log
select 'calls','R-CALL-4','timestamp re-based from UTC/Dubai to IST','corrected',
       count(*) filter (where src_timezone <> 'Asia/Kolkata'), null from cln.calls;

-- ---------------------------------------------------------------------
-- CALL ATTEMPTS / DISPOSITIONS (no duplicate IDs; vendor gaps & code harmonisation)
-- ---------------------------------------------------------------------
create or replace table cln.call_attempts as select * from stg.call_attempts;
insert into cln.rejection_log
select 'call_attempts','R-ATT-1','missing vendor_id','set to UNKNOWN',
       count(*) filter (where vendor_id='UNKNOWN'), null from cln.call_attempts;

-- Right-Party-Contact = we spoke to the borrower and they engaged on the debt.
-- CALLBACK is excluded (could be a third party asking us to call later).
create or replace table cln.call_dispositions as
select *,
       disposition_code in ('PROMISE_TO_PAY','PTP_BROKEN','PAID','DISPUTE','REFUSED') as is_rpc,
       disposition_code = 'PROMISE_TO_PAY'                                          as is_ptp
from stg.call_dispositions;
insert into cln.rejection_log
select 'call_dispositions','R-DISP-1','legacy short code PTP mapped to PROMISE_TO_PAY','corrected',
       count(*) filter (where disposition_code_raw='PTP'), null from cln.call_dispositions;

-- ---------------------------------------------------------------------
-- DIGITAL / FIELD
-- ---------------------------------------------------------------------
create or replace table cln.whatsapp_events as
select * exclude (rn) from (
    select *, row_number() over (partition by event_id order by _src_row) rn from stg.whatsapp_events)
where rn = 1;
insert into cln.rejection_log
select 'whatsapp_events','R-WA-1','exact duplicate event_id rows','removed',
       (select count(*) from stg.whatsapp_events) - (select count(*) from cln.whatsapp_events), null;

create or replace table cln.sms_events as select * from stg.sms_events;
insert into cln.rejection_log
select 'whatsapp_events','R-WA-2','message_id attached to more than one account','kept; touch key = message_id x account_id',
       count(*) filter (where n > 1), null from (select message_id, count(distinct account_id) n from cln.whatsapp_events group by 1);
insert into cln.rejection_log
select 'sms_events','R-SMS-1','message_id attached to more than one account','kept; touch key = message_id x account_id',
       count(*) filter (where n > 1), null from (select message_id, count(distinct account_id) n from cln.sms_events group by 1);

create or replace table cln.field_visits as
select *, hour(event_at_ist) not between 8 and 18 as flag_outside_8am_7pm_ist from stg.field_visits;
insert into cln.rejection_log
select 'field_visits','R-FV-1','missing scheduled_at','kept + flagged',
       count(*) filter (where scheduled_at is null), null from cln.field_visits;

create or replace table cln.complaints as select * from stg.complaints;

-- ---------------------------------------------------------------------
-- PROMISES TO PAY
--   Reported status (KEPT/BROKEN) is an agent-entered label. We re-derive it from cash:
--   verified_kept = a SUCCESS payment on the same account between PTP creation and
--   promised_date + 3 days grace, totalling >= 50% of the promised amount.
--   PTPs whose promised_date + grace is after the data cutoff are NOT yet due.
-- ---------------------------------------------------------------------
--   v2 fix: a payment may fall inside the window of several PTPs on the same account.
--   To avoid counting the same cash twice, each payment is allocated to ONE PTP only:
--   the earliest-created PTP whose window contains it (first promise, first served).
create or replace table cln.promises_to_pay as
with cutoff as (select max(event_at_ist) as data_cutoff from cln.payments),
candidates as (
    select p.ptp_id, pay.payment_id, pay.net_amount,
           row_number() over (partition by pay.payment_id order by p.event_at_ist, p.ptp_id) as claim_rank
    from stg.promises_to_pay p
    join cln.payments pay
      on pay.account_id = p.account_id and pay.is_recognised
     and pay.event_at_ist between p.event_at_ist and p.promised_date + interval 3 day),
paid as (
    select ptp_id, sum(net_amount) as paid_in_window, count(*) as payments_allocated
    from candidates where claim_rank = 1 group by 1)
select p.*, coalesce(paid.paid_in_window,0) as paid_in_window,
       (p.promised_date + interval 3 day) <= c.data_cutoff                     as is_due,
       coalesce(paid.paid_in_window,0) >= 0.5 * p.promised_amount              as verified_kept,
       p.reported_status = 'KEPT' and (p.promised_date + interval 3 day) > c.data_cutoff
                                                                               as flag_kept_before_due
from stg.promises_to_pay p cross join cutoff c left join paid using (ptp_id);
insert into cln.rejection_log
select 'promises_to_pay','R-PTP-2','payment inside the window of >1 PTP','allocated to earliest PTP only',
       (select count(*) from (select pay.payment_id from stg.promises_to_pay p join cln.payments pay
          on pay.account_id=p.account_id and pay.is_recognised
         and pay.event_at_ist between p.event_at_ist and p.promised_date + interval 3 day
        group by 1 having count(*)>1)), null;
insert into cln.rejection_log
select 'promises_to_pay','R-PTP-1','status KEPT although promised date is after data cutoff','flagged; status re-derived from payments',
       count(*) filter (where flag_kept_before_due), null from cln.promises_to_pay;

-- ---------------------------------------------------------------------
-- BORROWERS  (multiple conflicting versions per borrower_id)
--   Survivor = latest updated_at among versions where updated_at >= created_at;
--   if none valid, latest created_at.
-- ---------------------------------------------------------------------
create or replace table cln.dim_borrower as
with v as (
    select *, updated_at >= created_at as valid_order,
           count(*) over (partition by borrower_id) as n_versions,
           count(distinct city) over (partition by borrower_id) as n_cities
    from stg.borrowers),
ranked as (
    select *, row_number() over (partition by borrower_id
              order by valid_order desc, case when valid_order then updated_at else created_at end desc, _src_row) rn
    from v)
select borrower_id, city, state, n_versions, n_cities, not valid_order as flag_survivor_invalid_dates
from ranked where rn = 1;
insert into cln.rejection_log
select 'borrowers','R-BRW-1','multiple versions per borrower_id','collapsed to 1 survivor',
       (select count(*) from stg.borrowers) - (select count(*) from cln.dim_borrower), null;
insert into cln.rejection_log
select 'borrowers','R-BRW-2','updated_at earlier than created_at','version de-prioritised',
       count(*) filter (where updated_at < created_at), null from stg.borrowers;
insert into cln.rejection_log
select 'borrowers','R-BRW-3','borrower has >1 city across versions (geography unreliable)','flagged',
       count(*) filter (where n_cities > 1), null from cln.dim_borrower;

-- ---------------------------------------------------------------------
-- ACCOUNTS  -> dimension with resolved borrower geography
-- ---------------------------------------------------------------------
create or replace table cln.dim_account as
select a.*, b.city, b.state, coalesce(b.n_cities,0) > 1 as flag_geo_conflict,
       a.borrower_id is null as flag_missing_borrower,
       a.borrower_id is not null and b.borrower_id is null as flag_orphan_borrower,
       a.outstanding_amount > a.principal_amount as flag_outstanding_gt_principal
from stg.accounts a left join cln.dim_borrower b using (borrower_id);
insert into cln.rejection_log
select 'accounts','R-ACC-1','missing borrower_id','kept; geography = UNKNOWN',
       count(*) filter (where flag_missing_borrower), null from cln.dim_account;
insert into cln.rejection_log
select 'accounts','R-ACC-2','borrower_id not found in borrowers','kept; geography = UNKNOWN',
       count(*) filter (where flag_orphan_borrower), null from cln.dim_account;
insert into cln.rejection_log
select 'accounts','R-ACC-3','risk_segment inconsistent with DPD (e.g. NPA at 0 DPD)','DPD used as truth',
       count(*) filter (where (risk_segment='NPA' and dpd < 90) or (risk_segment='LOW' and dpd >= 90)), null
from cln.dim_account;

-- ---------------------------------------------------------------------
-- AGENTS  (~30 overwritten versions per agent_id; employee_code is many-to-many)
--   Type-2 SCD keyed on agent_id: version valid from updated_at until next updated_at.
--   agent_id is the only identifier used by event tables -> it is the canonical key.
--   employee_code CANNOT be used to merge identities (one code maps to ~30 agent_ids).
-- ---------------------------------------------------------------------
create or replace table cln.dim_agent_scd as
select agent_id, employee_code, agent_name, vendor_id, team, status, joined_at,
       updated_at as valid_from,
       coalesce(lead(updated_at) over (partition by agent_id order by updated_at, _src_row),
                timestamp '2099-01-01') as valid_to,
       row_number() over (partition by agent_id order by updated_at, _src_row) as version_no
from stg.agents;
insert into cln.rejection_log
select 'agents','R-AGT-1','overwritten agent master versions','modelled as SCD-2 (as-of join)',
       count(*) - count(distinct agent_id), null from stg.agents;

-- ---------------------------------------------------------------------
-- AGENT SESSIONS  (overlapping sessions for the same agent would double-count hours)
-- ---------------------------------------------------------------------
create or replace table cln.agent_sessions as
with s as (select *, date_diff('second', login_at_ist, logout_at_ist)/3600.0 as hours_raw from stg.agent_sessions),
o as (select a.session_id, max(least(a.logout_at_ist,b.logout_at_ist)) as ov_end,
             min(greatest(a.login_at_ist,b.login_at_ist)) as ov_start
      from s a join s b on a.agent_id=b.agent_id and a.session_id > b.session_id
       and a.login_at_ist < b.logout_at_ist and b.login_at_ist < a.logout_at_ist
      group by 1)
select s.*, coalesce(date_diff('second', o.ov_start, o.ov_end)/3600.0,0) as overlap_hours,
       hours_raw - coalesce(date_diff('second', o.ov_start, o.ov_end)/3600.0,0) as hours_clean
from s left join o using (session_id);
insert into cln.rejection_log
select 'agent_sessions','R-SES-1','session overlaps another session of same agent','overlap hours removed',
       count(*) filter (where overlap_hours > 0), null from cln.agent_sessions;

-- ---------------------------------------------------------------------
-- TARGETING  (duplicate account x date rows)
--   ASSUMPTION A-07: priority 1 = most urgent (no dictionary). Lowest priority number kept.
-- ---------------------------------------------------------------------
create or replace table cln.daily_targeting as
select * exclude (rn) from (
    select t.*, c.strategy_version, c.strategy_generation, c.target_definition,
           row_number() over (partition by t.account_id, t.target_date order by t.priority, t._src_row) rn
    from stg.daily_targeting t left join stg.campaigns c using (campaign_id))
where rn = 1;
insert into cln.rejection_log
select 'daily_targeting','R-TGT-1','same account targeted twice on same date','kept highest priority',
       (select count(*) from stg.daily_targeting) - (select count(*) from cln.daily_targeting), null;

create or replace table cln.dim_campaign as select * from stg.campaigns;
create or replace table cln.dim_vendor   as select * from stg.vendor_telephony;

-- ---------------------------------------------------------------------
-- ACCOUNT STATUS HISTORY
--   recorded_at is within +/-24h of event_at (both directions) -> clock skew, not lateness.
--   Ordering uses event_at; ties broken by recorded_at (last write wins).
-- ---------------------------------------------------------------------
create or replace table cln.account_status_history as
select *, recorded_at < event_at_ist as flag_recorded_before_event from stg.account_status_history;
insert into cln.rejection_log
select 'account_status_history','R-ASH-1','recorded_at earlier than event_at (clock skew)','flagged; event_at used for ordering',
       count(*) filter (where flag_recorded_before_event), null from cln.account_status_history;

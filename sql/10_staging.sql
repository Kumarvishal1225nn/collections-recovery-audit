-- =====================================================================
-- 10_staging.sql  —  STAGING layer
-- * Cast every column to its real type
-- * Normalise IDs (trim / upper) and categorical codes
-- * Convert every timestamp to ONE reporting clock: IST (Asia/Kolkata)
--
-- Timestamp policy (see docs/data_quality_report.md §3):
--   calls, agent_sessions : carry a row-level `timezone` -> trusted, converted to IST
--   all other event tables: carry no timezone. Assumed to be IST (platform clock).
--                           Sensitivity of this assumption is tested in 50_forensics.sql
--   Offsets are fixed (no DST in IST / GST / UTC): UTC=0, Asia/Dubai=+240, Asia/Kolkata=+330 min
-- =====================================================================
create schema if not exists stg;

create or replace macro tz_offset_min(tz) as
    case tz when 'UTC' then 0 when 'Asia/Dubai' then 240 when 'Asia/Kolkata' then 330 end;

-- local wall-clock time in `tz`  ->  IST wall-clock time
create or replace macro to_ist(ts, tz) as
    ts + to_minutes(cast(330 - tz_offset_min(tz) as bigint));

create or replace macro dpd_bucket(d) as
    case when d = 0 then '0 (current)' when d <= 30 then '01-30' when d <= 60 then '31-60'
         when d <= 90 then '61-90' else '90+' end;

-- ---------- reference / master data ----------
create or replace table stg.accounts as
select upper(trim(account_id))            as account_id,
       nullif(upper(trim(borrower_id)),'') as borrower_id,
       upper(trim(loan_type))             as loan_type,
       try_cast(principal_amount as double)   as principal_amount,
       try_cast(outstanding_amount as double) as outstanding_amount,
       try_cast(dpd as integer)           as dpd,
       dpd_bucket(try_cast(dpd as integer)) as dpd_bucket,
       upper(trim(risk_segment))          as risk_segment,
       upper(trim(status))                as snapshot_status,
       try_cast(opened_at as timestamp)   as opened_at_local,
       timezone                           as account_timezone,
       schema_version,
       _src_row
from raw.accounts;

create or replace table stg.borrowers as
select upper(trim(borrower_id)) as borrower_id, name, phone, email,
       trim(city) as city, trim(state) as state,
       try_cast(created_at as timestamp) as created_at,
       try_cast(updated_at as timestamp) as updated_at,
       _src_row
from raw.borrowers;

create or replace table stg.agents as
select upper(trim(agent_id)) as agent_id, upper(trim(employee_code)) as employee_code,
       agent_name, upper(trim(vendor_id)) as vendor_id, upper(trim(team)) as team,
       upper(trim(status)) as status,
       try_cast(joined_at as timestamp)  as joined_at,
       try_cast(updated_at as timestamp) as updated_at,
       _src_row
from raw.agents;

create or replace table stg.vendor_telephony as
select upper(trim(vendor_id)) as vendor_id, vendor_name, vendor_account_id,
       timezone as vendor_timezone, upper(status) as status, schema_version, _src_row
from raw.vendor_telephony;

create or replace table stg.campaigns as
select upper(trim(campaign_id)) as campaign_id, campaign_name, upper(channel) as channel,
       strategy_version, target_definition,
       try_cast(start_at as timestamp) as start_at, try_cast(end_at as timestamp) as end_at,
       case when strategy_version in ('v2','v3') then 'NEW' else 'OLD' end as strategy_generation,
       _src_row
from raw.campaigns;

-- ---------- event data ----------
create or replace table stg.calls as
select upper(trim(call_id)) as call_id, upper(trim(account_id)) as account_id,
       upper(trim(borrower_id)) as borrower_id,
       try_cast(event_at as timestamp)                         as event_at_local,
       timezone                                                as src_timezone,
       to_ist(try_cast(event_at as timestamp), timezone)       as event_at_ist,
       nullif(upper(trim(agent_id)),'')                        as agent_id,
       upper(trim(campaign_id)) as campaign_id, upper(direction) as direction,
       upper(trim(vendor_id))   as vendor_id, upper(call_status) as call_status,
       try_cast(duration_sec as integer) as duration_sec,
       _src_row
from raw.calls;

create or replace table stg.call_attempts as
select upper(trim(attempt_id)) as attempt_id, upper(trim(account_id)) as account_id,
       upper(trim(borrower_id)) as borrower_id,
       try_cast(event_at as timestamp) as event_at_ist,
       upper(trim(call_id)) as call_id, upper(trim(agent_id)) as agent_id,
       try_cast(attempt_no as integer) as attempt_no,
       coalesce(nullif(upper(trim(vendor_id)),''),'UNKNOWN') as vendor_id,
       upper(attempt_status) as attempt_status, _src_row
from raw.call_attempts;

-- Disposition codes differ across schema versions (legacy / v1 / v2).
-- 'PTP' (short form) and 'PROMISE_TO_PAY' are the same outcome -> harmonised.
create or replace table stg.call_dispositions as
select upper(trim(disposition_id)) as disposition_id, upper(trim(account_id)) as account_id,
       upper(trim(borrower_id)) as borrower_id,
       try_cast(event_at as timestamp) as event_at_ist,
       upper(trim(call_id)) as call_id, upper(trim(agent_id)) as agent_id,
       disposition_code as disposition_code_raw,
       case disposition_code when 'PTP' then 'PROMISE_TO_PAY' else disposition_code end as disposition_code,
       disposition_version, _src_row
from raw.call_dispositions;

create or replace table stg.whatsapp_events as
select upper(trim(whatsapp_event_id)) as event_id, upper(trim(account_id)) as account_id,
       upper(trim(borrower_id)) as borrower_id, try_cast(event_at as timestamp) as event_at_ist,
       message_id, upper(event_type) as event_type, template_code, provider_id, _src_row
from raw.whatsapp_events;

create or replace table stg.sms_events as
select upper(trim(sms_event_id)) as event_id, upper(trim(account_id)) as account_id,
       upper(trim(borrower_id)) as borrower_id, try_cast(event_at as timestamp) as event_at_ist,
       message_id, upper(event_type) as event_type, template_code, provider_id, _src_row
from raw.sms_events;

create or replace table stg.field_visits as
select upper(trim(visit_id)) as visit_id, upper(trim(account_id)) as account_id,
       upper(trim(borrower_id)) as borrower_id, try_cast(event_at as timestamp) as event_at_ist,
       upper(trim(agent_id)) as agent_id, visit_type, outcome,
       try_cast(latitude as double) as latitude, try_cast(longitude as double) as longitude,
       try_cast(scheduled_at as timestamp) as scheduled_at, _src_row
from raw.field_visits;

create or replace table stg.promises_to_pay as
select upper(trim(ptp_id)) as ptp_id, upper(trim(account_id)) as account_id,
       upper(trim(borrower_id)) as borrower_id, try_cast(event_at as timestamp) as event_at_ist,
       upper(trim(agent_id)) as agent_id, try_cast(promised_amount as double) as promised_amount,
       try_cast(promised_date as timestamp) as promised_date, upper(status) as reported_status,
       upper(source) as source, _src_row
from raw.promises_to_pay;

create or replace table stg.payments as
select upper(trim(payment_id)) as payment_id, upper(trim(account_id)) as account_id,
       upper(trim(borrower_id)) as borrower_id,
       try_cast(event_at as timestamp) as event_at_raw,   -- clock unknown (no tz column)
       try_cast(event_at as timestamp) as event_at_ist,   -- policy: assume IST
       nullif(trim(payment_reference),'') as payment_reference,
       try_cast(amount as double) as amount, upper(payment_status) as payment_status,
       upper(payment_method) as payment_method, upper(trim(provider_id)) as provider_id, _src_row
from raw.payments;

create or replace table stg.agent_sessions as
select upper(trim(session_id)) as session_id, upper(trim(agent_id)) as agent_id,
       to_ist(try_cast(login_at as timestamp), timezone)  as login_at_ist,
       to_ist(try_cast(logout_at as timestamp), timezone) as logout_at_ist,
       upper(channel) as channel, device_id, timezone as src_timezone, _src_row
from raw.agent_sessions;

create or replace table stg.daily_targeting as
select upper(trim(target_id)) as target_id, upper(trim(account_id)) as account_id,
       upper(trim(campaign_id)) as campaign_id, try_cast(target_date as date) as target_date,
       try_cast(priority as integer) as priority, upper(recommended_channel) as recommended_channel,
       upper(status) as status, _src_row
from raw.daily_targeting;

create or replace table stg.complaints as
select upper(trim(complaint_id)) as complaint_id, upper(trim(account_id)) as account_id,
       try_cast(event_at as timestamp) as event_at_ist, complaint_type, severity,
       upper(status) as status, upper(source) as source,
       try_cast(resolution_at as timestamp) as resolution_at, _src_row
from raw.complaints;

create or replace table stg.account_status_history as
select upper(trim(history_id)) as history_id, upper(trim(account_id)) as account_id,
       try_cast(event_at as timestamp) as event_at_ist, upper(status) as status,
       changed_by, upper(source) as source,
       try_cast(recorded_at as timestamp) as recorded_at, _src_row
from raw.account_status_history;

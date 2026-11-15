-- =====================================================================
-- 00_raw.sql  —  RAW layer
-- Land every source file exactly as delivered (all columns VARCHAR).
-- Nothing is typed, trimmed or filtered here, so raw row counts are
-- reproducible and every later rejection can be traced back.
-- {{RAW_DIR}} is substituted by run_pipeline.py
-- =====================================================================
create schema if not exists raw;

create or replace table raw.borrowers              as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/borrowers.csv',              all_varchar=true, header=true);
create or replace table raw.accounts               as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/accounts.csv',               all_varchar=true, header=true);
create or replace table raw.agents                 as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/agents.csv',                 all_varchar=true, header=true);
create or replace table raw.agent_sessions         as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/agent_sessions.csv',         all_varchar=true, header=true);
create or replace table raw.campaigns              as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/campaigns.csv',              all_varchar=true, header=true);
create or replace table raw.daily_targeting        as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/daily_targeting.csv',        all_varchar=true, header=true);
create or replace table raw.calls                  as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/calls.csv',                  all_varchar=true, header=true);
create or replace table raw.call_attempts          as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/call_attempts.csv',          all_varchar=true, header=true);
create or replace table raw.call_dispositions      as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/call_dispositions.csv',      all_varchar=true, header=true);
create or replace table raw.whatsapp_events        as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/whatsapp_events.csv',        all_varchar=true, header=true);
create or replace table raw.sms_events             as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/sms_events.csv',             all_varchar=true, header=true);
create or replace table raw.field_visits           as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/field_visits.csv',           all_varchar=true, header=true);
create or replace table raw.promises_to_pay        as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/promises_to_pay.csv',        all_varchar=true, header=true);
create or replace table raw.payments               as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/payments.csv',               all_varchar=true, header=true);
create or replace table raw.vendor_telephony       as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/vendor_telephony.csv',       all_varchar=true, header=true);
create or replace table raw.complaints             as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/complaints.csv',             all_varchar=true, header=true);
create or replace table raw.account_status_history as select *, row_number() over () as _src_row from read_csv('{{RAW_DIR}}/account_status_history.csv', all_varchar=true, header=true);

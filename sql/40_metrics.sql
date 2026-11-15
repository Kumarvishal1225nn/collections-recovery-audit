-- =====================================================================
-- 40_metrics.sql  —  METRICS layer (one governed definition per KPI)
-- Definitions & rationale: docs/metric_definitions.md
-- =====================================================================
create schema if not exists mart;

create or replace table mart.kpi_monthly as
with book as (select count(*) n_accounts, sum(outstanding_amount) book_outstanding from cln.dim_account),
reported as (   -- reconstruction of the business's current number (see 50_forensics.sql F0)
    select date_trunc('month', event_at_raw)::date month_start,
           sum(amount) filter (where payment_status='SUCCESS') as reported_collections
    from stg.payments group by 1),
pay as (select month_start, sum(net_amount) net_collections, count(*) n_payments,
               count(distinct account_id) paying_accounts
        from gld.fct_payment group by 1),
calls as (select date_trunc('month', event_at_ist)::date month_start,
                 count(*) filter (where direction='OUTBOUND') outbound_calls,
                 count(*) filter (where direction='OUTBOUND' and is_contact) answered_calls,
                 count(*) filter (where direction='OUTBOUND' and call_status in ('ANSWERED','VOICEMAIL')) answered_or_vm
          from cln.calls group by 1),
dispo as (select date_trunc('month', event_at_ist)::date month_start, count(*) dispositions,
                 count(*) filter (where is_rpc) rpc, count(*) filter (where is_ptp) ptp_dispo
          from cln.call_dispositions group by 1),
ptp as (select month_start, count(*) ptps,
               count(*) filter (where reported_status='KEPT') kept_reported,
               count(*) filter (where reported_status in ('KEPT','BROKEN')) resolved_reported,
               count(*) filter (where is_due) due, count(*) filter (where is_due and verified_kept) kept_verified
        from gld.fct_ptp group by 1),
hrs as (select date_trunc('month', login_at_ist)::date month_start, sum(hours_clean) agent_hours,
               count(distinct agent_id) active_agents
        from cln.agent_sessions group by 1),
cmp as (select date_trunc('month', event_at_ist)::date month_start, count(*) complaints from cln.complaints group by 1),
active_den as (  -- "survivor" denominator used ONLY to demonstrate denominator manipulation
    select month_start, sum(outstanding_amount) active_outstanding, count(*) active_accounts
    from gld.account_month where status_at_month_start not in ('WRITEOFF','CLOSED','PAID')
    group by 1)
select c.month_start, c.days_in_month, c.is_complete,
       r.reported_collections,
       p.net_collections, p.n_payments, p.paying_accounts,
       p.net_collections / c.days_in_month                        as net_collections_per_day,
       100 * p.net_collections / b.book_outstanding               as recovery_rate_pct,
       p.net_collections / b.n_accounts                           as recovery_per_account,
       100.0 * p.paying_accounts / b.n_accounts                   as paying_account_rate_pct,
       100.0 * k.answered_calls / k.outbound_calls                as contact_rate_pct,
       100.0 * k.answered_or_vm / k.outbound_calls                as contact_rate_incl_voicemail_pct,
       100.0 * d.rpc / d.dispositions                             as rpc_rate_pct,
       100.0 * d.ptp_dispo / nullif(d.rpc,0)                      as ptp_rate_pct,
       100.0 * t.kept_reported / nullif(t.resolved_reported,0)    as ptp_kept_reported_pct,
       100.0 * t.kept_verified / nullif(t.due,0)                  as ptp_kept_verified_pct,
       h.agent_hours, h.active_agents,
       p.net_collections / nullif(h.agent_hours,0)                as recovery_per_agent_hour,
       1000.0 * m.complaints / b.n_accounts                       as complaints_per_1000_accounts,
       ad.active_accounts,
       100 * p.net_collections / ad.active_outstanding            as recovery_rate_survivor_denominator_pct,
       b.book_outstanding
from gld.calendar_month c cross join book b
left join reported r using (month_start)
left join pay p using (month_start)
left join calls k using (month_start)
left join dispo d using (month_start)
left join ptp t using (month_start)
left join hrs h using (month_start)
left join cmp m using (month_start)
left join active_den ad using (month_start)
order by 1;

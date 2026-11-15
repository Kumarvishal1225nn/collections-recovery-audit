# SQL guide: what each step does and why

The pipeline is executed in this order by `run_pipeline.py` (DuckDB):

`00_raw → 10_staging → 05_validation → 20_clean → 30_golden → 40_metrics → 50_forensics → 60_analysis → 70_dq_checks`

## Join cardinality policy (applies everywhere)
| Relationship | Cardinality | Rule |
|---|---|---|
| event tables → `dim_account` | many-to-one | always joined on the event's own `account_id` |
| `calls` → `call_attempts` / `call_dispositions` via `call_id` | broken (account mismatch >99.9%) | **never joined**; each table is aggregated to account × month separately |
| payment ↔ PTP window | many-to-many | resolved with `row_number()` so a payment counts toward one PTP only |
| payment ↔ touches (attribution) | many-to-many | resolved with `arg_max` (last touch) inside the window; one row per payment |
| calls → agent SCD | many-to-one at event time | as-of join `event_at ∈ [valid_from, valid_to)`; asserted no loss |
| `account_month` | account × month | built from a cross join grid + left joins of **pre-aggregated** CTEs (never joined row-to-row), so it cannot fan out; asserted rows = 30,000 × 8 |

## Key queries

| File / object | What it does | Why it is required | Tables used | Business question |
|---|---|---|---|---|
| `00_raw` raw.* | Lands each CSV as VARCHAR with `_src_row` | Traceability: every rejection points back to a source row | 17 CSVs | — |
| `10_staging` stg.* | Types columns, normalises IDs and codes, converts all clocks to IST (`to_ist` macro) | One reporting clock; a third of calls were stored in UTC and a third in Dubai time | raw.* | "When did it happen?" |
| `05_validation` val.inventory / table_profile / month_completeness / fk_health / null_profile / schema_versions | Inventory, PK integrity, coverage, FK health, nulls and schema versions | The brief claims ~12 months and gives no data dictionary | stg.* | "Which data can we trust, for which period?" |
| `20_clean` cln.payments | Dedup on `payment_id`; `net_amount` only for SUCCESS; flags shared or missing references | Removes ₹2.59 Cr of double-counted cash; avoids the false key | stg.payments | "How much cash really came in?" |
| `20_clean` cln.calls | Dedup on `call_id` (agent-bearing, then earliest); contact and out-of-hours flags | 1,350 duplicate rows; compliance view | stg.calls | "How many real calls, and when?" |
| `20_clean` cln.call_dispositions | Harmonises `PTP` → `PROMISE_TO_PAY`; RPC / PTP flags | Legacy codes would halve PTP counts | stg.call_dispositions | "Did we reach the borrower?" |
| `20_clean` cln.promises_to_pay | Cash-verified kept status; allocates each payment to one PTP | Agent labels are unreliable; prevents double-claiming | stg.promises_to_pay, cln.payments | "Are promises really kept?" |
| `20_clean` cln.dim_borrower / dim_account | Survivor borrower; account dimension with geography and flags | Conflicting borrower versions | stg.borrowers, stg.accounts | "Who and where is the borrower?" |
| `20_clean` cln.dim_agent_scd | Agent master as SCD-2 | ~30 overwritten versions per agent | stg.agents | "Which agent and team, at the time of the call?" |
| `20_clean` cln.agent_sessions | Removes overlapping session hours | Prevents double-counted agent-hours | stg.agent_sessions | "How many productive hours?" |
| `30_golden` gld.fct_payment | One row per recognised payment + 7-day last-touch and naive "latest campaign" attribution | Recovery fact; compares attribution logics | cln.payments, gld.fct_touch, cln.calls | "Which touch, if any, preceded the payment?" |
| `30_golden` gld.fct_touch | One row per contact across call / WhatsApp / SMS / field | Unified channel activity | cln.calls, cln.whatsapp_events, cln.sms_events, cln.field_visits | "What did we do to each account?" |
| `30_golden` gld.account_month | Fixed-cohort panel: 30,000 accounts × months, with activity, cash and status at month start | Consistent population; denominator can't shrink | all golden + clean facts | "How did the *same* book perform month to month?" |
| `40_metrics` mart.kpi_monthly | Governed KPIs (audited and reported-style side by side) | One definition per KPI | gld.*, cln.* | "What are the official numbers?" |
| `50_forensics` fx.f0_reported_mom | Reconstructs candidate "11%" definitions | Find what the business reported | stg.payments | "Where did 11% come from?" |
| `50_forensics` fx.a_ … fx.j_ | Tests A–G plus PTP / campaign / key integrity | Part 2 of the brief | various | "What is wrong in the data?" |
| `60_analysis` ana.channel_conversion / channel_baseline | P(pay within 7d after touch) vs after a random day | Without a baseline, conversion is coincidence | gld.fct_touch, gld.fct_payment | "Does any channel work?" |
| `60_analysis` ana.campaign_targeting / campaign_summary | Payment within 7d after targeting, by campaign attributes and status | Campaign drivers; contacted vs skipped targets | cln.daily_targeting, cln.dim_campaign, gld.fct_payment | "Does any campaign or strategy work?" |
| `60_analysis` ana.funnel_monthly | Account counts at each funnel stage | Call-level funnel is impossible (broken keys) | gld.account_month | "Where do accounts drop out?" |
| `60_analysis` ana.agent_* | Agent outcomes, split-half, as-of tenure | Agent driver analysis | cln.calls, cln.call_dispositions, gld.fct_ptp, cln.dim_agent_scd | "Do agents differ?" |
| `60_analysis` mart.kpi_daily | Daily recovery, reported vs audited | Trend tests and visualisation | gld.fct_payment, stg.payments | "Is there a trend?" |
| `70_dq_checks` dq.results | 18 assertions (PK, reconciliation, fan-out, double claim, duplicate evidence, WARN thresholds) | Blocks publishing if money or keys break | all layers | "Can we publish today?" |

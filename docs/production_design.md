# Production analytics design

Diagram: `docs/architecture.svg` (also `docs/architecture.png`).

## 1. Layers

| Layer | Purpose | Implementation here | Production target |
|---|---|---|---|
| **Raw** | Immutable landing of every source extract, all columns string, + `_ingested_at`, `_source_file`, `_src_row` | `sql/00_raw.sql` | S3 `raw/<source>/dt=YYYY-MM-DD/` (append-only, never overwritten) |
| **Staging** | Types, trimmed IDs, harmonised codes, **IST timestamps** with source timezone retained | `sql/10_staging.sql` | dbt staging models / Glue jobs → Iceberg tables |
| **Clean** | Deduplication, entity resolution, SCD-2 for agents/borrowers, flags; every rule writes to `rejection_log` | `sql/20_clean.sql` | dbt incremental models with `unique_key` merge |
| **Golden** | Facts (`fct_payment`, `fct_touch`, `fct_ptp`) + `account_month` fixed-cohort panel | `sql/30_golden.sql` | dbt marts, partitioned by month |
| **Feature** | Model inputs per account-day (recency of touch, DPD trajectory, payment history, response to channel) | — | Feature tables for uplift / targeting model |
| **Metrics** | One governed definition per KPI | `sql/40_metrics.sql` | dbt semantic layer / metrics store |
| **Reporting** | Leadership reporting / dashboard | marts in `outputs/tableau/` (dashboard rebuilt in the visualisation phase) | BI tool reading the metrics layer only |

## 2. Data contracts (per source)

Each source publishes a contract checked at ingestion; a breach quarantines the file instead of loading it.

| Source | Primary key | Required fields | Rules |
|---|---|---|---|
| payments | `payment_id` | account_id, event_at, amount, payment_status, **timezone** (new, mandatory) | amount > 0; status ∈ {SUCCESS, FAILED, PENDING, REVERSED}; **reversals as new rows** referencing the original `payment_id`, never in-place status overwrites |
| calls | `call_id` | account_id, event_at, timezone, vendor_id, call_status, direction, **dialer_mode** (new) | timezone ∈ IANA list; one row per call; agent_id required when dialer_mode = HUMAN |
| call_attempts / dispositions | `attempt_id` / `disposition_id` | call_id **and** account_id must match `calls` | referential check on (call_id, account_id) pair |
| dispositions | — | disposition_code from the **current code list**; `code_version` | old codes mapped via a versioned mapping table, not ad-hoc |
| agents | `agent_id` + `valid_from` | employee_code unique per person | SCD-2 by design; HR system is the master for joined_at |
| accounts | `account_id` | borrower_id, dpd, outstanding, **as_of_date** | daily snapshot partition (so DPD history exists) |
| campaigns / targeting | `campaign_id`, `target_id` | target rule as machine-readable predicate | targeted accounts must satisfy the predicate (checked) |
| all | — | `_ingested_at` | late events accepted up to 35 days; beyond that → quarantine + alert |

## 3. Primary keys & grains

| Table | Grain | Key |
|---|---|---|
| gld.fct_payment | one settled payment | payment_id |
| gld.fct_touch | one contact attempt (any channel) | channel + touch_id |
| gld.fct_ptp | one promise | ptp_id |
| gld.account_month | account × month | (account_id, month_start) |
| cln.dim_agent_scd | agent version | (agent_id, valid_from) |
| mart.kpi_monthly | month | month_start |

## 4. Incremental processing, late data and backfills

* **Partitioning:** event tables by `event_date_ist`; panel by `month_start`.
* **Incremental rule:** each run re-processes all partitions touched by files ingested since the last successful run (`_ingested_at > last_watermark`), not just "yesterday". This is what makes late-arriving events safe.
* **Late-arrival window:** 35 days. Metrics for a month are **provisional** until month-end + 35 days, then **frozen** (stored with a `metric_version`). The dashboard labels provisional values.
* **Restatement:** if a frozen month changes by > 0.5% on reprocessing, the new value is published as a restatement with a reason code — never silently overwritten.
* **Backfills:** idempotent by partition (`delete partition → insert`), triggered with an explicit date range; the raw layer is never modified, so any historical layer can be rebuilt from raw.
* **Dedup in incremental mode:** `merge` on primary key; for payments, a duplicate `payment_id` with different content raises a contract violation instead of last-write-wins.

## 5. Data-quality checks (`sql/70_dq_checks.sql` is the seed)

| Check | Severity | Action |
|---|---|---|
| PK uniqueness on every golden table | BLOCK | pipeline stops, previous metrics stay published |
| Golden ₹ = clean SUCCESS ₹ (reconciliation) | BLOCK | stop |
| Panel ₹ = fact ₹ | BLOCK | stop |
| Every payment maps to an account | BLOCK | stop |
| Unparseable timestamps / unknown timezone | BLOCK | quarantine file |
| Duplicate-row rate in raw > 1% | WARN | alert data owner |
| Calls outside 08:00–19:00 IST > 0% | WARN → compliance | alert compliance daily |
| PTP KEPT before due date > 0 | WARN | alert ops |
| Accounts without borrower > 2% | WARN | alert |
| Daily ₹ collected outside ±4σ of trailing 28-day mean | WARN | anomaly alert |

## 6. Monitoring & anomaly detection

* **Freshness:** each source must land by 06:00 IST; late → alert, dashboard shows "data as of".
* **Volume:** row counts per source vs trailing 28-day median (±30%).
* **Distribution drift:** share of each disposition code, call status, timezone and payment status per day; a code appearing/disappearing triggers a "mapping change" alert (this is how a vendor code change is caught on day 1).
* **Metric anomaly:** daily recovery modelled as weekday-adjusted mean with 28-day rolling σ; alert outside ±3σ. MoM comparisons are only shown per day and with CI.
* **Experiment integrity:** holdout share and balance (DPD, product) checked daily; sample-ratio mismatch alert.
* **Lineage:** every dashboard number links to its metric definition → SQL model → source tables (dbt docs / OpenLineage).

## 7. Orchestration
Daily DAG (Airflow / Step Functions): `ingest → contract checks → staging → clean → golden → features → metrics → DQ gate → publish dashboard`. The DQ gate is the only path to publish; on failure the last good snapshot stays live.

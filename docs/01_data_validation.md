# Phase 2: Source data validation

Source: `collections_30k_dataset.zip` as delivered by the placement cell. The files were re-extracted, checksummed against the working copy (identical), and never modified. All checks are reproducible in `sql/05_validation.sql`, with outputs in `outputs/validation/*.csv`.

## 1. Are all expected tables present?
**Yes.** All 17 tables named in the assignment were delivered (`val.inventory`). The zip also contains a `README.md` that discloses deliberate defects (duplicates, mixed timezones, legacy codes, overwritten history) and a `data_dictionary.csv` that lists column dtypes only, with no definitions.

## 2. What period does the data cover?

| Check | Result | Evidence |
|---|---|---|
| Earliest event | **1 Jan 2026** | payments 00:14 IST, and every other event table on 1 Jan |
| Latest event | **8 Aug 2026** | payments 23:50; every event table ends on 8 Aug |
| Span | **220 days** | `val.table_profile.span_days` |
| Complete calendar months | **7 (Jan–Jul 2026)** | every day of each month has payments, calls, WhatsApp and field events (`val.month_completeness`) |
| Partial months | August (8 of 31 days) | excluded from all month-on-month comparisons |
| Missing days inside the window | **None** | 0 days without payments between 1 Jan and 8 Aug |
| Data before 2026 | Only master data | accounts opened 2024-01 → 2025-11; borrower and agent records from 2024–25 |
| Stray events | 4 calls (local clock) fall on 29–31 Dec or 9–12 Aug | outside the common window; kept but flagged |

**Conclusion (FACT):** the brief says "approximately 12 months". The data supports **7 complete months plus 8 days**. Nothing from Aug 9 onwards, and nothing before 2026, exists in any event table. Every finding in this project refers to Jan–Jul 2026 and is never described as a 12-month result.

## 3. Grain and primary keys

| Table | Rows | Distinct PK | Duplicate-PK rows | Grain after cleaning |
|---|---:|---:|---:|---|
| payments | 25,500 | 25,000 | **500** | one row per payment_id |
| calls | 91,350 | 90,000 | **1,350** | one row per call_id |
| whatsapp_events | 60,600 | 60,000 | **600** | one row per event_id |
| borrowers | 30,600 | 11,015 | **19,585** (versions) | one survivor per borrower_id |
| agents | 30,000 | 1,000 | **29,000** (versions) | SCD-2: agent_id + valid_from |
| all other tables | — | = rows | 0 | as delivered |

## 4. Foreign keys and relationships

| Relationship | Rows | Broken | Consequence |
|---|---:|---:|---|
| payments / calls / PTPs → accounts | all | **0** | `account_id` is a reliable join key |
| calls → agents, campaigns, vendors | all | 0 | lookup joins are safe |
| accounts → borrowers | 30,000 | 2,913 (9.7%) | geography unknown for these accounts |
| call_attempts (call_id, account_id) → calls | 120,000 | **119,992** | the `call_id` exists, but on a *different* account: attempt → call → disposition funnels **cannot** be joined at call level |
| call_dispositions (call_id, account_id) → calls | 35,000 | **35,000** | same problem |
| payments.borrower_id = accounts.borrower_id | 25,500 | **25,499** | event-level borrower_id is unusable; borrower is always taken from the account |

**Relationship model used:** account is the hub. Every event table joins to `accounts` on its own `account_id` (many-to-one). Call-level joins between `calls`, `call_attempts` and `call_dispositions` are **not** used; each table is aggregated to account-month separately. This avoids the many-to-many fan-out that a `call_id` join would create on mismatched accounts.

## 5. Missing values

| Column | Missing | Treatment |
|---|---:|---|
| payments.payment_reference | 382 (1.5%) | kept; not a key |
| accounts.borrower_id | 455 (1.5%) | geography = UNKNOWN |
| calls.agent_id | 1,827 (2.0%) | kept for contact metrics; excluded from agent metrics |
| call_attempts.vendor_id | 2,400 (2.0%) | set to UNKNOWN |
| field_visits.scheduled_at | 250 (1.0%) | kept; not used |
| borrowers.phone / email | 614 / 895 | not used (PII) |

No missing values in amounts, statuses or event timestamps.

## 6. Timestamps, schemas, late data
- **Timezones:** calls are stored as one-third each in UTC, Asia/Dubai and IST (row-level `timezone` column). All other event tables carry no timezone and are assumed to be IST (see the sensitivity test in the DQ report).
- **Schema versions:** accounts v1/v2/v3, dispositions legacy/v1/v2, vendors v1/v2/v3, campaigns legacy/v1/v2/v3. All versions appear in every month. Old and new codes co-exist rather than switching on a date, so they add noise, not a step change.
- **Late-arriving data:** only `account_status_history` has an ingestion time (`recorded_at`). It sits within ±24 h of `event_at` in both directions, which is clock skew, not lateness. Payments have no ingestion timestamp, so lateness **cannot be measured** for money (stated as a limitation).
- **Overwritten history:** agents (≈30 versions each) and borrowers (up to 11 versions) contain overwritten records with contradictory attributes. Account `status` in the snapshot disagrees with the latest status history for 86% of accounts.

## 7. Disappearing accounts and portfolio mix
- All 30,000 accounts are present for the whole window. No account is added or removed, because the book was originated before 2026.
- 29 accounts were never contacted; 16,716 never paid in the window.
- DPD, product and risk mixes are fixed: they come from a single account snapshot with no history. **Limitation:** DPD drift over the period cannot be observed.

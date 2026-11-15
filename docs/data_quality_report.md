# Data Quality Report

Audience: technical and business. Scope: all 17 source tables, 1 Jan – 8 Aug 2026 (7 complete months + 8 days; the brief's "≈12 months" is not in the data — see `docs/01_data_validation.md`). Every rule below is implemented in `sql/20_clean.sql`, logged to `outputs/rejection_log.csv`, and asserted in `sql/70_dq_checks.sql`.

## 1. Raw → Rejected/Corrected → Golden

| Entity | Raw rows | Clean rows | Golden rows | What changed |
|---|---:|---:|---:|---|
| payments | 25,500 | 25,000 | **17,534** | 500 payments recorded twice: one copy removed (486 identical, 14 with the reference dropped on one copy); 7,466 non-SUCCESS rows kept in clean but excluded from recovery |
| calls | 91,350 | 90,000 | 82,907 outbound | 1,350 duplicate `call_id` rows removed; 59,962 timestamps re-based to IST |
| whatsapp_events | 60,600 | 60,000 | 59,999 message touches | 600 exact duplicates removed |
| borrowers | 30,600 | 11,015 | 11,015 | 600 exact duplicate rows and 18,985 conflicting versions collapsed to 1 survivor per borrower |
| agents | 30,000 | 30,000 SCD rows | 1,000 agents | 29,000 overwritten versions modelled as SCD-2 |
| daily_targeting | 45,000 | 44,840 | 44,840 | 160 same-day duplicates removed |
| promises_to_pay | 18,000 | 18,000 | 18,000 | status re-derived from cash; 394 premature KEPT flagged |
| accounts, attempts, dispositions, SMS, field, complaints | unchanged counts | | | flags only (see §2) |

**Business impact of cleaning on recovery (Jan–Aug 8):**

| Step | ₹ Cr |
|---|---:|
| Sum of all payment rows (any status, duplicates included) | 191.73 |
| − duplicate rows (all statuses) | −3.84 |
| − non-cash statuses (FAILED / PENDING / REVERSED) | −56.33 |
| **= Golden recovery** | **131.56** |
| *Memo: reported-style SUCCESS sum with duplicates* | *134.15 (of which ₹2.59 Cr duplicates)* |

Duplicates inflate cash by ~1.9%, but **evenly across months** (₹28–43 lakh each month), so they inflate the level, not the trend.

## 2. Issue register

| # | Issue | Detection method | Treatment | Business impact |
|---|---|---|---|---|
| 1 | **Duplicate payment events** — 500 `payment_id`s appear twice. Classified by evidence: **486** identical in every column; **14** identical except one copy has lost its `payment_reference`; **0** ambiguous. In every group both rows agree on account, amount, timestamp to the second, status, method and provider, and the second copy sits in the last 500 rows of the file (a re-appended block) | Per-group comparison of every column (`cln.payment_duplicate_groups`, `fx.a_duplicate_payment_classes`); independent pandas test in `tests/test_golden.py` | One row kept per payment; the survivor is the copy that still carries the reference. Any group that disagreed on amount, time, status or reference would be **quarantined, not deleted** (blocking check) | ₹2.59 Cr of SUCCESS cash double-counted (₹2.50 Cr identical + ₹0.09 Cr reference-dropped) = 1.9% of reported cash. The other 154 duplicate rows are FAILED / PENDING / REVERSED and carry no cash |
| 2 | **Non-unique `payment_reference`** — 7,218 payments share a reference with a different account, amount and date | Compare account/amount/time inside reference groups | **Not** treated as duplicates; flagged | Deduping on reference would have deleted ₹14.7 Cr of real SUCCESS cash — the "cleanest-looking" key is the wrong one |
| 3 | **Non-cash statuses** — FAILED 3,744, PENDING 2,592, REVERSED 1,284 | Status distribution; REVERSED rows have no matching SUCCESS (statuses overwritten in place) | Excluded from recovery | ₹56.3 Cr of attempted-but-not-received money |
| 4 | **Mixed timezones in calls** — 33% UTC, 33% Asia/Dubai, 33% IST | Row-level `timezone` column | Converted to IST with fixed offsets | 100% of UTC/Dubai calls had the wrong hour, 8,791 the wrong day, 305 the wrong month |
| 5 | **Call timezone ≠ vendor timezone** on ~50% of calls | Join to `vendor_telephony` | Row-level timezone trusted over vendor master | Vendor master cannot be used to infer clocks |
| 6 | **Payments carry no timezone** | Schema inspection | Assumed IST; sensitivity run with UTC & Dubai | Any complete month moves < 0.7%; conclusions unchanged |
| 7 | **Duplicate calls with conflicting timestamps** — 11 call_ids whose copies differ by 1–5 whole days | Distinct `event_at` per `call_id` | Earliest kept, flagged | Negligible volume; shows re-ingestion overwrote dates |
| 8 | **Calls missing agent** — 1,759 (2%) | Null check | Kept for contact metrics, excluded from agent metrics | Possible IVR/agentic calls (no dialer-mode field exists) |
| 9 | **Legacy disposition codes** — `PTP` (3,904) and `PROMISE_TO_PAY` (3,926) co-exist across schema versions legacy/v1/v2 | Code × version crosstab | `PTP` → `PROMISE_TO_PAY` | Counting only one spelling halves PTP volume. Version mix is constant by month, so no artificial trend |
| 10 | **Agent identity chaos** — each `agent_id` has 14–48 master versions, ~9.5 distinct names, ~30 `joined_at` values; each `employee_code` maps to ~27 agent_ids | Distinct counts per key | `agent_id` kept as canonical key (it is what events use); master modelled as SCD-2 (as-of join); `employee_code` not used for merging | Team and tenure attributes are unreliable; agent rankings cannot be trusted |
| 11 | **Borrower versions conflict** — up to 11 versions per borrower, with different names, cities and states; 15,354 versions have `updated_at < created_at` | Version counts, date-order check | Survivor = latest valid `updated_at` | 8,159 borrowers (74%) have >1 city → geography is low-confidence |
| 12 | **Accounts → borrowers broken** — 455 null, 2,458 orphan `borrower_id` | Anti-join | Geography = UNKNOWN | 9.7% of accounts cannot be geo-located |
| 13 | **Event `borrower_id` ≠ account's borrower** — 25,499 of 25,500 payments, ~100% of calls | Join to accounts | `account_id` is the key; event `borrower_id` ignored | Any borrower-level roll-up from event tables is wrong |
| 14 | **`call_id` links broken** — attempts and dispositions point to a call on a *different* account in >99.9% of rows | Join on `call_id`, compare `account_id` | Each table's own `account_id` used; `call_id` join not trusted | Call-level funnels (attempt → connect → disposition) cannot be reconstructed |
| 15 | **Risk segment inconsistent with DPD** — 7,521 accounts (e.g. NPA at 0 DPD) | Rule check | DPD treated as truth | Risk-based targeting rules target the wrong accounts |
| 16 | **DPD/risk carry no recovery signal** | χ² of paying rate by bucket (p > 0.10) | Reported, not corrected | HYPOTHESIS: fields are stale snapshots, not refreshed |
| 17 | **Account snapshot status ≠ latest history status** for ~85% of accounts; terminal accounts (PAID/CLOSED/WRITEOFF) keep paying | Compare snapshot vs `arg_max(status)` | Fixed-cohort panel ignores status for the denominator | Status-based denominators inflate recovery rate by +53% Jan→Jul |
| 18 | **Status history clock skew** — 30,191 rows recorded *before* the event (up to 24 h) | `recorded_at < event_at` | `event_at` used for ordering | Late-arriving logic based on `recorded_at` would re-order history |
| 19 | **PTP labels not backed by cash** — KEPT: 4.2% verified; BROKEN: 3.4%; 394 KEPT before due date | Match payments within promise window | Status re-derived from payments; each payment allocated to one PTP only (v2) | Reported PTP-kept (~50%) overstates reality ~12× |
| 20 | **Campaign definitions don't match populations** — only 46% of "DPD≥60" targets are ≥60 DPD; 28% of "NPA" targets are 90+; campaign names don't match channels | Rule check on targeted accounts | Reported | Campaign-level reporting is meaningless |
| 21 | **Calls outside campaign window** — 81% | `event_at` vs `start_at/end_at` | Reported | Campaign attribution by `campaign_id` is unreliable |
| 22 | **Overlapping agent sessions** — 222 sessions | Self-join on time overlap | Overlap hours removed | Agent-hours slightly overstated before fix |
| 23 | **Calls outside 08:00–19:00 IST** — 54% | Hour of IST timestamp | Flagged | Regulatory exposure (RBI fair-practices calling hours) |
| 24 | **Same payment claims several PTPs** — 14 payments fall in two promise windows | Payment × PTP window join, count per payment | Allocated to earliest PTP (v2) | Prevents double-counting cash in PTP-kept; small |
| 25 | **Message IDs shared across accounts** — 16,818 WhatsApp and 12,354 SMS `message_id`s attached to >1 account | Distinct accounts per message_id | Touch key = message_id × account_id | A message-level funnel would mis-assign engagement |
| 26 | **Dispositions without a conversation** — 93% of accounts with an RPC disposition had no answered call that month | Account-month comparison | Reported; call-level funnel not built | RPC / PTP-per-call rates are not trustworthy; account-level counts used |
| 27 | **Coverage gap** — 7.3 months, not 12; no client, language, dialer-mode or cost fields | Range & schema checks | Stated in every output | Cost per ₹ recovered and client/language analysis not possible |

### Other payment-inflation patterns searched for and not found
| Pattern | Result |
|---|---|
| Same account and same amount under different payment_ids | 0 |
| Same account and same reference under different payment_ids | 0 |
| Two payments on one account within 10 minutes | 0 |
| Shared-reference groups with a matching amount or timestamp | 0 of 3,407 groups |
| FAILED followed by SUCCESS on the same account within 24 h | 8 (genuine retries; both rows correct as recorded) |

### Additional issues found in the final audit
| # | Issue | Detection method | Treatment | Business impact |
|---|---|---|---|---|
| 28 | **Balance field has no as-of date** — 1,859 paying accounts paid more than their `outstanding_amount`, ₹13.0 Cr above balance (10% of cash) | Sum of SUCCESS cash per account vs outstanding | None possible; reported. Recovery rate is still computed on the snapshot balance | The recovery-rate *level* (1.7%/month) is only as reliable as the balance; the *trend* is unaffected because the denominator is constant |
| 29 | **Account status carries no information** — cash arrives equally from ACTIVE, CLOSED, PAID and WRITEOFF accounts (25% each) | Cash by snapshot status | Status never used to filter the population | Any status-filtered report (e.g. "active accounts only") drops ~75% of paying accounts |
| 30 | **Late arrival cannot be measured for money** — payments have no ingestion timestamp; status history is recorded within ±24 h either side of the event; 11 duplicate calls are dated whole days apart | `fx.k_late_arrival` | Production design adds `_ingested_at` and a 35-day restatement window | Month totals could restate and nobody would know |
| 31 | **No telephony code change over time** (tested, not found) | χ² of call-status mix by month for each of 15 vendors: min p = 0.011, none below the 0.003 multiple-test threshold | — | Contact-rate trend is not an artefact of a mapping change |

## 3. Source-of-truth decisions

| Question | Decision | Why |
|---|---|---|
| What is "recovered"? | `payments` rows with status SUCCESS, one row per `payment_id` after the copies were shown to be the same payment | Only settled cash; `payment_id` is the only unique key; reference is not |
| Which key links events to the book? | `account_id` on each event row | `borrower_id` and `call_id` cross-links are demonstrably broken |
| Which clock? | IST for everything; row-level timezone wins over vendor master | Leadership reports in IST; calls carry a reliable row-level zone |
| Agent master? | SCD-2 keyed on `agent_id`, as-of join on event time | Overwritten history; no stable alternate key |
| Borrower master? | Latest valid version | Most recent record with consistent dates |
| PTP outcome? | Cash-verified, not label | Labels contradict payments |
| Denominator for rates? | Fixed cohort of all 30,000 accounts | No new accounts were acquired; status fields are unreliable and would create survivorship bias |
| Partial month? | August excluded from MoM | 8 days of data |

## 4. Assumptions
1. Payment timestamps are IST (no timezone supplied). Sensitivity: < 0.7% per month.
2. Duplicate rows with identical fields are ingestion retries, not two real payments.
3. A PTP is "kept" if ≥50% of the promised amount is paid by promised date + 3 days.
4. RPC = disposition in {PROMISE_TO_PAY, PTP_BROKEN, PAID, DISPUTE, REFUSED}. CALLBACK is excluded because the speaker may be a third party.
5. "New targeting strategy" = v2/v3 campaigns; cut-over 1 Apr 2026 (the brief asks us to assume a mid-year change; the data shows none).

## 5. Remaining limitations (not fixable from this data)
| Limitation | Consequence |
|---|---|
| Only 7 complete months; no data after 8 Aug 2026 | No seasonality; no year-on-year comparison |
| No cost data | Cost per ₹ recovered not measurable; investment model uses labelled external assumptions |
| No client, language, dialer-mode fields | These drivers can't be analysed |
| No ingestion timestamp on payments | Late-arriving payments can't be detected; month totals may restate |
| DPD/risk are single snapshots | DPD drift and roll-rates can't be measured |
| Agent identities can't be resolved | Agent and tenure analysis are low-confidence |
| `call_id` links broken across calls / attempts / dispositions | No call-level funnel; account-month is the finest reliable grain |
| Payment timestamps have no timezone | Assumed IST; < 0.7% monthly sensitivity |

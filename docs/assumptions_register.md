# Assumptions and decisions register

Every judgement call in the project, where it is implemented, and how sensitive the conclusions are to it.

## A. Data assumptions
| ID | Assumption | Where | Sensitivity tested? | Effect if wrong |
|---|---|---|---|---|
| A-01 | Payment timestamps are IST (no timezone column) | `10_staging.sql` | Yes: UTC/Dubai alternatives move any complete month by < 0.7% | Negligible |
| A-02 | Row-level `timezone` on calls is the true clock (beats vendor master) | `10_staging.sql` | Partly: answer rate by hour is flat under either clock | Hour-of-day analysis only |
| A-03 | Two rows with the same `payment_id`, account, amount, timestamp, status, method and provider are one payment recorded twice (486 identical; 14 differ only by a missing reference) | `20_clean.sql` R-PAY-1a/b; blocking check R-PAY-1c | Yes: 0 groups disagree on any core field; all second copies sit in the last 500 file rows | ₹2.59 Cr (1.9%), spread evenly; if they were real second payments, recovery would be 1.9% higher in every month and the trend conclusion would not change |
| A-04 | `payment_reference` is not unique to a payment | `20_clean.sql` R-PAY-2 | Yes: reference-based dedup would delete ₹14.7 Cr of distinct payments | — |
| A-05 | Only SUCCESS is cash; REVERSED rows are overwritten originals (no matching SUCCESS row exists) | `20_clean.sql` R-PAY-3 | Yes: 0 of 1,255 REVERSED rows match a SUCCESS row | — |
| A-06 | For duplicate calls, keep the copy with an agent, then the earliest timestamp | `20_clean.sql` R-CALL-1 | — | 11 calls |
| A-07 | `daily_targeting.priority` 1 = most urgent (no dictionary) | `20_clean.sql` R-TGT-1 | — | 160 rows |
| A-08 | PTP kept = ≥50% of promised ₹ paid by promised date + 3 days; each payment counts toward one PTP (earliest) | `20_clean.sql` | Labels vs cash differ ~12×, so threshold choice doesn't change the conclusion | — |
| A-09 | RPC = {PROMISE_TO_PAY, PTP_BROKEN, PAID, DISPUTE, REFUSED}; CALLBACK excluded | `20_clean.sql` | — | RPC level only; low-confidence metric anyway |
| A-10 | Borrower survivor = latest `updated_at` among versions with valid date order | `20_clean.sql` | — | Geography only; no geography effect found |
| A-11 | Agent master is SCD-2 on `agent_id`; `employee_code` is not used to merge | `20_clean.sql` | — | Tenure analysis is low-confidence by design |
| A-12 | `account_id` on each event row is the join key; `call_id` and event `borrower_id` links are not trusted | `30_golden.sql` | Validated: FK failure rates >99.9% on those links | — |
| A-13 | Denominator for rates = fixed book of 30,000 accounts | `40_metrics.sql` | Status-based alternative shown as risk (+53%) | — |
| A-15 | `outstanding_amount` is used as the recovery-rate denominator although its as-of date is unknown | `40_metrics.sql` | 1,859 payers exceed it by ₹13.0 Cr in total | Affects the level of the rate, not its trend |
| A-16 | PENDING payments are not cash | `20_clean.sql` R-PAY-3 | Yes: Mar vs Feb per-day change is +0.3% (SUCCESS), 0.0% (SUCCESS + PENDING), +0.7% (all but FAILED) | None on the conclusion |
| A-14 | August 2026 (8 days) excluded from month-on-month comparisons | everywhere | — | — |

## B. Analytical assumptions
| ID | Assumption | Where | Note |
|---|---|---|---|
| B-01 | Reported "11%" = Mar vs Feb SUCCESS sum with duplicates | notebook §4.1 | Reconstruction; formula not disclosed. Only that month pair gives ≈11% under any candidate definition |
| B-02 | "New targeting strategy" = v2/v3 campaigns; cut-over 1 Apr 2026 | notebook §7 | The brief asks us to assume a change; the data shows none |
| B-03 | Per-touch effects are only valid up to ~2× today's volume | notebook §8 | 99% of account-months have ≤2 touches per channel |
| B-04 | 3-year payback horizon for ₹10 Cr | notebook §8 | ₹3.33 Cr/yr = 1.5% of recovery |
| B-06 | Same-month touches are treated as preceding the payment | notebook §6.3 | Tested with previous-month touches: no channel significant either way |
| B-05 | Months are independent within an account | notebook §9 | Observed: month-to-month correlation ≈ 0 |

## C. External / planning assumptions (to be replaced by Finance actuals)
| ID | Assumption | Value | Source |
|---|---|---|---|
| C-01 | WhatsApp utility message, all-in | ₹0.3 (Meta ≈₹0.115–0.145 + BSP) | Meta India rate card via BSP publications, 2026 |
| C-02 | WhatsApp platform and content | ₹0.2–0.5 Cr/yr | ASSUMPTION |
| C-03 | AI voice per answered minute | ₹6–25 (headline ₹4–6) | Indian vendor pricing pages and guides, 2026 |
| C-04 | AI voice platform | ₹0.5–1 Cr/yr | ASSUMPTION |
| C-05 | Agent loaded cost | ₹3–6 lakh/yr (salary ₹1.1–4 lakh + overhead) | Salary aggregators + loading factor |
| C-06 | Field visit cost | ₹150–400 | **No public source; pure ASSUMPTION** |
| C-07 | Telephony upgrade answer-rate gain | +1 pp (observed best-vendor gap) to +5 pp | data / ASSUMPTION |
| C-08 | Experiment cost | ₹0.5–1 Cr | ASSUMPTION |
| C-09 | ROI on gross recovered ₹ | — | For a commission-based agency, scale benefits by the commission rate |

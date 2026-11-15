# Metric definitions (governed)

Every metric is computed in `sql/40_metrics.sql` (`mart.kpi_monthly`) or `sql/60_analysis.sql`. All time is IST; all money is deduplicated SUCCESS cash.

| Metric | Current / naive definition (problem) | Audited definition | Why it is the right one | Jan–Jul 2026 value |
|---|---|---|---|---|
| **Recovery (₹)** | Σ amount where status = SUCCESS, raw rows, calendar month | Σ `net_amount` from `gld.fct_payment` (SUCCESS, deduped on `payment_id`), reported **per day** and per month | Removes double-counted retries; per-day removes the 28/30/31-day calendar artefact that created the "+11%" | ≈₹6.0 lakh/day; ₹17.0–18.9 Cr/month |
| **Recovery growth** | Month total ÷ previous month total − 1 | Change in ₹/day, with bootstrap 95% CI; weekday-adjusted check; trend = OLS slope on daily series with weekday controls and Newey-West (HAC) errors | A change inside its CI is not a change; weekday composition tested (no effect, p = 0.69) | Mar vs Feb +0.3% (CI −5.9% to +7.1%); trend −0.36%/month (HAC CI −1.1% to +0.3%) |
| **Recovery rate** | Recovery ÷ outstanding of "active" accounts | Recovery ÷ outstanding of the **fixed book** (all 30,000 accounts, ₹1,049 Cr) | Status-based denominators shed non-paying (and re-labelled) accounts → survivorship bias. The book is fixed (no acquisitions in the window) | 1.6–1.8% per month, flat |
| **Recovery per account** | — | Recovery ÷ 30,000 accounts | Same fixed base | ₹5,671–6,297 per month |
| **Paying-account rate** | — | Accounts with ≥1 SUCCESS payment in month ÷ 30,000 | Breadth of recovery, not skewed by a few large payments | 7.2–8.1% |
| **Contact rate** | (ANSWERED + VOICEMAIL) ÷ calls, incl. duplicate call rows | ANSWERED ÷ outbound calls (deduped) | Voicemail is not a conversation; duplicates inflate both sides | ~20% (40% if voicemail is counted) |
| **RPC rate** *(low confidence — 93% of accounts with an RPC disposition had no answered call that month)* | Any disposition logged | Dispositions in {PROMISE_TO_PAY, PTP_BROKEN, PAID, DISPUTE, REFUSED} ÷ all dispositions | These require the debtor to engage; CALLBACK, NO_CONTACT, WRONG_NUMBER do not. `PTP` and `PROMISE_TO_PAY` harmonised first | 65.5–66.8% |
| **PTP rate** | PTPs ÷ calls | PROMISE_TO_PAY dispositions ÷ RPC | Only a right party can promise; per-call rates move with dialling volume | 32.5–35.4% |
| **PTP kept rate** | KEPT labels ÷ (KEPT + BROKEN) | **Due** PTPs with ≥50% of promised ₹ received between PTP date and promised date + 3 days ÷ due PTPs; each payment counts toward **one** PTP only (earliest) | Labels are agent-entered and contradict cash; not-yet-due promises must be excluded; no double-claiming of cash | Label ~50%; verified 3.0–4.6% |
| **Recovery per agent-hour** | Recovery ÷ login hours | Recovery ÷ de-overlapped session hours, labelled an *efficiency index* | 80% of payments have no touch in the prior 7 days, so total recovery ÷ hours is not agent productivity | ≈₹16–17k per hour |
| **Cost per ₹ recovered** | — | (Telephony + messaging + people + field cost) ÷ **incremental** recovery vs holdout | Cost ÷ total recovery credits organic payments to spend | **Not computable: no cost data.** Proxy delivered instead: *break-even cost per touch* = observed ₹ effect per touch (point / 95% upper bound), e.g. WhatsApp ₹149 / ₹352 per message, answered call ₹257 / ₹697 (`outputs/tableau/channel_effect_rs_per_touch.csv`) |
| **Channel conversion** | Payments attributed to last touch ÷ touches | P(payment within 7 days after touch) − P(payment within 7 days after a random day); in ₹: regression of ₹ per account-month on touches with month/DPD/product fixed effects; later replaced by holdout lift | Without a baseline, conversion = coincidence | Lift ≈ 0 for all channels (call +0.01 pp, WhatsApp −0.06 pp); ₹ effects not significant |
| **Complaints per 1,000 accounts** | — | Complaints logged in month ÷ 30,000 × 1,000 | Guard-rail metric for any intensity increase | 34–39 |

## Rules that apply to every metric
1. **Fixed population.** Denominators never shrink because an account changed status.
2. **Calendar-neutral.** Month comparisons use per-day values; partial months are never compared.
3. **Uncertainty shown.** Any change is reported with a 95% interval; changes inside it are reported as "no change".
4. **Cash beats labels.** Outcomes (PTP kept, paid, RPC) come from the system that holds the money, not from the agent's disposition.
5. **Incrementality beats attribution.** Channel and campaign value is measured against a holdout or baseline, never by last-touch credit.

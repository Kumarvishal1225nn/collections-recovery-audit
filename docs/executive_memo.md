# Executive memo: is "+11% recovery MoM" real, and where should ₹10 Cr go?

**To:** Leadership team **From:** Kumar Vishal, Analytics **Date:** 15 Nov 2026
**Basis:** all 17 source systems, 1 Jan – 8 Aug 2026. That is 7 complete months; the "≈12 months" in the brief is not in the data. Book: 30,000 accounts, ₹1,049 Cr outstanding. Labels: *Fact*, *Strong evidence*, *Correlation*, *Hypothesis*, *Assumption*.

## 1. What happened?
**Recovery did not improve. It has been flat for seven months at ≈₹18.1 Cr/month (≈₹6 lakh/day), 1.7% of the book per month.** About 7.7% of accounts pay in a given month. *(Strong evidence)*
- **Daily trend** (controlled for weekday, serial-correlation-robust errors): −0.4% per month, 95% CI −1.1% to +0.3%. No sustained improvement above ~0.3% per month is consistent with the data.
- **Consistent population:** on the same 30,000 accounts every month, per-day recovery, recovery per account, recovery rate and paying-account rate all show the same flat picture.

## 2. Is the reported +11% real?
**No. The claim is misleading: one month pair shows +11% in raw totals, but performance did not improve.**
- The same formula gives −8.9%, +11.0%, −7.7%, +4.8%, −4.5% and +6.5% across the six month pairs, so there is no month-on-month pattern at all.
- The only reconstruction that reproduces it (+10.99%) is the March total vs the February total, with duplicate payments included. *(Strong evidence; the business formula was not provided.)*
- March has 31 days and February 28, which is worth +10.7 points on its own. Per day, March was +0.3% above February (95% CI −5.9% to +7.1%, p = 0.93). The weekday mix explains nothing further. *(Fact / Strong evidence)*

Other numbers leadership should not rely on:

| Metric | What it shows | What's actually true | Status |
|---|---|---|---|
| Promise-to-pay kept rate | ~50% (agent labels) | ≈4% backed by cash; "broken" promises are paid almost as often | *Fact* |
| Reported cash | includes duplicates | 500 payments are recorded twice (486 identical copies, 14 with a dropped reference, none ambiguous): ₹2.6 Cr, 1.9% of cash, even across months, so no effect on the trend | *Fact* |
| Contact rate | 40% if voicemail counted | 20% answered | *Fact* |
| Recovery rate on a status-based base | would rise 53% in six months | fixed-book rate is flat; written-off and closed accounts keep paying (35% of July cash) | *Fact* (mechanism); unknown whether the business uses this base |

## 3. Why?
The reporting changed, not the operation. Nothing in the data moves recovery:

| Driver tested | Finding | Status |
|---|---|---|
| Portfolio mix, DPD, product, geography, vintage | No acquisitions; paying rate 7.4–8.1% in every segment; no Simpson's paradox | Strong evidence |
| Channels (call, WhatsApp, SMS, field) | Payment after a touch = payment after a random day (1.8%); no ₹ effect is significant | Strong evidence |
| Campaigns and targeting | No campaign or strategy version differs; targeted accounts that were contacted pay no more than targeted accounts that were skipped | Correlation |
| Calling hour, telephony vendor, attempt frequency | No effect on answer or payment rates | Strong evidence |
| Agents and tenure | Rankings don't repeat across half-years; spread = chance; IDs unreliable | Strong evidence |
| Targeting change (counterfactual) | DiD, robustness and propensity weighting all ≈0; not causally identifiable from this data | Correlation |
| Predictability | Past payment doesn't predict next month (AUC 0.50), so there is nothing to target on | Strong evidence |

Two **data defects** block channel and campaign management:
- Campaigns don't target what they are named for.
- Call, attempt and disposition records disagree on the account.

There is also a **regulatory exposure**: 54% of calls are placed outside 08:00–19:00 IST. *(Fact)*

## 4. How confident are we?
- **High:** the 11% is not real; recovery is flat; today's activity shows no measurable incremental effect.
- **Low:** the size of any future investment return. The data cannot detect lifts below ~5–7% even with a 6-month randomised test, because collections per account are very noisy and the book is small.

## 5. What should management do, and where should the ₹10 Cr go?
1. **Now, at zero cost:**
    - enforce the 08:00–19:00 calling window;
    - report recovery per day on the fixed book, with a confidence band;
    - measure promises-to-pay from cash, not labels.
2. **Do not commit ₹10 Cr to any one option.** The evidence supports none of them at that scale.
    - **Telephony is rejected:** even with optimistic assumptions it returns under 15% of what is needed to repay ₹10 Cr.
    - **Agents, AI voice and field are unproven:** they repay only if their effects sit at the optimistic edge of the data, or if costs are at the low end.
    - **Targeting has no signal to work with** on current data.
    - **No single option can absorb more than ≈₹1.5–5 Cr** within the volume range the data supports.
3. **Lead option: WhatsApp / digital engagement, run inside a 6-month randomised test** (≈₹0.5–1 Cr). It is the only option whose point estimate exceeds its cost across the whole cost range, and its downside is capped and reversible. Test design:
    - three arms of 10,000 accounts: BAU / WhatsApp-first / reduced contact;
    - a pre-registered rule: scale only where the 95% CI excludes zero.
4. **Hold ≥ ₹8.5 Cr** until the test reports.

## 6. Expected financial impact
| | Value | Status |
|---|---|---|
| Spend committed now | ≈₹0.5–1.5 Cr (test + WhatsApp running cost ₹0.2–0.5 Cr/yr) | Assumption |
| WhatsApp expected net gain (point estimate) | +₹1.0–1.3 Cr/yr | Observed effect, **not significant** |
| 95% range of WhatsApp net gain | −₹1.0 Cr to +₹3.3 Cr per year | Observed CI + assumed cost |
| Worst case | ≈−₹1 Cr/yr, stoppable at any time, vs up to −₹10 Cr if the full budget were committed blind | Assumption |
| Capital protected | ≥ ₹8.5 Cr held for evidence-based release | — |

**Cost per ₹ recovered** could not be measured: no cost data was supplied. Finance should replace the assumed unit costs (`docs/assumptions_register.md`); the agent, AI-voice and field verdicts depend on them, while the telephony and WhatsApp verdicts do not.

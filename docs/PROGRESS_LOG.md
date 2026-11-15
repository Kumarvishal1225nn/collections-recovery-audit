# Progress log

## Final version (audit of v2 → final)

| Phase | Completed | Important findings | Files created (C) / modified (M) | Remaining |
|---|---|---|---|---|
| 1 Project audit | Every v2 component re-checked against the brief and the raw CSVs | v2's duplicate-payment description was imprecise (14 of 500 groups are not identical) and its survivor rule kept the wrong copy in 3 groups; no tests, no validation report, no per-option ROI table | M `docs/00_gap_analysis.md` | — |
| 2 Independent data audit | All 17 tables profiled with pandas, independently of the pipeline; coverage re-verified | 1 Jan–8 Aug 2026 = 7 complete months; 486 identical + 14 reference-dropped + 0 ambiguous duplicate payments; ₹2.59 Cr; no retry inflation; 1,859 payers exceed their balance; status field uninformative; no vendor code change | C `scripts/profile_source.py`, `docs/02_source_table_audit.md`, `outputs/validation/column_profile.csv` | — |
| 3 Golden dataset | Duplicate groups classified by evidence; survivor keeps the reference; quarantine rule | Money unchanged; missing-reference rows 371 → 368 | M `sql/20_clean.sql`, `sql/70_dq_checks.sql` | — |
| 4 SQL | Forensics for duplicate classes, retries, late arrival, balance, status; Tableau extracts | 13 blocking checks pass | M `sql/50_forensics.sql`, `run_pipeline.py` | — |
| 5–6 Analysis and the 11% | Verdict table; six month pairs; PENDING sensitivity; previous-month robustness; vendor × month test | Verdict: misleading. Conclusions unchanged under every sensitivity | M `notebooks/build_notebook.py`, `notebooks/analysis.ipynb` | — |
| 7 Counterfactual | Re-verified | No change needed | — | — |
| 8 Investment | One decision table: cost, incremental recovery, range, ROI, break-even, downside for all six options | Telephony rejected; WhatsApp lead option inside a test; hold ≥ ₹8.5 Cr | M `docs/investment_decision.md` | Finance unit costs |
| 9 Reports | DQ report, memo, README, assumptions register, Tableau handoff | — | M `docs/data_quality_report.md`, `docs/executive_memo.md`, `docs/executive_memo.pdf`, `README.md`, `docs/assumptions_register.md`; C `docs/tableau_handoff.md` (replaces the marts dictionary) | — |
| 13 Quality control | Fresh virtual environment rebuild; 9 independent tests; generated validation report | See `docs/validation_report.md` | C `tests/test_golden.py`, `scripts/validate_final.py`, `docs/validation_report.md` | — |
| Removed | v1 HTML dashboard (it showed a withdrawn recommendation) | — | — | Executive dashboard: Tableau phase, not started |

## Earlier versions
- **v2** audited v1: withdrew the assumed 3–6% lift and the untested targeting recommendation; added source validation, campaign / funnel / heterogeneity analysis, the six-option evidence-bounded model and the experiment power analysis.
- **v1** built the pipeline, golden dataset, forensics A–G, the 11% reconstruction and the first memo.

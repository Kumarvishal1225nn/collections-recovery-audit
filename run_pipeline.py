"""
run_pipeline.py — builds the whole analytical layer from the raw CSVs.

    python run_pipeline.py --raw data/raw --db outputs/collections.duckdb

Steps (each is one SQL file, executed in order):
    00_raw -> 10_staging -> 20_clean -> 30_golden -> 40_metrics
           -> 50_forensics -> 60_analysis -> 70_dq_checks
Exports:
    outputs/golden/*.parquet           golden dataset (fact + panel tables)
    outputs/cleaning_waterfall.csv     raw -> rejected/corrected -> golden counts
    outputs/kpi_monthly.csv            governed monthly KPIs
    outputs/forensics/*.csv            every forensic test
    outputs/analysis/*.csv             analytical tables used by the notebook
    outputs/dq_results.csv             data-quality assertions
Exit code 1 if any BLOCK-severity DQ check fails.
"""
import argparse, pathlib, sys, time
import duckdb

ROOT = pathlib.Path(__file__).resolve().parent
STEPS = ["00_raw", "10_staging", "05_validation", "20_clean", "30_golden", "40_metrics",
         "50_forensics", "60_analysis", "70_dq_checks"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default=str(ROOT / "data" / "raw"))
    ap.add_argument("--db", default=str(ROOT / "outputs" / "collections.duckdb"))
    args = ap.parse_args()

    raw_dir = pathlib.Path(args.raw).resolve()
    out = ROOT / "outputs"
    for d in ["golden", "forensics", "analysis", "validation", "tableau"]:
        (out / d).mkdir(parents=True, exist_ok=True)

    con = duckdb.connect(args.db)
    for step in STEPS:
        t0 = time.time()
        sql = (ROOT / "sql" / f"{step}.sql").read_text().replace("{{RAW_DIR}}", raw_dir.as_posix())
        con.execute(sql)
        print(f"[ok] {step:14s} {time.time()-t0:5.1f}s")

    # ---- cleaning waterfall: raw -> golden row counts per entity
    waterfall = con.execute("""
        select * from (values
          ('payments',          (select count(*) from raw.payments),          (select count(*) from cln.payments),        (select count(*) from gld.fct_payment)),
          ('calls',             (select count(*) from raw.calls),             (select count(*) from cln.calls),           (select count(*) from gld.fct_touch where channel='CALL')),
          ('call_attempts',     (select count(*) from raw.call_attempts),     (select count(*) from cln.call_attempts),   (select count(*) from cln.call_attempts)),
          ('call_dispositions', (select count(*) from raw.call_dispositions), (select count(*) from cln.call_dispositions),(select count(*) from cln.call_dispositions)),
          ('whatsapp_events',   (select count(*) from raw.whatsapp_events),   (select count(*) from cln.whatsapp_events), (select count(*) from gld.fct_touch where channel='WHATSAPP')),
          ('sms_events',        (select count(*) from raw.sms_events),        (select count(*) from cln.sms_events),      (select count(*) from gld.fct_touch where channel='SMS')),
          ('field_visits',      (select count(*) from raw.field_visits),      (select count(*) from cln.field_visits),    (select count(*) from gld.fct_touch where channel='FIELD')),
          ('promises_to_pay',   (select count(*) from raw.promises_to_pay),   (select count(*) from cln.promises_to_pay), (select count(*) from gld.fct_ptp)),
          ('borrowers',         (select count(*) from raw.borrowers),         (select count(*) from cln.dim_borrower),    (select count(*) from cln.dim_borrower)),
          ('agents',            (select count(*) from raw.agents),            (select count(*) from cln.dim_agent_scd),   (select count(distinct agent_id) from cln.dim_agent_scd)),
          ('accounts',          (select count(*) from raw.accounts),          (select count(*) from cln.dim_account),     (select count(*) from cln.dim_account)),
          ('daily_targeting',   (select count(*) from raw.daily_targeting),   (select count(*) from cln.daily_targeting), (select count(*) from cln.daily_targeting))
        ) t(entity, raw_rows, clean_rows, golden_rows)""").df()
    waterfall.to_csv(out / "cleaning_waterfall.csv", index=False)
    con.execute("select * from cln.rejection_log").df().to_csv(out / "rejection_log.csv", index=False)

    # ---- golden dataset
    for t in ["fct_payment", "fct_touch", "fct_ptp", "account_month", "calendar_month"]:
        con.execute(f"copy gld.{t} to '{(out/'golden'/(t+'.parquet')).as_posix()}' (format parquet)")
    for t in ["dim_account", "dim_agent_scd", "dim_campaign", "dim_vendor"]:
        con.execute(f"copy cln.{t} to '{(out/'golden'/(t+'.parquet')).as_posix()}' (format parquet)")

    con.execute("select * from mart.kpi_monthly").df().to_csv(out / "kpi_monthly.csv", index=False)
    # Tableau-ready extracts (documented in docs/tableau_handoff.md). One file per grain; no PII.
    tb = out / "tableau"
    tableau = {
        "kpi_monthly":   "select * from mart.kpi_monthly",
        "kpi_daily":     "select * from mart.kpi_daily",
        "accounts":      """select account_id, loan_type, dpd, dpd_bucket, risk_segment, snapshot_status, principal_amount, outstanding_amount,
                                   coalesce(state,'UNKNOWN') state, coalesce(city,'UNKNOWN') city, account_timezone, opened_at_local::date opened_date,
                                   flag_geo_conflict, flag_missing_borrower, flag_orphan_borrower, flag_outstanding_gt_principal
                            from cln.dim_account""",
        "account_month": """select account_id, month_start, is_complete, days_in_month, collected, n_payments, paid_flag, n_touches, n_calls, n_calls_answered,
                                   n_whatsapp, n_sms, n_field_visits, n_dial_attempts, n_rpc, n_ptps, n_target_days, targeted_new_strategy, n_complaints,
                                   status_at_month_start
                            from gld.account_month""",
        "payments":      """select payment_id, account_id, event_at_ist, month_start, net_amount, payment_method, attr_7d_channel,
                                   days_since_last_touch, naive_touch_after_payment, flag_shared_reference
                            from gld.fct_payment""",
        "channel_month": """select date_trunc('month', event_at_ist)::date month_start, channel, count(*) touches, sum(is_engaged::int) engaged_touches,
                                   count(distinct account_id) accounts_touched
                            from gld.fct_touch where event_at_ist >= '2026-01-01' and event_at_ist < '2026-08-09' group by all order by all""",
        "segment_month": "select * from ana.segment_month",
        "channel_conversion": "select c.*, b.baseline_pay_within_7d_pct from ana.channel_conversion c cross join ana.channel_baseline b",
        "campaign_summary": "select * from ana.campaign_summary",
        "funnel_monthly": "select * from ana.funnel_monthly",
        "cleaning_waterfall": None,
        "data_quality_rules": "select * from cln.rejection_log",
        "duplicate_payment_classes": "select * from fx.a_duplicate_payment_classes",
        "reported_vs_audited_mom": "select * from fx.f0_reported_mom",
    }
    for name, sql in tableau.items():
        (waterfall if sql is None else con.execute(sql).df()).to_csv(tb / f"{name}.csv", index=False)
    for schema, folder in [("val", "validation"), ("fx", "forensics"), ("ana", "analysis")]:
        for (t,) in con.execute(f"select table_name from information_schema.tables where table_schema='{schema}'").fetchall():
            if t in ("agent_call_tenure", "campaign_targeting"):   # row-level, too large for csv
                continue
            con.execute(f"select * from {schema}.{t}").df().to_csv(out / folder / f"{t}.csv", index=False)

    dq = con.execute("select * from dq.results").df()
    dq.to_csv(out / "dq_results.csv", index=False)
    print(dq.to_string(index=False))
    if ((dq.status == "FAIL") & (dq.severity == "BLOCK")).any():
        print("BLOCKING data-quality failure"); sys.exit(1)
    print("pipeline complete")


if __name__ == "__main__":
    main()

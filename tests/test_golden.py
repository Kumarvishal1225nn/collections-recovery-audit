"""Independent checks of the golden dataset against the ORIGINAL CSVs.
Everything on the 'expected' side is recomputed here with pandas from data/raw, sharing no code with the SQL pipeline.
    python run_pipeline.py && pytest -q
"""
import pathlib
import pandas as pd
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RAW, OUT = ROOT / "data" / "raw", ROOT / "outputs"


@pytest.fixture(scope="session")
def raw_pay():
    p = pd.read_csv(RAW / "payments.csv")
    p["event_at"] = pd.to_datetime(p["event_at"])
    return p


@pytest.fixture(scope="session")
def gold_pay():
    return pd.read_parquet(OUT / "golden" / "fct_payment.parquet")


@pytest.fixture(scope="session")
def panel():
    return pd.read_parquet(OUT / "golden" / "account_month.parquet")


def test_duplicate_groups_are_486_identical_and_14_reference_dropped(raw_pay):
    g = raw_pay.groupby("payment_id")
    dup_ids = g.size()[g.size() > 1].index
    d = raw_pay[raw_pay.payment_id.isin(dup_ids)]
    assert len(dup_ids) == 500 and (g.size().loc[dup_ids] == 2).all()
    core = ["account_id", "borrower_id", "event_at", "amount", "payment_status", "payment_method", "provider_id"]
    assert (d.groupby("payment_id")[core].nunique() == 1).all().all(), "copies disagree on a core field"
    refs = d.groupby("payment_id").payment_reference.agg(lambda s: (s.nunique(dropna=True), s.isna().sum()))
    identical = sum(1 for n, na in refs if na in (0, 2) and n <= 1)
    dropped = sum(1 for n, na in refs if na == 1 and n == 1)
    assert (identical, dropped) == (486, 14)
    assert sum(1 for n, na in refs if n > 1) == 0, "two different references under one payment_id"


def test_golden_cash_equals_deduplicated_success_cash_in_source(raw_pay, gold_pay):
    expected = raw_pay.drop_duplicates("payment_id").query("payment_status == 'SUCCESS'")
    assert len(gold_pay) == len(expected) == 17534
    assert gold_pay.net_amount.sum() == pytest.approx(expected.amount.sum(), abs=1)
    assert gold_pay.payment_id.is_unique
    assert set(gold_pay.payment_id) == set(expected.payment_id)


def test_duplicates_inflate_success_cash_by_2_59_crore(raw_pay):
    s = raw_pay.query("payment_status == 'SUCCESS'")
    assert (s.amount.sum() - s.drop_duplicates("payment_id").amount.sum()) / 1e7 == pytest.approx(2.59, abs=0.005)


def test_reported_11_percent_reproduces_from_raw_rows(raw_pay):
    s = raw_pay.query("payment_status == 'SUCCESS'")
    m = s.groupby(s.event_at.dt.to_period("M")).amount.sum()
    assert 100 * (m["2026-03"] / m["2026-02"] - 1) == pytest.approx(10.99, abs=0.01)


def test_per_day_change_is_about_zero(gold_pay):
    m = gold_pay.groupby(pd.to_datetime(gold_pay.month_start).dt.to_period("M")).net_amount.sum()
    assert 100 * ((m["2026-03"] / 31) / (m["2026-02"] / 28) - 1) == pytest.approx(0.29, abs=0.01)


def test_panel_is_a_fixed_cohort_with_no_fan_out(panel, gold_pay):
    n_accounts = len(pd.read_csv(RAW / "accounts.csv"))
    assert n_accounts == 30000
    assert len(panel) == n_accounts * panel.month_start.nunique()
    assert not panel.duplicated(["account_id", "month_start"]).any()
    assert panel.collected.sum() == pytest.approx(gold_pay.net_amount.sum(), abs=1)


def test_no_non_cash_status_reaches_golden(raw_pay, gold_pay):
    bad = set(raw_pay.loc[raw_pay.payment_status != "SUCCESS", "payment_id"])
    assert not (set(gold_pay.payment_id) & bad)


def test_calls_are_unique_and_utc_rows_shift_by_5h30():
    raw = pd.read_csv(RAW / "calls.csv")
    assert raw.call_id.nunique() == 90000
    touch = pd.read_parquet(OUT / "golden" / "fct_touch.parquet")
    calls = touch[touch.channel == "CALL"]
    assert calls.touch_id.is_unique
    one = raw[(raw.timezone == "UTC") & (raw.direction == "OUTBOUND") & ~raw.call_id.duplicated(keep=False)].iloc[0]
    got = calls.loc[calls.touch_id == one.call_id, "event_at_ist"].iloc[0]
    assert pd.Timestamp(got) - pd.Timestamp(one.event_at) == pd.Timedelta(hours=5, minutes=30)


def test_tableau_extracts_reconcile_to_golden(gold_pay):
    tb = OUT / "tableau"
    assert pd.read_csv(tb / "payments.csv").net_amount.sum() == pytest.approx(gold_pay.net_amount.sum(), abs=1)
    assert pd.read_csv(tb / "account_month.csv").collected.sum() == pytest.approx(gold_pay.net_amount.sum(), abs=1)
    k = pd.read_csv(tb / "kpi_monthly.csv")
    assert k.net_collections.sum() == pytest.approx(gold_pay.net_amount.sum(), abs=1)
    assert pd.read_csv(tb / "kpi_daily.csv").net_collections.sum() == pytest.approx(gold_pay.net_amount.sum(), abs=1)

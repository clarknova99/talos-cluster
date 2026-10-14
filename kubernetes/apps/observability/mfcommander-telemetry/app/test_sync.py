"""Unit tests for sync.py. No network, no database: tables are in-memory fakes.

Run: python -m pytest test_sync.py   (see ../README.md)
"""

from __future__ import annotations

import json
import uuid
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

import pytest

import sync


class FakeTable:
    """Mimics boto3's Table.scan: pages of `page_size`, LastEvaluatedKey between."""

    def __init__(self, items, page_size=2):
        self.items = list(items)
        self.page_size = page_size
        self.calls: list[dict] = []

    def scan(self, **kwargs):
        self.calls.append(kwargs)
        start = kwargs.get("ExclusiveStartKey", {}).get("offset", 0)
        end = start + self.page_size
        page = {"Items": self.items[start:end]}
        if end < len(self.items):
            page["LastEvaluatedKey"] = {"offset": end}
        return page


INSTALL = "3f1c9a52-7d0e-4b8e-9a51-2c8f6d4e1b70"


def v1_item(**overrides):
    item = {
        "install_id": INSTALL,
        "day": "2026-10-01",
        "schema_version": Decimal("1"),
        "policy_version": Decimal("1"),
        "cohort_week": "2026-W39",
        "app_version": "1.4.0",
        "os_major": Decimal("26"),
        "arch": "arm64",
        "tier": "community",
        "active_days": Decimal("3"),
        "counters": {"viewer.opened": Decimal("3"), "fileop.copy": Decimal("0")},
        "ttl": Decimal("1790000000"),
    }
    item.update(overrides)
    return item


def v2_item(**overrides):
    item = {
        "install_id": "0b6c1d2e-3f40-4a5b-8c6d-7e8f9a0b1c2d",
        "day": "2026-10-12",
        "schema_version": Decimal("2"),
        "policy_version": Decimal("2"),
        "cohort_week": "2026-W41",
        "app_version": "1.5.0",
        "os_major": Decimal("15"),
        "arch": "x86_64",
        "tier": "pro",
        "active_days": Decimal("7"),
        "license_id": "lic_abc123",
        "counters": {"viewer.opened": Decimal("4211"), "buy.clicked": Decimal("1")},
    }
    item.update(overrides)
    return item


def license_item(**overrides):
    item = {
        "license_id": "lic_abc123",
        "polar_order_id": "ord_1",
        "email": "buyer@example.com",
        "customer_name": "Ada Buyer",
        "tier": "pro",
        "status": "active",
        "issued_at": "2026-09-01T10:00:00+00:00",
        "updates_until": "2027-09-01T10:00:00+00:00",
        "created_at": "2026-09-01T10:00:01.123456+00:00",
        "updated_at": "2026-10-10T08:00:00Z",
        "last_validated_at": "2026-10-10T08:00:00+00:00",
    }
    item.update(overrides)
    return item


# ---- Decimal -> int --------------------------------------------------------------------


def test_to_int_converts_integral_decimal():
    assert sync.to_int(Decimal("42")) == 42
    assert isinstance(sync.to_int(Decimal("42")), int)
    assert sync.to_int(Decimal("1E+2")) == 100
    assert sync.to_int(None) is None
    assert sync.to_int(7) == 7


def test_to_int_rejects_fractional_and_bool():
    with pytest.raises(ValueError):
        sync.to_int(Decimal("1.5"))
    with pytest.raises(ValueError):
        sync.to_int(True)


# ---- counters map -> json --------------------------------------------------------------


def test_counters_map_becomes_json_with_plain_ints():
    encoded = sync.to_json({"b": Decimal("2"), "a": Decimal("0"), "nested": {"5": Decimal("9")}})
    assert json.loads(encoded) == {"a": 0, "b": 2, "nested": {"5": 9}}
    assert '"a": 0' in encoded  # ints, not "0" strings or 0.0 floats


def test_missing_counters_become_empty_object():
    assert sync.to_json(None) == "{}"


# ---- telemetry rows: v1 / v2 / optional fields ----------------------------------------


def test_v1_row_keeps_range_ordinals_and_ignores_ttl():
    row = dict(zip(sync.TELEMETRY_COLUMNS, sync.telemetry_row(v1_item())))
    assert row["install_id"] == INSTALL
    uuid.UUID(row["install_id"])
    assert row["day"] == date(2026, 10, 1)
    assert row["schema_version"] == 1
    assert row["os_major"] == 26 and isinstance(row["os_major"], int)
    assert row["trial_day"] is None
    assert row["license_id"] is None
    assert json.loads(row["counters"]) == {"viewer.opened": 3, "fileop.copy": 0}
    assert "ttl" not in sync.TELEMETRY_COLUMNS


def test_v2_row_keeps_exact_counts_and_license():
    row = dict(zip(sync.TELEMETRY_COLUMNS, sync.telemetry_row(v2_item())))
    assert row["schema_version"] == 2
    assert row["license_id"] == "lic_abc123"
    assert json.loads(row["counters"])["viewer.opened"] == 4211


def test_trial_row_carries_trial_day():
    row = dict(zip(sync.TELEMETRY_COLUMNS, sync.telemetry_row(v1_item(tier="trial", trial_day=Decimal("5")))))
    assert row["trial_day"] == 5


def test_row_tolerates_missing_optional_attributes():
    sparse = {"install_id": INSTALL, "day": "2026-10-02"}
    row = dict(zip(sync.TELEMETRY_COLUMNS, sync.telemetry_row(sparse)))
    assert row["day"] == date(2026, 10, 2)
    assert row["schema_version"] is None
    assert row["tier"] is None
    assert row["counters"] == "{}"


def test_row_width_matches_columns():
    assert len(sync.telemetry_row(v2_item())) == len(sync.TELEMETRY_COLUMNS)
    agg = {"cohort_week": "2026-W40", "month": "2026-10"}
    assert len(sync.aggregate_row(agg)) == len(sync.AGGREGATE_COLUMNS)
    assert len(sync.license_row(license_item())) == len(sync.LICENSE_COLUMNS)


# ---- aggregates ------------------------------------------------------------------------


def test_aggregate_row_converts_month_and_buckets():
    item = {
        "cohort_week": "2026-W40",
        "month": "2026-10",
        "active_installations": Decimal("12"),
        "report_count": Decimal("80"),
        "active_days": Decimal("150"),
        "counter_buckets": {"viewer.opened": {"0": Decimal("2"), "3": Decimal("10")}},
    }
    row = dict(zip(sync.AGGREGATE_COLUMNS, sync.aggregate_row(item)))
    assert row["month"] == date(2026, 10, 1)
    assert row["active_installations"] == 12
    assert json.loads(row["counter_buckets"]) == {"viewer.opened": {"0": 2, "3": 10}}


# ---- licenses --------------------------------------------------------------------------


def test_license_row_parses_timestamps_and_missing_fields():
    row = dict(zip(sync.LICENSE_COLUMNS, sync.license_row(license_item())))
    assert row["issued_at"] == datetime(2026, 9, 1, 10, tzinfo=timezone.utc)
    assert row["updated_at"] == datetime(2026, 10, 10, 8, tzinfo=timezone.utc)  # "Z" suffix
    assert row["revoked_at"] is None
    assert row["email"] == "buyer@example.com"


def test_naive_and_bad_timestamps():
    assert sync.parse_timestamp("2026-01-02T03:04:05") == datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
    assert sync.parse_timestamp("2026-01-02T03:04:05-05:00").utcoffset() == timedelta(hours=-5)
    assert sync.parse_timestamp("not a date") is None
    assert sync.parse_timestamp("") is None


def test_license_row_never_contains_signed_key_even_if_present():
    row = sync.license_row(license_item(signed_key="SECRET-MATERIAL"))
    assert "SECRET-MATERIAL" not in row


def test_licenses_scan_request_is_attribute_restricted():
    kwargs = sync.license_scan_kwargs()
    assert kwargs["Select"] == "SPECIFIC_ATTRIBUTES"
    names = kwargs["ExpressionAttributeNames"]
    assert sorted(names.values()) == sorted(sync.LICENSE_ATTRIBUTES)
    # Every projected token is a placeholder, so reserved words such as `status` work.
    tokens = [t.strip() for t in kwargs["ProjectionExpression"].split(",")]
    assert sorted(tokens) == sorted(names)
    assert "status" in names.values()
    assert "signed_key" not in json.dumps(kwargs)


def test_read_sources_skips_throttle_rows_and_never_requests_signed_key():
    licenses = FakeTable(
        [
            license_item(),
            {"license_id": "recover-throttle#buyer@example.com"},
            license_item(license_id="lic_def456", status="refunded",
                         revoked_at="2026-10-05T00:00:00+00:00"),
        ],
        page_size=1,
    )
    data = sync.read_sources(FakeTable([v1_item(), v2_item()]), FakeTable([]), licenses)
    assert [row[0] for row in data["licenses"]] == ["lic_abc123", "lic_def456"]
    assert data["skipped_rows"] == 1
    assert len(licenses.calls) == 3
    for call in licenses.calls:
        assert call["Select"] == "SPECIFIC_ATTRIBUTES"
        assert "signed_key" not in json.dumps(call, default=str)


# ---- pagination ------------------------------------------------------------------------


def test_scan_all_follows_last_evaluated_key():
    items = [v1_item(day=f"2026-10-{d:02d}") for d in range(1, 8)]
    table = FakeTable(items, page_size=3)
    assert list(sync.scan_all(table)) == items
    assert len(table.calls) == 3
    assert "ExclusiveStartKey" not in table.calls[0]
    assert table.calls[1]["ExclusiveStartKey"] == {"offset": 3}
    assert table.calls[2]["ExclusiveStartKey"] == {"offset": 6}


def test_scan_all_keeps_request_kwargs_on_every_page():
    table = FakeTable([license_item(license_id=f"lic_{i}") for i in range(5)], page_size=2)
    rows = list(sync.scan_all(table, **sync.license_scan_kwargs()))
    assert len(rows) == 5
    assert all(call["Select"] == "SPECIFIC_ATTRIBUTES" for call in table.calls)


def test_scan_all_handles_empty_table():
    table = FakeTable([])
    assert list(sync.scan_all(table)) == []
    assert len(table.calls) == 1


def test_read_sources_counts_everything():
    data = sync.read_sources(
        FakeTable([v1_item(), v2_item()], page_size=1),
        FakeTable([{"cohort_week": "2026-W40", "month": "2026-10"}]),
        FakeTable([license_item()]),
    )
    assert len(data["telemetry_reports"]) == 2
    assert len(data["telemetry_aggregates"]) == 1
    assert len(data["licenses"]) == 1
    assert data["skipped_rows"] == 0


# ------------------------------------------------------------------ keep-forever telemetry


def test_upsert_statement_updates_every_non_key_column():
    statement = sync.upsert_statement("telemetry_reports", sync.TELEMETRY_COLUMNS, ("install_id", "day"))
    assert statement.startswith("INSERT INTO telemetry_reports (")
    assert "FROM staging_telemetry_reports" in statement
    assert "ON CONFLICT (install_id, day) DO UPDATE SET" in statement
    for column in sync.TELEMETRY_COLUMNS:
        if column in ("install_id", "day"):
            assert f"{column} = EXCLUDED.{column}" not in statement
        else:
            assert f"{column} = EXCLUDED.{column}" in statement


class _RecordingCopy:
    def __init__(self, log, statement):
        self.log, self.statement = log, statement

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def write_row(self, row):
        self.log.append(("row", str(self.statement), row))


class _RecordingCursor:
    def __init__(self, log):
        self.log = log

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, statement, params=None):
        self.log.append(("execute", str(statement)))

    def copy(self, statement):
        self.log.append(("copy", str(statement)))
        return _RecordingCopy(self.log, statement)


class _RecordingConnection:
    class info:
        dbname = "mfcommander"

    def __init__(self):
        self.log = []

    def transaction(self):
        return _RecordingCursor(self.log)  # any no-op context manager

    def cursor(self):
        return _RecordingCursor(self.log)


def _mirror_data():
    return {
        "telemetry_reports": [("r",) * len(sync.TELEMETRY_COLUMNS)],
        "telemetry_aggregates": [("a",) * len(sync.AGGREGATE_COLUMNS)],
        "licenses": [("l",) * len(sync.LICENSE_COLUMNS)],
        "skipped_rows": 0,
    }


def test_write_mirror_never_truncates_or_deletes_telemetry():
    """Postgres is the second copy of telemetry: a row DynamoDB loses must survive here."""
    conn = _RecordingConnection()
    sync.write_mirror(conn, _mirror_data(), datetime.now(timezone.utc))
    executed = [entry[1] for entry in conn.log if entry[0] == "execute"]
    destructive = [s for s in executed if "TRUNCATE" in s or s.lstrip().startswith("DELETE")]
    assert all("telemetry_reports" not in s and "telemetry_aggregates" not in s for s in destructive)
    assert any("ON CONFLICT (install_id, day)" in s for s in executed)
    assert any("ON CONFLICT (cohort_week, month)" in s for s in executed)


def test_write_mirror_keeps_licenses_an_exact_mirror():
    """A license's status changes and refunds must not leave a stale row behind."""
    conn = _RecordingConnection()
    sync.write_mirror(conn, _mirror_data(), datetime.now(timezone.utc))
    executed = [entry[1] for entry in conn.log if entry[0] == "execute"]
    assert "TRUNCATE licenses" in executed

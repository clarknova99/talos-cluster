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


class FakeClientError(Exception):
    """Shaped like botocore's ClientError: a `response` dict carrying Error.Code."""

    def __init__(self, code):
        super().__init__(f"An error occurred ({code}) when calling the operation")
        self.response = {"Error": {"Code": code, "Message": "test"}}


class FakeCloudWatch:
    """Mimics the two CloudWatch calls the sync makes, with NextToken paging on list_metrics.

    `series` maps a Route to [(timestamp, value), ...] daily points. `deny` makes every
    call raise FakeClientError with that code.
    """

    def __init__(self, series=None, page_size=2, deny=None):
        self.series = series or {}
        self.page_size = page_size
        self.deny = deny
        self.list_calls: list[dict] = []
        self.data_calls: list[dict] = []

    def list_metrics(self, **kwargs):
        self.list_calls.append(kwargs)
        if self.deny:
            raise FakeClientError(self.deny)
        routes = sorted(self.series)
        start = int(kwargs.get("NextToken", 0))
        metrics = [
            {
                "Namespace": kwargs["Namespace"],
                "MetricName": kwargs["MetricName"],
                "Dimensions": [{"Name": "Route", "Value": route}],
            }
            for route in routes[start:start + self.page_size]
        ]
        page = {"Metrics": metrics}
        if start + self.page_size < len(routes):
            page["NextToken"] = str(start + self.page_size)
        return page

    def get_metric_data(self, **kwargs):
        self.data_calls.append(kwargs)
        if self.deny:
            raise FakeClientError(self.deny)
        results = []
        for query in kwargs["MetricDataQueries"]:
            route = query["MetricStat"]["Metric"]["Dimensions"][0]["Value"]
            points = [
                (at, value)
                for at, value in self.series.get(route, [])
                if kwargs["StartTime"] <= at < kwargs["EndTime"]
            ]
            results.append({
                "Id": query["Id"],
                "Timestamps": [at for at, _ in points],
                "Values": [value for _, value in points],
                "StatusCode": "Complete",
            })
        return {"MetricDataResults": results}


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
    data = sync.read_sources(FakeTable([v1_item(), v2_item()]), FakeTable([]), licenses,
                             FakeTable([]), FakeCloudWatch())
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
        FakeTable([]),
        FakeCloudWatch(),
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


def _mirror_data(devices_scanned=True, unkeyed_fetched=True):
    """`None` for devices / api_unkeyed_daily means that mirror was skipped this run."""
    return {
        "telemetry_reports": [("r",) * len(sync.TELEMETRY_COLUMNS)],
        "telemetry_aggregates": [("a",) * len(sync.AGGREGATE_COLUMNS)],
        "licenses": [("l",) * len(sync.LICENSE_COLUMNS)],
        "skipped_rows": 0,
        "devices": [("dev",) * len(sync.DEVICE_COLUMNS)] if devices_scanned else None,
        "api_unkeyed_daily": [(date(2026, 10, 1), "/v1/x", 1)] if unkeyed_fetched else None,
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


# ---- devices: row shapes ---------------------------------------------------------------

DEVICE = "9d3e2f10-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
LICENSE = "lic_abc123"


def trial_item(**overrides):
    item = {
        "pk": f"device#{DEVICE}",
        "sk": "trial",
        "started_at": "2026-10-03T09:00:00Z",
        "last_checked_at": "2026-10-12T09:30:00+00:00",
        "app_version": "1.5.0",
    }
    item.update(overrides)
    return item


def activation_item(**overrides):
    item = {
        "pk": f"license#{LICENSE}",
        "sk": f"device#{DEVICE}",
        "license_id": LICENSE,
        "device_id": DEVICE,
        "device_name": "Michael's MacBook Pro",
        "activated_at": "2026-09-01T10:00:00+00:00",
        "last_seen_at": "2026-10-13T07:00:00+00:00",
    }
    item.update(overrides)
    return item


def unidentified_item(**overrides):
    item = {
        "pk": f"license#{LICENSE}",
        "sk": "unidentified#7c1e0a2b-3d4f-4a5b-9c6d-8e7f6a5b4c3d",
        "unidentified": True,
        "license_id": LICENSE,
        "device_name": "Unknown Mac",
        "activated_at": "2026-10-02T12:00:00+00:00",
    }
    item.update(overrides)
    return item


def meta_item(**overrides):
    item = {"pk": f"license#{LICENSE}", "sk": "meta", "active_count": Decimal("2")}
    item.update(overrides)
    return item


def as_dict(row):
    return dict(zip(sync.DEVICE_COLUMNS, row))


def test_trial_row_maps_to_trial_kind():
    row = as_dict(sync.device_row(trial_item()))
    assert row["kind"] == "trial"
    assert row["pk"] == f"device#{DEVICE}" and row["sk"] == "trial"
    assert row["device_id"] == DEVICE
    assert row["license_id"] is None
    assert row["started_at"] == datetime(2026, 10, 3, 9, tzinfo=timezone.utc)
    assert row["last_checked_at"] == datetime(2026, 10, 12, 9, 30, tzinfo=timezone.utc)
    assert row["app_version"] == "1.5.0"
    assert row["activated_at"] is None and row["active_count"] is None
    assert row["over_cap"] is False and row["unidentified"] is False


def test_activation_row_maps_to_activation_kind():
    row = as_dict(sync.device_row(activation_item(deactivated_at="2026-10-05T00:00:00Z", over_cap=True)))
    assert row["kind"] == "activation"
    assert row["license_id"] == LICENSE and row["device_id"] == DEVICE
    assert row["device_name"] == "Michael's MacBook Pro"
    assert row["activated_at"] == datetime(2026, 9, 1, 10, tzinfo=timezone.utc)
    assert row["deactivated_at"] == datetime(2026, 10, 5, tzinfo=timezone.utc)
    assert row["last_seen_at"] == datetime(2026, 10, 13, 7, tzinfo=timezone.utc)
    assert row["over_cap"] is True
    assert row["unidentified"] is False
    assert row["started_at"] is None


def test_activation_without_optional_attributes_defaults_flags():
    row = as_dict(sync.device_row(activation_item()))
    assert row["deactivated_at"] is None
    assert row["device_name"] == "Michael's MacBook Pro"
    assert row["over_cap"] is False


def test_unidentified_row_maps_to_unidentified_kind_without_device_id():
    row = as_dict(sync.device_row(unidentified_item()))
    assert row["kind"] == "unidentified"
    assert row["unidentified"] is True
    assert row["device_id"] is None
    assert row["license_id"] == LICENSE
    assert row["device_name"] == "Unknown Mac"
    assert row["activated_at"] == datetime(2026, 10, 2, 12, tzinfo=timezone.utc)


def test_meta_row_maps_active_count_to_int():
    row = as_dict(sync.device_row(meta_item()))
    assert row["kind"] == "meta"
    assert row["license_id"] == LICENSE
    assert row["device_id"] is None
    assert row["active_count"] == 2 and isinstance(row["active_count"], int)


def test_device_row_width_matches_columns():
    for item in (trial_item(), activation_item(), unidentified_item(), meta_item()):
        assert len(sync.device_row(item)) == len(sync.DEVICE_COLUMNS)


def test_unrecognised_device_keys_are_not_classified():
    assert sync.device_kind("device#x", "activation") is None
    assert sync.device_kind("license#x", "something-else") is None
    assert sync.device_kind(f"device#{DEVICE}", "trial") == "trial"


# ---- devices: scan tolerance and exact mirror ------------------------------------------


@pytest.mark.parametrize("code", ["ResourceNotFoundException", "AccessDeniedException"])
def test_devices_absent_or_denied_skips_only_that_mirror(code, caplog):
    caplog.set_level("WARNING", logger="mfcommander-telemetry-sync")
    data = sync.read_sources(
        FakeTable([v1_item(), v2_item()]),
        FakeTable([{"cohort_week": "2026-W40", "month": "2026-10"}]),
        FakeTable([license_item()]),
        _raising_table(code),
        FakeCloudWatch(),
    )
    assert data["devices"] is None
    assert len(data["telemetry_reports"]) == 2
    assert len(data["telemetry_aggregates"]) == 1
    assert len(data["licenses"]) == 1
    assert data["api_unkeyed_daily"] == []
    warnings = [r for r in caplog.records if "devices" in r.getMessage()]
    assert len(warnings) == 1
    assert code in warnings[0].getMessage()


def _raising_table(code):
    class Denied:
        table_name = "mfcommander-devices"

        def scan(self, **kwargs):
            raise FakeClientError(code)

    return Denied()


def test_devices_other_errors_still_fail_the_run():
    with pytest.raises(FakeClientError):
        sync.read_sources(FakeTable([]), FakeTable([]), FakeTable([]),
                          _raising_table("ValidationException"), FakeCloudWatch())


def test_devices_scan_reads_every_page_and_skips_unrecognised_keys():
    items = [trial_item(), activation_item(), unidentified_item(), meta_item(),
             {"pk": "something#else", "sk": "x"}]
    rows = sync.read_devices(FakeTable(items, page_size=2))
    assert [row[0] for row in rows] == [
        f"device#{DEVICE}", f"license#{LICENSE}", f"license#{LICENSE}", f"license#{LICENSE}"
    ]
    assert [row[2] for row in rows] == ["trial", "activation", "unidentified", "meta"]


def test_devices_deleted_in_dynamodb_disappear_from_the_next_read():
    before = FakeTable([trial_item(), activation_item(), meta_item()])
    after = FakeTable([trial_item(), meta_item()])
    assert len(sync.read_devices(before)) == 3
    rows = sync.read_devices(after)
    assert [row[2] for row in rows] == ["trial", "meta"]


def test_write_mirror_replaces_devices_exactly_and_never_upserts_them():
    conn = _RecordingConnection()
    sync.write_mirror(conn, _mirror_data(), datetime.now(timezone.utc))
    executed = [entry[1] for entry in conn.log if entry[0] == "execute"]
    assert "TRUNCATE devices" in executed
    assert not any("staging_devices" in s for s in executed)
    assert any(entry[0] == "row" and entry[2][0] == "dev" for entry in conn.log)


def test_write_mirror_leaves_devices_untouched_when_the_scan_was_skipped():
    conn = _RecordingConnection()
    sync.write_mirror(conn, _mirror_data(devices_scanned=False), datetime.now(timezone.utc))
    executed = [entry[1] for entry in conn.log if entry[0] == "execute"]
    assert "TRUNCATE devices" not in executed
    assert not any(entry[0] == "row" and entry[2][0] == "dev" for entry in conn.log)
    # Every other mirror still completes, and the run is still recorded.
    assert "TRUNCATE licenses" in executed
    assert any("ON CONFLICT (install_id, day)" in s for s in executed)
    assert any(s.lstrip().startswith("INSERT INTO sync_runs") for s in executed)


def _ddl(name):
    return next(statement for statement in sync.SCHEMA_SQL
                if f"CREATE TABLE IF NOT EXISTS {name} " in statement)


def test_schema_declares_devices_with_composite_key_and_typed_columns():
    devices_ddl = _ddl("devices")
    for column in ("pk", "sk", "kind", "device_id", "license_id", "device_name", "started_at",
                   "last_checked_at", "app_version", "activated_at", "deactivated_at",
                   "over_cap", "unidentified", "last_seen_at", "active_count"):
        assert column in devices_ddl
    assert "PRIMARY KEY (pk, sk)" in devices_ddl
    assert "over_cap" in devices_ddl and "boolean" in devices_ddl


# ---- api_unkeyed_daily: CloudWatch fetch -----------------------------------------------

NOW = datetime(2026, 10, 14, 12, 0, tzinfo=timezone.utc)


def test_unkeyed_rows_are_daily_sums_per_route_inside_the_window():
    cloudwatch = FakeCloudWatch({
        "/v1/licenses/validate": [
            (datetime(2026, 10, 1, tzinfo=timezone.utc), 12.0),
            (datetime(2026, 10, 2, tzinfo=timezone.utc), 3.0),
            (datetime(2026, 9, 1, tzinfo=timezone.utc), 99.0),  # outside the window
        ],
        "/v1/telemetry": [(datetime(2026, 10, 13, tzinfo=timezone.utc), 7.0)],
    })
    rows = sync.fetch_unkeyed_daily(cloudwatch, NOW)
    assert sorted(rows) == sorted([
        (date(2026, 10, 1), "/v1/licenses/validate", 12),
        (date(2026, 10, 2), "/v1/licenses/validate", 3),
        (date(2026, 10, 13), "/v1/telemetry", 7),
    ])
    assert all(isinstance(row[2], int) for row in rows)


def test_unkeyed_requests_daily_sum_over_fifteen_days_in_utc():
    cloudwatch = FakeCloudWatch({"/v1/x": [(datetime(2026, 10, 14, tzinfo=timezone.utc), 1.0)]})
    sync.fetch_unkeyed_daily(cloudwatch, NOW)
    listed = cloudwatch.list_calls[0]
    assert listed["Namespace"] == "MFCommander/API"
    assert listed["MetricName"] == "UnkeyedRequests"
    query_call = cloudwatch.data_calls[0]
    assert query_call["StartTime"] == datetime(2026, 9, 30, tzinfo=timezone.utc)
    assert query_call["EndTime"] == NOW
    query = query_call["MetricDataQueries"][0]
    assert query["MetricStat"]["Period"] == 86400
    assert query["MetricStat"]["Stat"] == "Sum"
    assert query["MetricStat"]["Metric"] == {
        "Namespace": "MFCommander/API",
        "MetricName": "UnkeyedRequests",
        "Dimensions": [{"Name": "Route", "Value": "/v1/x"}],
    }


def test_unkeyed_list_metrics_is_paginated_and_each_route_queried_once():
    series = {f"/v1/r{i}": [(datetime(2026, 10, 13, tzinfo=timezone.utc), float(i))] for i in range(5)}
    cloudwatch = FakeCloudWatch(series, page_size=2)
    rows = sync.fetch_unkeyed_daily(cloudwatch, NOW)
    assert len(cloudwatch.list_calls) == 3
    assert sorted(row[1] for row in rows) == sorted(series)
    queried = [q["MetricStat"]["Metric"]["Dimensions"][0]["Value"]
               for call in cloudwatch.data_calls for q in call["MetricDataQueries"]]
    assert sorted(queried) == sorted(series)


def test_unkeyed_route_listed_twice_produces_one_row_per_day():
    class Duplicated(FakeCloudWatch):
        def list_metrics(self, **kwargs):
            page = super().list_metrics(**kwargs)
            page["Metrics"] = page["Metrics"] + page["Metrics"]
            page.pop("NextToken", None)
            return page

    cloudwatch = Duplicated({"/v1/x": [(datetime(2026, 10, 13, tzinfo=timezone.utc), 4.0)]}, page_size=5)
    rows = sync.fetch_unkeyed_daily(cloudwatch, NOW)
    assert rows == [(date(2026, 10, 13), "/v1/x", 4)]


def test_unkeyed_with_no_routes_returns_no_rows_and_no_metric_query():
    cloudwatch = FakeCloudWatch({})
    assert sync.fetch_unkeyed_daily(cloudwatch, NOW) == []
    assert cloudwatch.data_calls == []


@pytest.mark.parametrize("code", ["AccessDenied", "AccessDeniedException"])
def test_unkeyed_access_denied_skips_only_that_mirror(code, caplog):
    caplog.set_level("WARNING", logger="mfcommander-telemetry-sync")
    data = sync.read_sources(
        FakeTable([v1_item()]), FakeTable([]), FakeTable([license_item()]), FakeTable([]),
        FakeCloudWatch({"/v1/x": [(datetime(2026, 10, 13, tzinfo=timezone.utc), 1.0)]}, deny=code),
        NOW,
    )
    assert data["api_unkeyed_daily"] is None
    assert data["devices"] == []
    assert len(data["telemetry_reports"]) == 1
    assert len(data["licenses"]) == 1
    assert any(code in r.getMessage() and "api_unkeyed_daily" in r.getMessage()
               for r in caplog.records)


def test_unkeyed_other_errors_still_fail_the_run():
    with pytest.raises(FakeClientError):
        sync.read_sources(FakeTable([]), FakeTable([]), FakeTable([]), FakeTable([]),
                          FakeCloudWatch({"/v1/x": []}, deny="Throttling"), NOW)


def test_write_mirror_upserts_unkeyed_counts_and_never_deletes_them():
    conn = _RecordingConnection()
    sync.write_mirror(conn, _mirror_data(), datetime.now(timezone.utc))
    executed = [entry[1] for entry in conn.log if entry[0] == "execute"]
    assert any("ON CONFLICT (day, route) DO UPDATE SET requests = EXCLUDED.requests" in s
               for s in executed)
    assert not any("api_unkeyed_daily" in s and ("TRUNCATE" in s or "DELETE" in s) for s in executed)


def test_write_mirror_leaves_unkeyed_untouched_when_skipped():
    conn = _RecordingConnection()
    sync.write_mirror(conn, _mirror_data(unkeyed_fetched=False), datetime.now(timezone.utc))
    executed = [entry[1] for entry in conn.log if entry[0] == "execute"]
    assert not any("ON CONFLICT (day, route)" in s for s in executed)
    assert not any("staging_api_unkeyed_daily" in s for s in executed)


def test_schema_declares_unkeyed_table_with_composite_key():
    ddl = _ddl("api_unkeyed_daily")
    assert "day" in ddl and "date" in ddl
    assert "route" in ddl and "text" in ddl
    assert "requests" in ddl and "bigint" in ddl
    assert "PRIMARY KEY (day, route)" in ddl

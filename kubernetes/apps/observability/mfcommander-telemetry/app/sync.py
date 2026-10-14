"""Copy MFCommander's DynamoDB telemetry and license tables into Postgres.

Every run scans the three source tables in full and writes them inside ONE transaction,
with two different semantics (owner decision, 2026-10-14):

* Telemetry reports and aggregates are **kept forever** here. Rows are upserted on their
  DynamoDB key and never deleted, so Postgres is a second copy that survives a row — or a
  whole table — lost in AWS. An erasure request therefore needs a manual DELETE here as
  well as in DynamoDB (see README).
* Licenses are an **exact mirror**: replaced every run, so a refund or revocation never
  leaves a stale row behind.

The licenses scan is attribute-restricted on purpose: the sync's IAM user may only Scan
`mfcommander-licenses` with Select=SPECIFIC_ATTRIBUTES over LICENSE_ATTRIBUTES.
`signed_key` is a live license credential and is never requested.

Two more sources ride along:

* `mfcommander-devices` (trials and per-Mac activations) is an exact mirror, like licenses.
* `MFCommander/API` / `UnkeyedRequests` (CloudWatch, us-east-1) gives daily request counts
  per route for the last 15 days. Those are upserted and kept, like telemetry.

A source the sync is not allowed to read yet (missing table or IAM grant) is skipped for
that run with one log line; its Postgres rows are left as they are and every other mirror
still completes.

Connection settings come from the standard libpq environment (PGHOST, PGDATABASE,
PGUSER, PGPASSWORD, ...); AWS credentials from the standard AWS environment.
"""

from __future__ import annotations

import json
import logging
import os
import sys
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import Any, Iterable, Iterator

log = logging.getLogger("mfcommander-telemetry-sync")

TELEMETRY_TABLE = os.environ.get("TELEMETRY_TABLE_NAME", "mfcommander-telemetry")
AGGREGATES_TABLE = os.environ.get("AGGREGATES_TABLE_NAME", "mfcommander-telemetry-aggregates")
LICENSES_TABLE = os.environ.get("LICENSES_TABLE_NAME", "mfcommander-licenses")
DEVICES_TABLE = os.environ.get("DEVICES_TABLE_NAME", "mfcommander-devices")
GRAFANA_ROLE = os.environ.get("GRAFANA_ROLE", "mfcommander_grafana")

METRICS_REGION = "us-east-1"
UNKEYED_NAMESPACE = "MFCommander/API"
UNKEYED_METRIC = "UnkeyedRequests"
UNKEYED_WINDOW_DAYS = 15
# CloudWatch GetMetricData takes at most 500 queries per request.
METRIC_QUERY_BATCH = 500

# Errors that mean "not readable yet" for one mirror; anything else fails the run.
DEVICES_SKIPPABLE = frozenset({"ResourceNotFoundException", "AccessDeniedException"})
UNKEYED_SKIPPABLE = frozenset({"AccessDenied", "AccessDeniedException"})

# Exactly the attributes the IAM policy allows. Never add `signed_key`.
LICENSE_ATTRIBUTES = (
    "license_id",
    "polar_order_id",
    "email",
    "customer_name",
    "tier",
    "status",
    "issued_at",
    "updates_until",
    "created_at",
    "updated_at",
    "last_validated_at",
    "revoked_at",
)
LICENSE_TIMESTAMPS = (
    "issued_at",
    "updates_until",
    "created_at",
    "updated_at",
    "last_validated_at",
    "revoked_at",
)
THROTTLE_PREFIX = "recover-throttle#"
SYNC_RUNS_RETENTION_DAYS = 90

TELEMETRY_COLUMNS = (
    "install_id",
    "day",
    "schema_version",
    "policy_version",
    "cohort_week",
    "app_version",
    "os_major",
    "arch",
    "tier",
    "trial_day",
    "active_days",
    "license_id",
    "counters",
)
AGGREGATE_COLUMNS = (
    "cohort_week",
    "month",
    "active_installations",
    "report_count",
    "active_days",
    "counter_buckets",
)
LICENSE_COLUMNS = LICENSE_ATTRIBUTES
DEVICE_COLUMNS = (
    "pk",
    "sk",
    "kind",
    "device_id",
    "license_id",
    "device_name",
    "started_at",
    "last_checked_at",
    "app_version",
    "activated_at",
    "deactivated_at",
    "over_cap",
    "unidentified",
    "last_seen_at",
    "active_count",
)
UNKEYED_COLUMNS = ("day", "route", "requests")
TELEMETRY_KEY = ("install_id", "day")
AGGREGATE_KEY = ("cohort_week", "month")
DEVICE_KEY = ("pk", "sk")
UNKEYED_KEY = ("day", "route")

SCHEMA_SQL = (
    """
    CREATE TABLE IF NOT EXISTS telemetry_reports (
        install_id      uuid        NOT NULL,
        day             date        NOT NULL,
        schema_version  smallint,
        policy_version  integer,
        cohort_week     text,
        app_version     text,
        os_major        integer,
        arch            text,
        tier            text,
        trial_day       integer,
        active_days     integer,
        license_id      text,
        counters        jsonb       NOT NULL DEFAULT '{}'::jsonb,
        PRIMARY KEY (install_id, day)
    )
    """,
    "CREATE INDEX IF NOT EXISTS telemetry_reports_day_idx ON telemetry_reports (day)",
    "CREATE INDEX IF NOT EXISTS telemetry_reports_tier_day_idx ON telemetry_reports (tier, day)",
    """
    CREATE INDEX IF NOT EXISTS telemetry_reports_license_id_idx
        ON telemetry_reports (license_id) WHERE license_id IS NOT NULL
    """,
    """
    CREATE TABLE IF NOT EXISTS telemetry_aggregates (
        cohort_week           text    NOT NULL,
        month                 date    NOT NULL,
        active_installations  bigint,
        report_count          bigint,
        active_days           bigint,
        counter_buckets       jsonb   NOT NULL DEFAULT '{}'::jsonb,
        PRIMARY KEY (cohort_week, month)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS licenses (
        license_id         text PRIMARY KEY,
        polar_order_id     text,
        email              text,
        customer_name      text,
        tier               text,
        status             text,
        issued_at          timestamptz,
        updates_until      timestamptz,
        created_at         timestamptz,
        updated_at         timestamptz,
        last_validated_at  timestamptz,
        revoked_at         timestamptz
    )
    """,
    "CREATE INDEX IF NOT EXISTS licenses_issued_at_idx ON licenses (issued_at)",
    "CREATE INDEX IF NOT EXISTS licenses_tier_status_idx ON licenses (tier, status)",
    """
    CREATE TABLE IF NOT EXISTS sync_runs (
        id                    bigserial   PRIMARY KEY,
        started_at            timestamptz NOT NULL,
        finished_at           timestamptz NOT NULL,
        telemetry_reports     integer     NOT NULL,
        telemetry_aggregates  integer     NOT NULL,
        licenses              integer     NOT NULL,
        skipped_rows          integer     NOT NULL DEFAULT 0
    )
    """,
    "CREATE INDEX IF NOT EXISTS sync_runs_finished_at_idx ON sync_runs (finished_at)",
    """
    CREATE TABLE IF NOT EXISTS devices (
        pk               text        NOT NULL,
        sk               text        NOT NULL,
        kind             text        NOT NULL,
        device_id        text,
        license_id       text,
        device_name      text,
        started_at       timestamptz,
        last_checked_at  timestamptz,
        app_version      text,
        activated_at     timestamptz,
        deactivated_at   timestamptz,
        over_cap         boolean     NOT NULL DEFAULT false,
        unidentified     boolean     NOT NULL DEFAULT false,
        last_seen_at     timestamptz,
        active_count     integer,
        PRIMARY KEY (pk, sk)
    )
    """,
    "CREATE INDEX IF NOT EXISTS devices_license_id_idx ON devices (license_id)",
    "CREATE INDEX IF NOT EXISTS devices_kind_started_at_idx ON devices (kind, started_at)",
    """
    CREATE TABLE IF NOT EXISTS api_unkeyed_daily (
        day       date    NOT NULL,
        route     text    NOT NULL,
        requests  bigint  NOT NULL,
        PRIMARY KEY (day, route)
    )
    """,
)


# --------------------------------------------------------------------------------------
# Pure conversion helpers (unit-tested; no network, no database)
# --------------------------------------------------------------------------------------


def to_int(value: Any) -> int | None:
    """DynamoDB numbers arrive from boto3 as Decimal; columns want int."""
    if value is None:
        return None
    if isinstance(value, bool):
        raise ValueError(f"boolean is not an integer: {value!r}")
    if isinstance(value, Decimal):
        if value != value.to_integral_value():
            raise ValueError(f"non-integral number: {value}")
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.strip().lstrip("-").isdigit():
        return int(value)
    raise ValueError(f"not an integer: {value!r}")


def plain(value: Any) -> Any:
    """Recursively turn boto3 values (Decimal, set) into JSON-serializable ones."""
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, dict):
        return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    if isinstance(value, (set, frozenset)):
        return sorted(plain(v) for v in value)
    return value


def to_json(value: Any) -> str:
    """A DynamoDB map as a jsonb literal; a missing map becomes an empty object."""
    return json.dumps(plain(value) if value is not None else {}, sort_keys=True)


def parse_day(value: str) -> date:
    return date.fromisoformat(value)


def parse_month(value: str) -> date:
    """`YYYY-MM` -> the first day of that month."""
    return date.fromisoformat(f"{value}-01")


def parse_timestamp(value: Any) -> datetime | None:
    """ISO-8601 string -> aware datetime (naive values are UTC). Bad input -> None."""
    if value is None or value == "":
        return None
    try:
        parsed = datetime.fromisoformat(str(value))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def telemetry_row(item: dict[str, Any]) -> tuple:
    """One `mfcommander-telemetry` item -> a `telemetry_reports` row.

    Counters keep their stored meaning: schema_version 1 rows hold range ordinals
    (0..5), schema_version 2 rows hold exact counts. Consumers tell them apart by
    `schema_version`. The legacy `ttl` attribute is ignored.
    """
    return (
        str(item["install_id"]),
        parse_day(item["day"]),
        to_int(item.get("schema_version")),
        to_int(item.get("policy_version")),
        item.get("cohort_week"),
        item.get("app_version"),
        to_int(item.get("os_major")),
        item.get("arch"),
        item.get("tier"),
        to_int(item.get("trial_day")),
        to_int(item.get("active_days")),
        item.get("license_id"),
        to_json(item.get("counters")),
    )


def aggregate_row(item: dict[str, Any]) -> tuple:
    return (
        item["cohort_week"],
        parse_month(item["month"]),
        to_int(item.get("active_installations")),
        to_int(item.get("report_count")),
        to_int(item.get("active_days")),
        to_json(item.get("counter_buckets")),
    )


def is_license_bookkeeping(item: dict[str, Any]) -> bool:
    return str(item.get("license_id", "")).startswith(THROTTLE_PREFIX)


def license_row(item: dict[str, Any]) -> tuple:
    values = []
    for column in LICENSE_COLUMNS:
        value = item.get(column)
        values.append(parse_timestamp(value) if column in LICENSE_TIMESTAMPS else value)
    return tuple(values)


def license_scan_kwargs() -> dict[str, Any]:
    """The only shape of licenses Scan the IAM policy permits."""
    names = {f"#a{i}": attribute for i, attribute in enumerate(LICENSE_ATTRIBUTES)}
    return {
        "Select": "SPECIFIC_ATTRIBUTES",
        "ProjectionExpression": ", ".join(names),
        "ExpressionAttributeNames": names,
    }


def scan_all(table: Any, **kwargs: Any) -> Iterator[dict[str, Any]]:
    """Follow LastEvaluatedKey until the table is exhausted."""
    request = dict(kwargs)
    while True:
        page = table.scan(**request)
        yield from page.get("Items", [])
        last_key = page.get("LastEvaluatedKey")
        if not last_key:
            return
        request = dict(kwargs, ExclusiveStartKey=last_key)


def device_kind(pk: str, sk: str) -> str | None:
    """Which of the four `mfcommander-devices` shapes a key pair is, or None if unknown."""
    if pk.startswith("device#") and sk == "trial":
        return "trial"
    if pk.startswith("license#"):
        if sk == "meta":
            return "meta"
        if sk.startswith("device#"):
            return "activation"
        if sk.startswith("unidentified#"):
            return "unidentified"
    return None


def device_row(item: dict[str, Any]) -> tuple:
    """One `mfcommander-devices` item -> a `devices` row, in DEVICE_COLUMNS order.

    Keys are the source of truth for `kind`. The id columns prefer an attribute the item
    carries and fall back to the key, so a trial (which has no device_id attribute) still
    gets its device id from `device#<id>`.
    """
    pk, sk = str(item["pk"]), str(item["sk"])
    kind = device_kind(pk, sk)
    if kind is None:
        raise ValueError(f"unrecognised devices key: {pk!r} / {sk!r}")
    device_id = license_id = None
    if kind == "trial":
        device_id = pk[len("device#"):]
    elif kind == "activation":
        license_id = item.get("license_id") or pk[len("license#"):]
        device_id = item.get("device_id") or sk[len("device#"):]
    elif kind in ("unidentified", "meta"):
        license_id = item.get("license_id") or pk[len("license#"):]
    return (
        pk,
        sk,
        kind,
        device_id,
        license_id,
        item.get("device_name"),
        parse_timestamp(item.get("started_at")),
        parse_timestamp(item.get("last_checked_at")),
        item.get("app_version"),
        parse_timestamp(item.get("activated_at")),
        parse_timestamp(item.get("deactivated_at")),
        item.get("over_cap") is True,
        item.get("unidentified") is True,
        parse_timestamp(item.get("last_seen_at")),
        to_int(item.get("active_count")),
    )


def error_code(error: BaseException) -> str | None:
    """The `Error.Code` of a botocore ClientError. Duck-typed: sync.py never imports botocore."""
    response = getattr(error, "response", None)
    if isinstance(response, dict):
        return (response.get("Error") or {}).get("Code")
    return None


def read_devices(table: Any) -> list[tuple] | None:
    """Scan the devices table. None means it was not readable this run (see module docs)."""
    try:
        items = list(scan_all(table))
    except Exception as error:
        code = error_code(error)
        if code in DEVICES_SKIPPABLE:
            log.warning(
                "devices mirror skipped this run (%s reading %s); existing devices rows kept",
                code, getattr(table, "table_name", DEVICES_TABLE),
            )
            return None
        raise
    rows: list[tuple] = []
    skipped = 0
    for item in items:
        if device_kind(str(item["pk"]), str(item["sk"])) is None:
            skipped += 1
            continue
        rows.append(device_row(item))
    if skipped:
        log.warning("devices mirror: skipped %d rows with unrecognised keys", skipped)
    return rows


def unkeyed_window(now: datetime) -> tuple[datetime, datetime]:
    """The last UNKEYED_WINDOW_DAYS UTC days, whole days aligned to UTC midnight.

    The end is `now`, so today's partial count is written and then corrected by later runs.
    """
    now = now.astimezone(timezone.utc)
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return midnight - timedelta(days=UNKEYED_WINDOW_DAYS - 1), now


def utc_day(value: datetime) -> date:
    aware = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    return aware.astimezone(timezone.utc).date()


def list_routes(cloudwatch: Any) -> list[str]:
    """Every distinct Route dimension of the unkeyed metric, following NextToken."""
    routes: set[str] = set()
    request: dict[str, Any] = {"Namespace": UNKEYED_NAMESPACE, "MetricName": UNKEYED_METRIC}
    while True:
        page = cloudwatch.list_metrics(**request)
        for metric in page.get("Metrics", []):
            for dimension in metric.get("Dimensions", []):
                if dimension.get("Name") == "Route":
                    routes.add(dimension["Value"])
        token = page.get("NextToken")
        if not token:
            return sorted(routes)
        request = dict(request, NextToken=token)


def fetch_unkeyed_daily(cloudwatch: Any, now: datetime) -> list[tuple]:
    """Daily Sum of UnkeyedRequests per route over the window, as (day, route, requests).

    Keyed by (day, route) before returning, so one INSERT never carries a duplicate key.
    """
    routes = list_routes(cloudwatch)
    if not routes:
        return []
    start, end = unkeyed_window(now)
    queries = [
        {
            "Id": f"r{index}",
            "MetricStat": {
                "Metric": {
                    "Namespace": UNKEYED_NAMESPACE,
                    "MetricName": UNKEYED_METRIC,
                    "Dimensions": [{"Name": "Route", "Value": route}],
                },
                "Period": 86400,
                "Stat": "Sum",
            },
            "ReturnData": True,
        }
        for index, route in enumerate(routes)
    ]
    route_of = {f"r{index}": route for index, route in enumerate(routes)}
    counts: dict[tuple[date, str], int] = {}
    for offset in range(0, len(queries), METRIC_QUERY_BATCH):
        request: dict[str, Any] = {
            "MetricDataQueries": queries[offset:offset + METRIC_QUERY_BATCH],
            "StartTime": start,
            "EndTime": end,
            "ScanBy": "TimestampAscending",
        }
        while True:
            page = cloudwatch.get_metric_data(**request)
            for result in page.get("MetricDataResults", []):
                route = route_of[result["Id"]]
                for at, value in zip(result["Timestamps"], result["Values"]):
                    counts[(utc_day(at), route)] = int(round(value))
            token = page.get("NextToken")
            if not token:
                break
            request = dict(request, NextToken=token)
    return [(day, route, requests) for (day, route), requests in sorted(counts.items())]


def read_unkeyed(cloudwatch: Any, now: datetime) -> list[tuple] | None:
    """None means CloudWatch denied the read this run (see module docs)."""
    try:
        return fetch_unkeyed_daily(cloudwatch, now)
    except Exception as error:
        code = error_code(error)
        if code in UNKEYED_SKIPPABLE:
            log.warning(
                "api_unkeyed_daily skipped this run (%s reading %s); existing rows kept",
                code, UNKEYED_METRIC,
            )
            return None
        raise


def read_sources(telemetry: Any, aggregates: Any, licenses: Any, devices: Any,
                 cloudwatch: Any, now: datetime | None = None) -> dict[str, Any]:
    """Read every source and convert it. A skipped source comes back as None."""
    license_rows: list[tuple] = []
    skipped = 0
    for item in scan_all(licenses, **license_scan_kwargs()):
        if is_license_bookkeeping(item):
            skipped += 1
            continue
        license_rows.append(license_row(item))
    return {
        "telemetry_reports": [telemetry_row(i) for i in scan_all(telemetry)],
        "telemetry_aggregates": [aggregate_row(i) for i in scan_all(aggregates)],
        "licenses": license_rows,
        "skipped_rows": skipped,
        "devices": read_devices(devices),
        "api_unkeyed_daily": read_unkeyed(cloudwatch, now or datetime.now(timezone.utc)),
    }


# --------------------------------------------------------------------------------------
# Database side
# --------------------------------------------------------------------------------------


def _copy_rows(cursor: Any, table: str, columns: Iterable[str], rows: list[tuple]) -> None:
    from psycopg import sql

    statement = sql.SQL("COPY {} ({}) FROM STDIN").format(
        sql.Identifier(table), sql.SQL(", ").join(sql.Identifier(c) for c in columns)
    )
    with cursor.copy(statement) as copy:
        for row in rows:
            copy.write_row(row)


def upsert_statement(table: str, columns: Iterable[str], key: Iterable[str]) -> str:
    """INSERT from the run's staging table, overwriting a row DynamoDB changed.

    Names are module constants, never input, so plain interpolation is safe here."""
    columns, key = tuple(columns), tuple(key)
    listed = ", ".join(columns)
    updates = ", ".join(f"{c} = EXCLUDED.{c}" for c in columns if c not in key)
    return (
        f"INSERT INTO {table} ({listed}) SELECT {listed} FROM staging_{table} "
        f"ON CONFLICT ({', '.join(key)}) DO UPDATE SET {updates}"
    )


def _upsert_rows(cursor: Any, table: str, columns: Iterable[str], key: Iterable[str],
                 rows: list[tuple]) -> None:
    cursor.execute(
        f"CREATE TEMP TABLE staging_{table} (LIKE {table} INCLUDING DEFAULTS) ON COMMIT DROP"
    )
    _copy_rows(cursor, f"staging_{table}", columns, rows)
    cursor.execute(upsert_statement(table, columns, key))


def write_mirror(conn: Any, data: dict[str, Any], started_at: datetime) -> dict[str, int]:
    """Upsert telemetry, replace licenses, and record the run, inside ONE transaction."""
    from psycopg import sql

    counts = {
        "telemetry_reports": len(data["telemetry_reports"]),
        "telemetry_aggregates": len(data["telemetry_aggregates"]),
        "licenses": len(data["licenses"]),
        "skipped_rows": data["skipped_rows"],
        # None = that source was skipped this run (its rows were left untouched).
        "devices": None if data["devices"] is None else len(data["devices"]),
        "api_unkeyed_daily": (None if data["api_unkeyed_daily"] is None
                              else len(data["api_unkeyed_daily"])),
    }
    grafana = sql.Identifier(GRAFANA_ROLE)
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute("SET LOCAL lock_timeout = '60s'")
            for statement in SCHEMA_SQL:
                cur.execute(statement)
            _upsert_rows(cur, "telemetry_reports", TELEMETRY_COLUMNS, TELEMETRY_KEY,
                         data["telemetry_reports"])
            _upsert_rows(cur, "telemetry_aggregates", AGGREGATE_COLUMNS, AGGREGATE_KEY,
                         data["telemetry_aggregates"])
            cur.execute("TRUNCATE licenses")
            _copy_rows(cur, "licenses", LICENSE_COLUMNS, data["licenses"])
            if data["devices"] is not None:
                cur.execute("TRUNCATE devices")
                _copy_rows(cur, "devices", DEVICE_COLUMNS, data["devices"])
            if data["api_unkeyed_daily"] is not None:
                _upsert_rows(cur, "api_unkeyed_daily", UNKEYED_COLUMNS, UNKEYED_KEY,
                             data["api_unkeyed_daily"])
            cur.execute(
                "DELETE FROM sync_runs WHERE started_at < now() - make_interval(days => %s)",
                (SYNC_RUNS_RETENTION_DAYS,),
            )
            cur.execute(
                """
                INSERT INTO sync_runs (started_at, finished_at, telemetry_reports,
                                       telemetry_aggregates, licenses, skipped_rows)
                VALUES (%s, clock_timestamp(), %s, %s, %s, %s)
                """,
                (
                    started_at,
                    counts["telemetry_reports"],
                    counts["telemetry_aggregates"],
                    counts["licenses"],
                    counts["skipped_rows"],
                ),
            )
            # Grafana reads through its own SELECT-only role. Only this database's
            # owner and the Grafana role may connect (PUBLIC has CONNECT by default).
            database = sql.Identifier(conn.info.dbname)
            cur.execute(sql.SQL("REVOKE CONNECT ON DATABASE {} FROM PUBLIC").format(database))
            cur.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(database, grafana))
            cur.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(grafana))
            cur.execute(sql.SQL("GRANT SELECT ON ALL TABLES IN SCHEMA public TO {}").format(grafana))
            cur.execute(
                sql.SQL(
                    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO {}"
                ).format(grafana)
            )
    return counts


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s"
    )
    import boto3
    import psycopg

    started_at = datetime.now(timezone.utc)
    dynamodb = boto3.resource("dynamodb")
    cloudwatch = boto3.client("cloudwatch", region_name=METRICS_REGION)
    data = read_sources(
        dynamodb.Table(TELEMETRY_TABLE),
        dynamodb.Table(AGGREGATES_TABLE),
        dynamodb.Table(LICENSES_TABLE),
        dynamodb.Table(DEVICES_TABLE),
        cloudwatch,
        started_at,
    )
    # Empty conninfo: libpq reads PGHOST/PGDATABASE/PGUSER/PGPASSWORD/PGSSLMODE.
    with psycopg.connect("", application_name="mfcommander-telemetry-sync") as conn:
        counts = write_mirror(conn, data, started_at)
    elapsed = (datetime.now(timezone.utc) - started_at).total_seconds()
    log.info("sync complete %s", json.dumps({**counts, "seconds": round(elapsed, 2)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())

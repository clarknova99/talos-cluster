#!/usr/bin/env python3
"""
Generate CPU/memory limit suggestions for Deployments based on historical Prometheus data.

Requires:
- Access to the Kubernetes API via kubectl in the current context.
- Prometheus HTTP API endpoint (no extra Python dependencies needed).

Output columns:
- Deployment/Container: namespace/name/container.
- CPU req / Mem req: current requests from the deployment spec (or "-" if none).
- CPU lim / Mem lim: current limits from the deployment spec (or "-" if none).
- CPU rec / Mem rec: recommended limits using the chosen quantile * headroom, rounded.
- Details: quantile/window/headroom used for the recommendation.

Example:
  ./scripts/recommend-resources.py \
    --prom-url http://prometheus.example.svc:9090 \
    --namespace default \
    --window 24h \
    --quantile 0.95 \
    --headroom 1.2
"""

import argparse
import json
import math
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from typing import Dict, Iterable, List, Optional, Tuple


def parse_duration(value: str) -> int:
    """Parse simple Prometheus-style durations (s, m, h, d)."""
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    try:
        suffix = value[-1]
        if suffix.isdigit():
            return int(value)
        return int(float(value[:-1]) * units[suffix])
    except Exception as exc:
        raise argparse.ArgumentTypeError(f"Invalid duration: {value}") from exc


def parse_cpu(value: str) -> float:
    """Return CPU cores from values like 250m or 0.25."""
    if value.endswith("m"):
        return float(value[:-1]) / 1000.0
    return float(value)


def parse_memory(value: str) -> float:
    """Return bytes from values like 256Mi, 1Gi, or raw bytes."""
    factors = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3}
    for suffix, mul in factors.items():
        if value.endswith(suffix):
            return float(value[:-len(suffix)]) * mul
    return float(value)


def run_kubectl(args: List[str]) -> dict:
    cmd = ["kubectl"] + args
    try:
        out = subprocess.check_output(cmd, text=True)
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(f"kubectl failed: {' '.join(cmd)}\n{exc}\n")
        raise
    return json.loads(out)


def build_rs_to_deploy() -> Dict[Tuple[str, str], Tuple[str, str]]:
    """Map ReplicaSets to their owning Deployments."""
    data = run_kubectl(["get", "rs", "-A", "-o", "json"])
    mapping: Dict[Tuple[str, str], Tuple[str, str]] = {}
    for item in data.get("items", []):
        ns = item["metadata"]["namespace"]
        rs_name = item["metadata"]["name"]
        for owner in item.get("metadata", {}).get("ownerReferences", []):
            if owner.get("kind") == "Deployment":
                mapping[(ns, rs_name)] = (ns, owner["name"])
    return mapping


def list_deployments(namespaces: Optional[Iterable[str]]) -> List[dict]:
    if namespaces:
        args = ["get", "deploy"]
        for ns in namespaces:
            args.extend(["-n", ns])
    else:
        args = ["get", "deploy", "-A"]
    args.extend(["-o", "json"])
    return run_kubectl(args)


def build_deploy_resources(namespaces: Optional[Iterable[str]]) -> Dict[Tuple[str, str, str], Dict[str, Optional[str]]]:
    """Map (ns, deploy, container) to current requests/limits."""
    data = list_deployments(namespaces)
    result: Dict[Tuple[str, str, str], Dict[str, Optional[str]]] = {}
    for item in data.get("items", []):
        ns = item["metadata"]["namespace"]
        name = item["metadata"]["name"]
        for c in item.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []):
            cname = c.get("name")
            if not cname:
                continue
            resources = c.get("resources", {})
            req = resources.get("requests", {}) if isinstance(resources, dict) else {}
            lim = resources.get("limits", {}) if isinstance(resources, dict) else {}
            result[(ns, name, cname)] = {
                "cpu_req": req.get("cpu"),
                "mem_req": req.get("memory"),
                "cpu_lim": lim.get("cpu"),
                "mem_lim": lim.get("memory"),
            }
    return result


def list_pods(namespaces: Optional[Iterable[str]]) -> List[dict]:
    if namespaces:
        args = ["get", "pods"]
        for ns in namespaces:
            args.extend(["-n", ns])
    else:
        args = ["get", "pods", "-A"]
    args.extend(["-o", "json"])
    return run_kubectl(args)


def percentile(values: List[float], q: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    k = (len(values) - 1) * q
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return values[int(k)]
    return values[f] + (values[c] - values[f]) * (k - f)


def prom_range(
    base_url: str,
    query: str,
    start: float,
    end: float,
    step: int,
    bearer_token: Optional[str] = None,
) -> List[float]:
    params = {
        "query": query,
        "start": f"{start:.0f}",
        "end": f"{end:.0f}",
        "step": str(step),
    }
    url = f"{base_url.rstrip('/')}/api/v1/query_range?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url)
    if bearer_token:
        req.add_header("Authorization", f"Bearer {bearer_token}")
    with urllib.request.urlopen(req) as resp:  # noqa: S310
        body = json.loads(resp.read())
    if body.get("status") != "success":
        raise RuntimeError(f"Prometheus query failed: {body}")
    samples: List[float] = []
    for result in body.get("data", {}).get("result", []):
        for _, value in result.get("values", []):
            samples.append(float(value))
    return samples


def format_cpu(cores: float) -> str:
    # round up to the nearest 10m
    milli = math.ceil(cores * 1000 / 10) * 10
    return f"{int(milli)}m"


def format_mem(bytes_val: float) -> str:
    mib = bytes_val / (1024 * 1024)
    # round up to nearest MiB
    return f"{int(math.ceil(mib))}Mi"


def pad(value: str, width: int) -> str:
    return value.ljust(width)[:width]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prom-url", required=True, help="Prometheus base URL (no trailing /api)")
    parser.add_argument("--namespace", action="append", help="Limit to namespaces (repeatable)")
    parser.add_argument("--window", default="24h", type=parse_duration, help="Lookback window (default 24h)")
    parser.add_argument("--step", default="5m", type=parse_duration, help="Prometheus step (default 5m)")
    parser.add_argument("--quantile", default=0.95, type=float, help="Usage quantile to target (default 0.95)")
    parser.add_argument("--headroom", default=1.2, type=float, help="Multiplier on usage to set limits (default 1.2)")
    parser.add_argument("--bearer-token-file", help="Path to bearer token for Prometheus, if needed")
    parser.add_argument("--min-cpu", default="10m", help="Minimum CPU limit to report (cores or Xm)")
    parser.add_argument("--min-memory", default="32Mi", help="Minimum memory limit to report (bytes or XMi/XGi)")
    args = parser.parse_args()

    bearer_token = None
    if args.bearer_token_file:
        with open(args.bearer_token_file, "r", encoding="utf-8") as fh:
            bearer_token = fh.read().strip()

    now = time.time()
    start = now - args.window
    min_cpu = parse_cpu(args.min_cpu)
    min_mem = parse_memory(args.min_memory)

    rs_map = build_rs_to_deploy()
    deploy_resources = build_deploy_resources(args.namespace)
    pods_data = list_pods(args.namespace)

    deployments: Dict[Tuple[str, str], Dict[str, List[str]]] = {}
    for item in pods_data.get("items", []):
        ns = item["metadata"]["namespace"]
        pod_name = item["metadata"]["name"]
        owner = None
        for ref in item.get("metadata", {}).get("ownerReferences", []):
            if ref.get("kind") == "ReplicaSet":
                owner = (ns, ref["name"])
                break
        if not owner or owner not in rs_map:
            continue
        deploy = rs_map[owner]
        containers = [
            c["name"] for c in item.get("spec", {}).get("containers", [])
            if c.get("name")
        ]
        if not containers:
            continue
        deployments.setdefault(deploy, {})
        for container in containers:
            deployments[deploy].setdefault(container, []).append((ns, pod_name))

    if not deployments:
        sys.stderr.write("No deployments found from pods/replicasets\n")
        sys.exit(1)

    columns = [
        ("Deployment/Container", 40),
        ("CPU req", 10),
        ("Mem req", 10),
        ("CPU lim", 10),
        ("Mem lim", 10),
        ("CPU rec", 10),
        ("Mem rec", 10),
        ("Details", 28),
    ]
    header = "  ".join(pad(name, width) for name, width in columns)
    print(header)
    for (ns, deploy), containers in sorted(deployments.items()):
        for container, pod_refs in containers.items():
            pod_filter = "|".join({p for _, p in pod_refs})
            cpu_query = (
                f"sum(rate(container_cpu_usage_seconds_total{{namespace=\"{ns}\","
                f"pod=~\"{pod_filter}\",container=\"{container}\"}}[5m]))"
            )
            mem_query = (
                f"avg(container_memory_working_set_bytes{{namespace=\"{ns}\","
                f"pod=~\"{pod_filter}\",container=\"{container}\"}})"
            )
            cpu_samples = prom_range(
                args.prom_url, cpu_query, start, now, args.step, bearer_token
            )
            mem_samples = prom_range(
                args.prom_url, mem_query, start, now, args.step, bearer_token
            )
            cpu_q = percentile(cpu_samples, args.quantile)
            mem_q = percentile(mem_samples, args.quantile)
            cpu_rec = max(cpu_q * args.headroom, min_cpu)
            mem_rec = max(mem_q * args.headroom, min_mem)

            res = deploy_resources.get((ns, deploy, container), {})
            cpu_req = res.get("cpu_req") or "-"
            mem_req = res.get("mem_req") or "-"
            cpu_lim = res.get("cpu_lim") or "-"
            mem_lim = res.get("mem_lim") or "-"
            details = f"p{int(args.quantile*100)} over {args.window}s @ {args.headroom}x"

            row = [
                f"{ns}/{deploy}/{container}",
                cpu_req,
                mem_req,
                cpu_lim,
                mem_lim,
                format_cpu(cpu_rec),
                format_mem(mem_rec),
                details,
            ]
            print("  ".join(pad(str(val), width) for val, (_, width) in zip(row, columns)))


if __name__ == "__main__":
    main()

"""sensei DR orchestrator Lambda. Runs every minute (EventBridge) and on demand from dr/bin/drctl.

Invoke payloads:
  {}                                   scheduled tick
  {"request": "<action>", "reason": ""} operator request (see logic.decide)
  {"status": true}                     return items without acting
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from decimal import Decimal

import boto3

from logic import Config, decide

TABLE = os.environ["TABLE"]
ASG_NAME = os.environ["ASG_NAME"]
TOPIC_ARN = os.environ["TOPIC_ARN"]
CF_SECRET = os.environ["CF_SECRET"]
DOMAIN = os.environ["DOMAIN"]
PROBE_URL = os.environ.get("PROBE_URL", f"https://{DOMAIN}/health")
FAILOVER_HOSTS = json.loads(os.environ["FAILOVER_HOSTS"])
DRILL_HOST = os.environ["DRILL_HOST"]
CFG = Config(
    heartbeat_timeout=int(os.environ.get("HEARTBEAT_TIMEOUT", "300")),
    probe_failures_needed=int(os.environ.get("PROBE_FAILURES", "3")),
    ready_timeout=int(os.environ.get("READY_TIMEOUT", "5400")),
)
DR_OWNER = "sensei-dr"

ddb = boto3.resource("dynamodb").Table(TABLE)
asg = boto3.client("autoscaling")
sns = boto3.client("sns")
secrets = boto3.client("secretsmanager")
_cf_cache: dict | None = None


def plain(v):
    if isinstance(v, Decimal):
        return int(v) if v == int(v) else float(v)
    if isinstance(v, dict):
        return {k: plain(x) for k, x in v.items()}
    if isinstance(v, list):
        return [plain(x) for x in v]
    return v


def get_item(pk: str) -> dict:
    return plain(ddb.get_item(Key={"pk": pk}, ConsistentRead=True).get("Item") or {"pk": pk})


# ---- Cloudflare -------------------------------------------------------------------------------
class Cloudflare:
    def __init__(self, cfg: dict):
        self.token = cfg["apiToken"]
        self.zone = cfg["zoneId"]
        self.target = f"{cfg['tunnelId']}.cfargotunnel.com"

    def _req(self, method: str, path: str, body: dict | None = None):
        req = urllib.request.Request(
            f"https://api.cloudflare.com/client/v4/zones/{self.zone}{path}",
            method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.loads(r.read())
        if not data.get("success"):
            raise RuntimeError(f"cloudflare {method} {path}: {data.get('errors')}")
        return data["result"]

    def find(self, name: str, rtype: str) -> list[dict]:
        return self._req("GET", f"/dns_records?type={rtype}&name={name}&per_page=50")

    def patch(self, rid: str, body: dict):
        return self._req("PATCH", f"/dns_records/{rid}", body)

    def create(self, body: dict):
        return self._req("POST", "/dns_records", body)

    def delete(self, rid: str):
        return self._req("DELETE", f"/dns_records/{rid}")


def cloudflare() -> Cloudflare:
    global _cf_cache
    if _cf_cache is None:
        _cf_cache = json.loads(secrets.get_secret_value(SecretId=CF_SECRET)["SecretString"])
    return Cloudflare(_cf_cache)


def fqdn(host: str) -> str:
    return DOMAIN if host == "@" else f"{host}.{DOMAIN}"


def dns_snapshot(cf: Cloudflare) -> dict:
    """Current CNAMEs + external-dns ownership TXT records for the failover hosts."""
    snap = {}
    for host in FAILOVER_HOSTS:
        name = fqdn(host)
        recs = cf.find(name, "CNAME")
        snap[f"CNAME:{name}"] = ({"id": recs[0]["id"], "content": recs[0]["content"], "proxied": recs[0]["proxied"]}
                                 if recs else {"absent": True})
        if host == "@":
            continue
        for txt in (f"k8s.{host}.{DOMAIN}", f"k8s.cname-{host}.{DOMAIN}"):
            for r in cf.find(txt, "TXT"):
                if "external-dns/owner=" in r["content"]:
                    snap[f"TXT:{txt}:{r['id']}"] = {"id": r["id"], "content": r["content"]}
    return snap


def dns_failover(cf: Cloudflare, snap: dict) -> None:
    for key, rec in snap.items():
        kind, name = key.split(":")[0], key.split(":")[1]
        if kind == "CNAME":
            if rec.get("absent"):
                if not cf.find(name, "CNAME"):
                    cf.create({"type": "CNAME", "name": name, "content": cf.target, "proxied": True,
                               "comment": "sensei-dr failover"})
            elif rec["content"] != cf.target:
                cf.patch(rec["id"], {"content": cf.target, "proxied": True})
        else:  # take external-dns ownership so home external-dns leaves the record alone
            content = rec["content"]
            if "external-dns/owner=" in content and f"owner={DR_OWNER}" not in content:
                start = content.index("external-dns/owner=") + len("external-dns/owner=")
                end = start
                while end < len(content) and content[end] not in ',"':
                    end += 1
                cf.patch(rec["id"], {"content": content[:start] + DR_OWNER + content[end:]})


def dns_restore(cf: Cloudflare, snap: dict) -> None:
    for key, rec in snap.items():
        kind, name = key.split(":")[0], key.split(":")[1]
        if kind == "CNAME" and rec.get("absent"):
            for r in cf.find(name, "CNAME"):
                if r["content"] == cf.target:
                    cf.delete(r["id"])
        elif kind == "CNAME":
            cf.patch(rec["id"], {"content": rec["content"], "proxied": rec["proxied"]})
        else:
            cf.patch(rec["id"], {"content": rec["content"]})


def dns_drill(cf: Cloudflare, add: bool) -> None:
    name = fqdn(DRILL_HOST)
    existing = cf.find(name, "CNAME")
    if add and not existing:
        cf.create({"type": "CNAME", "name": name, "content": cf.target, "proxied": True, "comment": "sensei-dr drill"})
    elif not add:
        for r in existing:
            if r["content"] == cf.target:
                cf.delete(r["id"])


def dns_targets(cf: Cloudflare) -> dict:
    out = {}
    for host in FAILOVER_HOSTS + [DRILL_HOST]:
        recs = cf.find(fqdn(host), "CNAME")
        out[fqdn(host)] = recs[0]["content"] if recs else None
    return out


# ---- probe / misc -----------------------------------------------------------------------------
def probe_site() -> bool:
    """True unless the origin is clearly unreachable. Cloudflare answers 530 (tunnel down) or other
    5xx when home is offline; 2xx-4xx (including bot challenges) count as up."""
    req = urllib.request.Request(PROBE_URL, headers={"User-Agent": "sensei-dr-probe/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status < 500
    except urllib.error.HTTPError as e:
        return e.code < 500
    except Exception:
        return False


def set_asg(desired: int) -> None:
    groups = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])["AutoScalingGroups"]
    if groups and groups[0]["DesiredCapacity"] != desired:
        asg.set_desired_capacity(AutoScalingGroupName=ASG_NAME, DesiredCapacity=desired, HonorCooldown=False)


def acquire_lock(now: int, wait: int) -> bool:
    deadline = time.time() + wait
    while True:
        try:
            ddb.put_item(Item={"pk": "lock", "until": now + 55},
                         ConditionExpression="attribute_not_exists(pk) OR #u < :now",
                         ExpressionAttributeNames={"#u": "until"}, ExpressionAttributeValues={":now": int(time.time())})
            return True
        except ddb.meta.client.exceptions.ConditionalCheckFailedException:
            if time.time() > deadline:
                return False
            time.sleep(2)


def handler(event, _context):
    event = event or {}
    if event.get("status"):
        out = {"dr": get_item("dr"), "home": get_item("home"), "instance": get_item("instance")}
        if event.get("dns"):
            out["dns"] = dns_targets(cloudflare())
        return out

    now = int(time.time())
    request = event.get("request")
    if not acquire_lock(now, wait=25 if request else 0):
        return {"skipped": "locked"}
    try:
        dr, home, instance = get_item("dr"), get_item("home"), get_item("instance")
        probe_result = {}

        def probe():
            probe_result["up"] = probe_site()
            return probe_result["up"]

        new_dr, eff = decide(now, dr, home, instance, CFG, request=request, probe=probe,
                             manual_reason=event.get("reason", ""))
        if probe_result:
            new_dr["lastProbe"] = {"at": now, "up": probe_result["up"]}

        if eff.home:
            expr = "SET " + ", ".join(f"#{k} = :{k}" for k in eff.home)
            ddb.update_item(Key={"pk": "home"}, UpdateExpression=expr,
                            ExpressionAttributeNames={f"#{k}": k for k in eff.home},
                            ExpressionAttributeValues={f":{k}": v for k, v in eff.home.items()})

        if eff.dns:
            cf = cloudflare()
            for op in eff.dns:
                if op == "failover":
                    if not new_dr.get("dnsSnapshot"):
                        new_dr["dnsSnapshot"] = dns_snapshot(cf)
                        # persist the snapshot before touching any record
                        ddb.update_item(Key={"pk": "dr"}, UpdateExpression="SET dnsSnapshot = :s",
                                        ExpressionAttributeValues={":s": new_dr["dnsSnapshot"]})
                    dns_failover(cf, new_dr["dnsSnapshot"])
                elif op == "restore":
                    dns_restore(cf, dr.get("dnsSnapshot") or {})
                elif op in ("drill-add", "drill-remove"):
                    dns_drill(cf, op == "drill-add")

        if eff.asg is not None:
            set_asg(eff.asg)
        if eff.clear_instance:
            ddb.delete_item(Key={"pk": "instance"})
        new_dr["pk"] = "dr"
        new_dr["updatedAt"] = now
        ddb.put_item(Item=json.loads(json.dumps(new_dr), parse_float=Decimal))

        for subject, body in eff.notify:
            sns.publish(TopicArn=TOPIC_ARN, Subject=subject[:100], Message=body)
        return {"state": new_dr["state"], "armed": new_dr.get("armed"), "desiredMode": new_dr.get("desiredMode"),
                "runId": new_dr.get("runId"), "asg": eff.asg, "dns": eff.dns, "notified": [s for s, _ in eff.notify]}
    finally:
        ddb.delete_item(Key={"pk": "lock"})

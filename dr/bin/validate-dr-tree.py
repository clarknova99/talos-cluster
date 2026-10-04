#!/usr/bin/env python3
"""Offline validation of the DR Flux tree (kubernetes/dr/aws).

Emulates what kustomize-controller does for every Flux Kustomization in kubernetes/dr/aws/apps:
substitute dr-vars into the Kustomization, kustomize-build its path with its components and
patches, then substitute cluster-secrets vars. Fails on build errors, unresolved variables and a
few DR invariants (no clickhouse-backup `watch`, no VolSync, mode-driven replicas applied).

Usage: dr/bin/validate-dr-tree.py [--mode drill|failover|maintenance]
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
APPS = os.path.join(ROOT, "kubernetes/dr/aws/apps")

# Mirrors MODES in dr/cdk/assets/instance/dr-agent.sh
MODES = {
    "drill": dict(DR_APP_REPLICAS=1, DR_API_REPLICAS=2, DR_ADMIN_REPLICAS=1, DR_WORKER_REPLICAS=0, DR_DITTOFEED_REPLICAS=0, DR_CRON_SUSPEND="true"),
    "failover": dict(DR_APP_REPLICAS=1, DR_API_REPLICAS=2, DR_ADMIN_REPLICAS=1, DR_WORKER_REPLICAS=2, DR_DITTOFEED_REPLICAS=1, DR_CRON_SUSPEND="false"),
    "maintenance": dict(DR_APP_REPLICAS=0, DR_API_REPLICAS=0, DR_ADMIN_REPLICAS=0, DR_WORKER_REPLICAS=0, DR_DITTOFEED_REPLICAS=0, DR_CRON_SUSPEND="true"),
}
VAR_RE = re.compile(r"(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def subst(text, values, strict_prefix=None):
    def repl(m):
        name = m.group(1)
        if name in values:
            return str(values[name])
        if strict_prefix and name.startswith(strict_prefix):
            raise SystemExit(f"unresolved {name}")
        return m.group(0)
    return VAR_RE.sub(repl, text)


def unescape(text):
    return text.replace("$${", "${")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="failover", choices=MODES)
    args = ap.parse_args()
    dr_vars = dict(MODES[args.mode], DR_SOURCE_SERVER="postgres16vector-v4", DR_TARGET_SERVER="postgres16vector-dr-test")

    # Key names are plaintext in sops files, so no decryption is needed.
    def keys(rel):
        p = os.path.join(ROOT, rel)
        return set((yaml.safe_load(open(p)).get("stringData") or {}).keys()) if os.path.exists(p) else set()
    secret_keys = keys("kubernetes/dr/aws/secrets/cluster-secrets.sops.yaml")
    home_keys = keys("kubernetes/components/sops/cluster-secrets.sops.yaml")

    failures = 0
    tmp_root = tempfile.mkdtemp(dir=ROOT, prefix=".dr-validate-")
    try:
        for fn in sorted(os.listdir(APPS)):
            if fn == "kustomization.yaml" or not fn.endswith(".yaml"):
                continue
            raw = unescape(subst(open(os.path.join(APPS, fn)).read(), dr_vars))
            for ks in yaml.safe_load_all(raw):
                if not ks:
                    continue
                name, spec = ks["metadata"]["name"], ks["spec"]
                path = os.path.normpath(os.path.join(ROOT, spec["path"]))
                work = os.path.join(tmp_root, name)
                os.makedirs(work)
                kz = {"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
                      "resources": [os.path.relpath(path, work)]}
                if spec.get("targetNamespace"):
                    kz["namespace"] = spec["targetNamespace"]
                if spec.get("components"):
                    kz["components"] = [os.path.relpath(os.path.normpath(os.path.join(path, c)), work) for c in spec["components"]]
                if spec.get("patches"):
                    kz["patches"] = spec["patches"]
                with open(os.path.join(work, "kustomization.yaml"), "w") as f:
                    yaml.safe_dump(kz, f)
                res = subprocess.run(["kustomize", "build", "--load-restrictor", "LoadRestrictionsNone", work],
                                     capture_output=True, text=True)
                if res.returncode != 0:
                    print(f"FAIL {name}: {res.stderr.strip()}")
                    failures += 1
                    continue
                out = res.stdout
                problems = []
                if spec.get("postBuild"):
                    out = subst(out, dr_vars)
                    for var in sorted(set(VAR_RE.findall(out))):
                        # Vars missing from the home secrets render empty at home too; only flag drift.
                        if secret_keys and var in home_keys and var not in secret_keys:
                            problems.append(f"${{{var}}} missing from DR cluster-secrets (run dr/bin/build-dr-secrets.sh)")
                        if var.startswith("DR_"):
                            problems.append(f"${{{var}}} unresolved")
                    out = unescape(out)
                docs = [d for d in yaml.safe_load_all(out) if d]
                kinds = [d["kind"] for d in docs]
                if "ReplicationSource" in kinds:
                    problems.append("VolSync ReplicationSource still present")
                if "- watch" in out and "clickhouse-backup" in out:
                    problems.append("clickhouse-backup still runs `watch`")
                for d in docs:
                    if d["kind"] == "HelmRelease":
                        for cname, c in (d["spec"].get("values", {}).get("controllers") or {}).items():
                            r = c.get("replicas")
                            if isinstance(r, str):
                                problems.append(f"{cname} replicas is a string: {r!r}")
                    if d["kind"] == "CronJob" and name == "sensei-prod-api":
                        if d["spec"].get("suspend") is not (dr_vars["DR_CRON_SUSPEND"] == "true"):
                            problems.append(f"CronJob {d['metadata']['name']} suspend not applied")
                status = "FAIL" if problems else "ok  "
                failures += bool(problems)
                print(f"{status} {name:24s} {len(docs):3d} objects  {', '.join(problems)}")
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)
    if not secret_keys:
        print("note: DR cluster-secrets not generated yet; variable coverage not checked")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()

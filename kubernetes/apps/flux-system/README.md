# Flux GitOps System

This cluster uses [Flux](https://fluxcd.io/) via the **Flux Operator** pattern to continuously reconcile Kubernetes state from this Git repository. Changes pushed to `main` are automatically applied to the cluster.

## Architecture Overview

```
GitHub repo (main branch)
  └── kubernetes/
       ├── flux/                          # Flux infrastructure (bootstrapped first)
       │    ├── cluster/ks.yaml           # Root "cluster-apps" Kustomization
       │    └── repositories/             # HelmRepository and OCIRepository sources
       ├── components/
       │    ├── sops/                     # SOPS-encrypted cluster-secrets (${SECRET_*} variables)
       │    └── volsync/                  # VolSync replication templates
       └── apps/                          # All application workloads
            ├── flux-system/              # Flux Operator + Flux Instance (you are here)
            ├── kube-system/
            ├── database/
            ├── sensei/
            └── ...
```

## How It Works

### 1. Flux Operator + Flux Instance

Flux is deployed in two layers:

- **Flux Operator** (`flux-operator/`) installs the Flux controllers via an OCI Helm chart.
- **Flux Instance** (`flux-instance/`) configures those controllers to sync from `https://github.com/clarknova99/talos-cluster.git`, starting at `kubernetes/flux/cluster`.

The instance deploys four Flux controllers: `source-controller`, `kustomize-controller`, `helm-controller`, and `notification-controller`.

### 2. The Reconciliation Chain

```
GitRepository "flux-system"  (watches the repo)
  └── Kustomization "cluster-apps"  (kubernetes/flux/cluster/ks.yaml)
        └── reads kubernetes/apps/
              └── discovers child Kustomizations (ks.yaml files in each app directory)
                    └── each child reconciles a HelmRelease or raw manifests
```

1. The `flux-system` GitRepository polls the GitHub repo (or receives push events via webhook).
2. The **cluster-apps** Kustomization (`kubernetes/flux/cluster/ks.yaml`) reconciles everything under `kubernetes/apps/`.
3. Each app directory contains a `ks.yaml` defining a Flux Kustomization that points to its own `app/` subdirectory.
4. Inside `app/`, a `helmrelease.yaml` (or raw manifests) defines the actual workload.

### 3. Variable Substitution

The cluster-apps Kustomization patches **all child Kustomizations** with:

```yaml
postBuild:
  substituteFrom:
    - kind: Secret
      name: cluster-secrets          # kubernetes/components/sops/cluster-secrets.sops.yaml
```

This is why `${SECRET_DOMAIN}`, `${SECRET_CLICKHOUSE_PASSWORD}`, etc. work in any HelmRelease across the cluster. The substitution happens at the **Kustomize controller** level when applying manifests -- not in the YAML files themselves.

The `cluster-secrets` Secret is SOPS-encrypted and included as a Kustomize Component from `kubernetes/components/sops/` by `kubernetes/apps/flux-system/kustomization.yaml`.

### 4. SOPS Decryption

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) using `age` keys. The cluster-apps Kustomization enables decryption:

```yaml
decryption:
  provider: sops
```

Encrypted files (`.sops.yaml`) are decrypted at apply time by the kustomize-controller, which has the `sops-age` secret mounted. The SOPS component is included from `kubernetes/components/sops/`.

### 5. HelmRelease Defaults

The cluster-apps Kustomization also patches all child HelmReleases with consistent install/upgrade/rollback behavior:

- `install.crds: CreateReplace` with `RetryOnFailure` strategy
- `upgrade.cleanupOnFail: true` with `RemediateOnFailure` strategy
- `rollback.cleanupOnFail: true` with `recreate: true`

You don't need to set these in individual HelmRelease files.

## Key Files

| File | Purpose |
|------|---------|
| `kubernetes/flux/cluster/ks.yaml` | **Root Kustomization** -- defines cluster-apps, variable substitution, SOPS decryption, and HelmRelease defaults for all apps |
| `kubernetes/components/sops/cluster-secrets.sops.yaml` | SOPS-encrypted Secret with all `${SECRET_*}` variables |
| `kubernetes/flux/repositories/helm/` | All HelmRepository sources (30+ charts) |
| `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml` | Flux Instance config -- controller tuning, SOPS setup, concurrency, OOM detection |
| `kubernetes/apps/flux-system/flux-instance/app/receiver.yaml` | GitHub webhook receiver for immediate reconciliation on push |
| `kubernetes/apps/<namespace>/<app>/ks.yaml` | Per-app Flux Kustomization (dependency ordering, target namespace) |
| `kubernetes/apps/<namespace>/<app>/app/helmrelease.yaml` | Per-app HelmRelease (chart source, values, image tags) |

## Adding a New App

1. Create the directory structure:
   ```
   kubernetes/apps/<namespace>/<app>/
   ├── ks.yaml                    # Flux Kustomization
   └── app/
       ├── kustomization.yaml     # lists resources
       └── helmrelease.yaml       # HelmRelease definition
   ```

2. In `ks.yaml`, define a Flux Kustomization pointing to the `app/` directory:
   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: my-app
     namespace: flux-system
   spec:
     targetNamespace: <namespace>
     path: ./kubernetes/apps/<namespace>/<app>/app
     sourceRef:
       kind: GitRepository
       name: flux-system
     interval: 30m
     prune: true
   ```

3. Register the `ks.yaml` in the namespace's `kustomization.yaml` under `resources:`.

4. Use `${SECRET_*}` variables freely -- they'll be substituted automatically.

## GitHub Webhook

A Flux `Receiver` listens for GitHub push events at `https://flux-webhook.<domain>/hook/`. On push, it immediately triggers reconciliation of the `flux-system` GitRepository and Kustomization instead of waiting for the poll interval. The webhook secret is stored in `flux-instance/app/secret.sops.yaml`.

## Troubleshooting

### Check overall Flux status

```bash
flux get all -A
flux stats
```

### A HelmRelease is stuck or failing

```bash
# Check the HelmRelease status and error message
flux get helmrelease -A | grep False
flux get helmrelease <name> -n <namespace>

# See the full error
kubectl describe helmrelease <name> -n <namespace>

# Force a re-reconciliation
flux reconcile helmrelease <name> -n <namespace> --force
```

### A Kustomization is not applying changes

```bash
# Check Kustomization status
flux get kustomization -A | grep False

# Force reconciliation from git
flux reconcile kustomization <name> -n flux-system --with-source
```

### Variable substitution isn't working (`${SECRET_*}` appears literally)

This is one of the most common issues. Variable substitution is performed by the **Kustomize controller** when processing a Flux Kustomization. It will **not** happen if you:

- `kubectl apply -f` a HelmRelease directly (bypasses Flux entirely)
- Reconcile only the HelmRelease without going through the Kustomization

**Fix:** Always let changes flow through git, or reconcile the Kustomization:
```bash
flux reconcile kustomization <name> -n flux-system --with-source
```

### SOPS decryption errors

```bash
# Check if the age key is present
kubectl get secret sops-age -n flux-system

# Verify the kustomize-controller has the key mounted
kubectl logs -n flux-system deploy/kustomize-controller | grep -i sops
```

If a `.sops.yaml` file fails to decrypt, verify it was encrypted with the correct age public key (check `.sops.yaml` at the repo root for the key fingerprint).

### Drift detection shows unexpected changes

If Flux keeps re-applying a resource, something is mutating it outside of git (a webhook, an operator, or a manual `kubectl` edit).

```bash
# Check for drift
flux diff kustomization <name>
```

### Pod is crashlooping after a config change

If a ConfigMap is mounted as a volume, Kubernetes propagates changes eventually, but the application won't reload automatically. You may need to restart the deployment:

```bash
kubectl rollout restart deployment/<name> -n <namespace>
```

### Flux controllers are OOM-killed

The flux-instance HelmRelease sets memory limits to 2Gi and enables OOM watch for helm-controller. If controllers are still OOM-killed:

```bash
kubectl top pods -n flux-system
kubectl describe pod -n flux-system -l app=helm-controller
```

Consider increasing memory limits in `flux-instance/app/helmrelease.yaml`.

## Key Things to Watch Out For

1. **Never `kubectl apply` HelmReleases directly** -- it bypasses Flux variable substitution and SOPS decryption. Changes should always go through git. If you must apply directly for emergency fixes, reconcile the Kustomization from source afterward.

2. **Dependency ordering matters** -- if `ks.yaml` has `dependsOn`, the dependency must be healthy first. A stuck dependency blocks everything downstream. Check with `flux get kustomization -A`.

3. **SOPS key rotation** -- if the age key changes, all `.sops.yaml` files must be re-encrypted. The kustomize-controller reads the key from the `sops-age` secret.

4. **ConfigMap-based configs don't trigger pod restarts** -- when a HelmRelease renders a ConfigMap (like ClickHouse's `config.xml`), updating the ConfigMap content doesn't automatically restart the pod. The Helm chart must use a checksum annotation on the ConfigMap, or you need a manual `kubectl rollout restart`.

5. **Flux reconciles from git, not local files** -- `flux reconcile` pulls from the GitRepository source. Local uncommitted changes have no effect unless applied via `kubectl apply` (which you should avoid -- see point 1).

6. **`prune: true` deletes removed resources** -- if you remove a resource from git, Flux will delete it from the cluster. Set `prune: false` on Kustomizations for critical resources (like Cilium CNI) where accidental deletion would be catastrophic.

7. **The webhook receiver speeds things up but isn't required** -- Flux polls every 30m-1h by default. If the webhook is broken, changes still apply eventually. Don't panic if reconciliation seems delayed -- check `flux get source git flux-system` for the last fetch time.

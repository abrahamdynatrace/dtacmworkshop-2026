# Migration Notes — 2021 → 2026

This folder is a modernized copy of `dynatrace-acm/dtacmworkshop` (last updated 2021). Goal: make the workshop runnable again on **GKE**, with **full self-healing**, replacing **Ansible Tower** with **AWX**. Nothing in the original repo was changed — this is a fresh, side-by-side folder.

## Why it was broken
The workshop stopped working because several dependencies were removed or deprecated:
- Kubernetes APIs used by the manifests were removed (`extensions/v1beta1` in 1.16, `rbac.../v1beta1` in 1.22, PodSecurityPolicy in 1.25).
- The Dynatrace install flow used the deprecated OneAgent Operator and never created a monitoring CR; it also relied on a `debian-9-stretch` GCE VM image that no longer exists.
- `gcloud` node image flags and defaults changed.
- Ansible Tower 3.3.1 reached end-of-life (replaced by AWX / Ansible Automation Platform).

## Changes by area

### 1. Kubernetes manifests
| Change | Files |
|--------|-------|
| `extensions/v1beta1` Deployment → `apps/v1` + required `spec.selector.matchLabels` | `manifests/sockshop-app/canary/carts2-badbuild.yml`, `.../front-end-canary.yml` |
| `rbac.authorization.k8s.io/v1beta1` → `v1` | `manifests/jenkins/k8s-jenkins-rbac.yaml` |
| nodeSelector `beta.kubernetes.io/os` → `kubernetes.io/os` | all `manifests/sockshop-app/**`, rabbitmq deps |
| Illegal Deployment name `front-end.canary` (dot) → `front-end-canary`; fixed Service with `namespace` misnested under `labels` | `manifests/sockshop-app/canary/front-end-canary.yml` |
| Removed deprecated `seccomp.security.alpha.kubernetes.io` annotation → `securityContext.seccompProfile: RuntimeDefault` | `manifests/prodload/k8s-prodload-deployment.yaml` |
| Pinned floating/old images: `mongo` → `mongo:6`, `rabbitmq:3.6.8/3.7-management` → `rabbitmq:3.12-management` | backend-services |

### 2. Dynatrace — Operator + DynaKube (biggest change)
- `utils/deploy-dt-operator.sh` now Helm-installs the operator from `oci://public.ecr.aws/dynatrace/dynatrace-operator`, creates the `dynakube` token secret (`apiToken` + `dataIngestToken`), and applies a **DynaKube** CR.
- New file `manifests/dynatrace/dynakube.yaml`: `oneAgent.cloudNativeFullStack` + an embedded **ActiveGate** with `kubernetes-monitoring`, `routing`, `dynatrace-api` (apiVersion `dynatrace.com/v1beta5`). This single CR replaces:
  - the separate Debian-9 GCE **ActiveGate VM** (`utils/deployagsoftware.sh` — **deleted**), and
  - the classic cluster registration via `api/config/v1/kubernetes/credentials` and the k8s-1.24-incompatible `sa.secrets[0]` token read (`utils/configureag.sh` — **deleted**).
- `1-Credentials/`: now collects an **API/operator token** and a **data-ingest token** (was API + PaaS). Dropped the "configure ActiveGate?" prompt (always on via DynaKube).
- **Deleted** as obsolete: `utils/deployagsoftware.sh`, `utils/configureag.sh`, `utils/deleteagConfiguration.sh`, `manifests/dynatrace/kubernetes-monitoring-service-account.yaml`.

### 3. GKE cluster (`2-CreateCluster/setupenv.sh`)
- GKE-only (Azure/AKS branch removed).
- `gcloud container clusters create`: `e2-standard-4` nodes, dropped `--image-type=Ubuntu` (default COS/containerd), added `--release-channel=regular`, 3 nodes. Zone/size overridable via env vars.
- Uses `get-credentials`, idempotent `clusterrolebinding`, real rollout waits instead of fixed `sleep`.

### 4. Jenkins (`3-DeployJenkins/deployJenkins.sh`)
- `kubectl create` → `apply`; real readiness + LoadBalancer-IP polling instead of `sleep 120`.
- Dropped `kubectl exec -it` (TTY flags fail in non-interactive shells).
- RBAC bumped to v1. Jenkins uses in-cluster projected SA tokens (works on k8s ≥ 1.24 without extra secrets).

### 5. Ansible Tower → AWX (`4-DeployTower`, `utils/configureAnsible.sh`)
- Replaced `manifests/ansible-tower/*` with the **AWX Operator** (`manifests/awx/kustomization.yaml` pinned to `2.19.1`) + an **AWX** CR (`manifests/awx/awx-cr.yaml`, LoadBalancer).
- `deployTower.sh`: `kubectl apply -k` the operator, wait, apply the AWX CR, wait for `awx-web`.
- `configureAnsible.sh`: migrated Ansible Tower **api/v1** → AWX **api/v2**; auth via operator-generated `awx-admin-password` on `http`/80 (was `admin:dynatrace` on `https`/443). Creates credential type/credential, git project (waits for SCM sync), inventory, and the `remediation` / `stop-campaign` / `start-campaign` job templates. `stop-campaign` is PATCHed with its own launch URL after creation (fixes the original's fragile `id+1` assumption).
- `utils/removeTower.sh` now removes AWX.

### 6. Load test / cleanup
- `5-Cleanup/cleanup.sh`: removes Dynatrace via `delete-dt-operator.sh`, drops the removed PSP/CRD deletions, uses `--ignore-not-found`, `pgrep` for the load-test PID.
- `5-Cleanup/deleteAll.sh`: GKE-only cluster delete; removed ActiveGate-VM delete and classic de-registration.

## Known risks / things you may still need to fix
1. **Legacy demo images** (`wmsegar/jenkins:5.0`, `wmsegar/carts:1.0/3.0`, `dynatracesockshop/*:0.5.0`) are pulled as-is from Docker Hub. They are amd64 (fine on GKE), but if any are deleted upstream you must rebuild them — their build sources are not in this repo.
2. **Jenkins pipeline internals** (pod templates, plugins) are baked into `wmsegar/jenkins:5.0` and are old; the pipeline definition lives in `PipelineWithIntegration.txt` / `3-DeployJenkins/config.xml`.
3. **Dynatrace classic v1 APIs** in `playbooks/*.yaml` (`api/v1/problem`, `api/v1/events`) — still present on most tenants but legacy; verify your token scopes.
4. `utils/configureK8sDashboard.sh` + `utils/config/k8sDashboard.json` are **legacy/optional** and no longer wired into the flow (they used the classic dashboard API). Left in place for reference; not maintained.
5. **AWX takes 5-10 min** to reconcile on first deploy; the scripts poll but be patient.

## Verification checklist (run on GKE)
This could not be executed offline (no cluster/tenant on the build machine). YAML edits are surgical; validate on your cluster:

```bash
# 0. Static-lint every manifest against your cluster's schemas
find manifests -name '*.y*ml' ! -path '*/awx/*' -exec kubectl apply --dry-run=server -f {} \;
kubectl kustomize manifests/awx >/dev/null   # renders the AWX operator kustomization

# 1..4  run the numbered folders (see README)

# Spot checks
kubectl -n dynatrace get dynakube,pods           # operator + OneAgent + ActiveGate Running
kubectl get pods -n dev; kubectl get pods -n production
kubectl -n cicd get svc jenkins                  # external IP on :24711
kubectl -n awx get pods,svc                       # awx-web running, awx-service has external IP
```

Then confirm in the Dynatrace UI: the cluster appears under Kubernetes, and SockShop services in `dev`/`production` are monitored. Finally, deploy a bad build (`manifests/sockshop-app/canary/carts2-badbuild.yml`) to trigger a problem and the AWX remediation.

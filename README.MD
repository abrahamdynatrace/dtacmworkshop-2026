# Dynatrace ACM Workshop (2026 refresh — GKE)

Unbreakable DevOps Pipeline tutorial with self-healing, using **Kubernetes (GKE)**, **Jenkins**, **JMeter**, **AWX** (modern Ansible), and **Dynatrace**.

> This is a modernized copy of the original 2021 [`dynatrace-acm/dtacmworkshop`](https://github.com/dynatrace-acm/dtacmworkshop). It targets **Google Kubernetes Engine only** and replaces the deprecated components so the workshop can run again. See [MIGRATION-NOTES.md](MIGRATION-NOTES.md) for everything that changed and the known risks.

The pipeline delivers four use cases:
1. **FullStack** monitoring of your **Staging** (dev) environment
2. **Shift-Left**: automatic approve/reject promotion Staging→Production based on Dynatrace quality gates
3. **FullStack** monitoring of your **Production** environment
4. **Self-Healing**: automatic remediation in Production when Dynatrace detects a problem (via AWX)

## Pre-Requisites
1. A **Google Cloud** account with billing, and access to **Google Cloud Shell** (recommended — it already has `gcloud`, `kubectl`, `helm`, `jq`, and `git`).
2. A **Dynatrace** SaaS tenant. [Free trial here](https://www.dynatrace.com/trial/).
3. Tooling if you are NOT using Cloud Shell: `gcloud`, `kubectl` ≥ 1.28, `helm` 3, `jq`.

### Dynatrace tokens you need
The modern Dynatrace Operator uses two tokens (create under **Access Tokens** in your tenant):

| Token | Purpose | Required scopes |
|-------|---------|-----------------|
| **API / Operator token** | operator + DynaKube + self-healing playbooks | `Create ActiveGate tokens`, `Read entities`, `Read settings`, `Write settings`, `Access problem and event feed, metrics, and topology`, `Read configuration`, `Write configuration`, `Ingest events` |
| **Data ingest token** | metrics/logs/traces ingest | `Ingest metrics`, `Ingest logs`, `Ingest OpenTelemetry traces` |

(You can also supply an optional legacy PaaS token; it is not required for the operator.)

## Quick start
Run each numbered folder in order **from inside that folder** (scripts use relative paths):

```bash
# 1. Enter your Dynatrace credentials -> writes 1-Credentials/creds.json
cd 1-Credentials && bash defineCredentials.sh && cd ..

# 2. Create the GKE cluster + Dynatrace Operator (DynaKube) + SockShop app
cd 2-CreateCluster && bash setupenv.sh && cd ..

# 3. Deploy Jenkins and the DeploySockShop pipeline job
cd 3-DeployJenkins && bash deployJenkins.sh && cd ..

# 4. Deploy AWX and configure the self-healing job templates
cd 4-DeployTower && bash deployTower.sh && cd ..
```

Cluster/zone/size are overridable via env vars, e.g.:
```bash
GKE_ZONE=europe-west1-b GKE_MACHINE_TYPE=e2-standard-4 bash setupenv.sh
```

### Self-healing wiring (in-cluster poller — no public AWX)
AWX is deployed as **ClusterIP** (no public IP). Instead of exposing it and configuring a
Dynatrace SaaS webhook, an **in-cluster poller** (a CronJob, deployed by step 4) checks Dynatrace
for open problems **through the in-cluster ActiveGate** and launches the AWX `remediation` job
template over internal DNS. Nothing inbound from the internet is required.

- Deployed automatically by `4-DeployTower/deployTower.sh` (or run `utils/deploy-remediation-poller.sh`).
- The Dynatrace API token needs scopes **`problems.read`** and **`problems.write`** (it comments a marker back on each handled problem for idempotency).
- Watch it: `kubectl -n awx get cronjob,jobs` and `kubectl -n awx logs -l job-name --tail=50 --prefix`.
- Access the AWX UI: `kubectl -n awx port-forward svc/awx-service 8080:80` → http://localhost:8080

To narrow which problems trigger remediation, set `PROBLEM_SELECTOR` (URL-encoded Dynatrace
problem selector) when running `deploy-remediation-poller.sh`.

## Cleanup
```bash
cd 5-Cleanup
bash cleanup.sh     # remove in-cluster objects, keep the GKE cluster
bash deleteAll.sh   # delete the entire GKE cluster
```

## Architecture
![](./images/acmsetup.JPG)

*(The diagram shows the original topology; the standalone ActiveGate VM is gone — the DynaKube now runs an embedded ActiveGate inside the cluster.)*

## Security / network exposure
This workshop exposes several services (including public LoadBalancers for Jenkins and AWX). In a monitored corporate GCP project this **will** trigger findings (e.g. GCP SCC "NodePort service created"). See **[SECURITY.md](SECURITY.md)** for the full exposure table and hardening steps. Quick version:

```bash
# dev services are ClusterIP now; reach them via port-forward:
kubectl -n dev port-forward svc/front-end 8080:8080

# restrict every LoadBalancer to your office IP + apply default-deny network policies:
kubectl apply -f manifests/security/networkpolicy.yaml
ALLOWED_CIDR="$(curl -s ifconfig.me)/32" bash utils/harden-network.sh
```
`setupenv.sh` runs the hardening automatically if you export `ALLOWED_CIDR` before running it, and creates the cluster with `--enable-dataplane-v2` so NetworkPolicies are enforced.

## Known risks / external dependencies
These are outside this repo's control and may need attention when you run it — details in [MIGRATION-NOTES.md](MIGRATION-NOTES.md):
- **Custom demo images** from 2019-2021 (`wmsegar/jenkins`, `dynatracesockshop/*`, `wmsegar/carts`) are pulled from Docker Hub as-is. If any are removed or fail to run they must be rebuilt from their (external) sources.
- The **Jenkins pipeline** relies on Kubernetes pod templates baked into `wmsegar/jenkins:5.0`; plugin versions there are old.
- The self-healing **playbooks** call classic Dynatrace `api/v1/problem` / `api/v1/events` endpoints; confirm your tenant/token still allows them.
- If you modify manifests or playbooks, push to your own fork and point AWX (and `manifests/prodload`) at it via `WORKSHOP_REPO_URL` / `WORKSHOP_REPO_BRANCH`.

More detailed slides: [DynatraceACM.pptx](DynatraceACM.pptx).

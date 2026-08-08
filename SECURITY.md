# Security notes

This is a **demo/workshop**, not a production reference. It deliberately exposes services to make the use cases observable. If you run it in a monitored corporate GCP project (e.g. GCP Security Command Center), expect findings. This doc explains what is exposed and how to reduce it.

## What gets exposed (by design)

| Service | Namespace | Type (default) | Notes |
|---------|-----------|----------------|-------|
| front-end | dev | **ClusterIP** (2026: was NodePort) | browse via `kubectl -n dev port-forward svc/front-end 8080:8080` |
| carts | dev | **ClusterIP** (2026: was NodePort) | `kubectl -n dev port-forward svc/carts 8080:80` |
| front-end | production | LoadBalancer | public demo storefront |
| carts | production | LoadBalancer | target of the load test |
| jenkins | cicd | LoadBalancer | **admin UI, default creds** |
| awx-service | awx | **ClusterIP** (2026: was LoadBalancer) | admin UI via `port-forward`; triggered internally by the poller |
| carts / front-end-canary | dev | LoadBalancer | created during the canary pipeline |

### GCP SCC finding: "Initial Access: GKE NodePort service created"
Caused by the two **NodePort** services in `dev`. Fixed in this repo by switching them to **ClusterIP** (2026 update). Re-apply the dev manifests (or patch live — see below) to clear it.

## Hardening ("medium" profile — applied by this repo)

1. **No NodePort** — dev services are ClusterIP; use `port-forward` to reach them.
2. **Restrict LoadBalancers to your office CIDR** and **default-deny NetworkPolicies**:
   ```bash
   kubectl apply -f manifests/security/networkpolicy.yaml
   ALLOWED_CIDR="<your-office-CIDR>" bash utils/harden-network.sh
   ```
   Or let `setupenv.sh` do it automatically by exporting `ALLOWED_CIDR` before running it.
3. **NetworkPolicy enforcement** requires the cluster to have it enabled:
   - New clusters: `setupenv.sh` now passes `--enable-dataplane-v2`.
   - Existing Standard cluster (like one already running): enable the Calico add-on
     ```bash
     gcloud container clusters update acmworkshop --zone us-central1-a \
       --update-addons=NetworkPolicy=ENABLED
     gcloud container clusters update acmworkshop --zone us-central1-a \
       --enable-network-policy
     ```

## Immediate mitigation for an already-running cluster
If your cluster is live and was just flagged, you don't need to redeploy:
```bash
# 1. Remove the NodePort exposure (clears the SCC finding)
kubectl -n dev patch svc front-end -p '{"spec":{"type":"ClusterIP"}}'
kubectl -n dev patch svc carts     -p '{"spec":{"type":"ClusterIP"}}'

# 2. Lock every LoadBalancer down to your office IP
ALLOWED_CIDR="$(curl -s ifconfig.me)/32" bash utils/harden-network.sh
```

## Self-healing without exposing AWX (in-cluster poller)
Dynatrace SaaS cannot push a webhook to an internal endpoint, and there is no native
"route this webhook through my ActiveGate" for generic problem notifications. So instead of
exposing AWX, this repo uses a **pull** model:

- AWX is **ClusterIP** (no public IP).
- `manifests/remediation-poller/` runs a CronJob (namespace `awx`, every minute) that:
  1. queries the Dynatrace Problems API v2 **through the in-cluster ActiveGate**
     (`https://dynakube-activegate.dynatrace.svc.cluster.local/e/<env>/api`), and
  2. launches the AWX `remediation` job template via internal DNS
     (`http://awx-service.awx.svc.cluster.local`).
- Idempotency: the poller posts a marker comment back on each handled problem and skips
  problems that already have it.
- Deploy with `utils/deploy-remediation-poller.sh` (done automatically by step 4).
- Token scopes required: `problems.read`, `problems.write`.

This means **no Dynatrace webhook/notification is configured** and **no inbound internet access
to AWX** is needed. If you prefer the classic push model, expose AWX via LoadBalancer and restrict
`loadBalancerSourceRanges` to Dynatrace's published egress ranges + your office CIDR instead.

## Known residual risks
- **Jenkins** still ships with weak/default credentials on a public LoadBalancer — change the
  password and restrict it (harden-network.sh), or move it to ClusterIP + port-forward too.
- **AWX admin password** is auto-generated (secret `awx-admin-password`); rotate if needed.
- The poller's Dynatrace token has `problems.read`/`problems.write` — scope it to exactly that.
- Old demo container images (see MIGRATION-NOTES) are not security-patched.

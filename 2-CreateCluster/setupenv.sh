#!/bin/bash
#
# Create a GKE cluster, deploy the Dynatrace Operator (+DynaKube) and the SockShop app.
#
# 2026 update:
#   - GKE only (the Azure/AKS branch was removed).
#   - Removed the separate Debian-9 GCE ActiveGate VM and the classic configureag.sh /
#     configureK8sDashboard.sh calls. The DynaKube's embedded ActiveGate registers the
#     cluster automatically.
#   - Modern node pool: e2-standard-4, default COS_containerd image (dropped --image-type=Ubuntu),
#     and a release channel instead of a pinned/expired version.
#
set -euo pipefail

CREDS="../1-Credentials/creds.json"
API_TOKEN=$(jq -r '.dynatraceApiToken' "$CREDS")
TENANTID=$(jq -r '.dynatraceTenantID' "$CREDS")
ENVIRONMENTID=$(jq -r '.dynatraceEnvironmentID' "$CREDS")

# Override these with env vars if you like: e.g. GKE_ZONE=europe-west1-b ./setupenv.sh
GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:-acmworkshop}"
GKE_ZONE="${GKE_ZONE:-us-central1-a}"
GKE_MACHINE_TYPE="${GKE_MACHINE_TYPE:-e2-standard-4}"
GKE_NUM_NODES="${GKE_NUM_NODES:-3}"
GKE_RELEASE_CHANNEL="${GKE_RELEASE_CHANNEL:-regular}"

if ! command -v gcloud >/dev/null 2>&1; then
    echo "gcloud not found. This workshop targets Google Kubernetes Engine (GKE)."
    echo "Run it from Google Cloud Shell or install the Google Cloud SDK."
    exit 1
fi

echo "Creating GKE cluster with the following settings:"
echo "  Dynatrace Tenant : $TENANTID"
echo "  Environment ID   : ${ENVIRONMENTID:-<SaaS>}"
echo "  Cluster name     : $GKE_CLUSTER_NAME"
echo "  Zone             : $GKE_ZONE"
echo "  Machine type     : $GKE_MACHINE_TYPE"
echo "  Node count       : $GKE_NUM_NODES"
echo "  Release channel  : $GKE_RELEASE_CHANNEL"
echo ""
read -p "Is this all correct? (y/n) : " -n 1 -r
echo ""
[[ $REPLY =~ ^[Yy]$ ]] || exit 1

echo "Creating GKE cluster (this can take several minutes)..."
gcloud container clusters create "$GKE_CLUSTER_NAME" \
    --zone="$GKE_ZONE" \
    --num-nodes="$GKE_NUM_NODES" \
    --machine-type="$GKE_MACHINE_TYPE" \
    --release-channel="$GKE_RELEASE_CHANNEL"

echo "Fetching cluster credentials..."
gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" --zone="$GKE_ZONE"

# Grant your account cluster-admin so RBAC-heavy components (Jenkins, operators) install cleanly.
kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole=cluster-admin \
    --user="$(gcloud config get-value account)" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying Dynatrace Operator + DynaKube..."
../utils/deploy-dt-operator.sh

echo "Deploying SockShop application (dev + production)..."
../utils/deploy-sockshop.sh

echo "Waiting for SockShop pods to schedule..."
kubectl -n production rollout status deploy/front-end --timeout=300s || true

echo "Starting production load generator (background)..."
nohup ../utils/cartsLoadTest.sh > /tmp/cartsLoadTest.log 2>&1 &

echo "-----------------------"
echo "Deployment Complete"
echo "The cluster auto-registers in Dynatrace via the DynaKube ActiveGate."
echo "-----------------------"

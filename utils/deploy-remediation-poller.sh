#!/bin/bash
#
# Deploy the in-cluster self-healing poller (2026). This replaces the public
# Dynatrace SaaS -> AWX webhook: AWX stays ClusterIP, and a CronJob in the cluster
# polls Dynatrace for open problems THROUGH THE IN-CLUSTER ACTIVEGATE, then launches
# the AWX 'remediation' job template over internal DNS.
#
# Prereqs: DynaKube deployed (provides the ActiveGate) and AWX deployed + configured.
#
set -euo pipefail

CREDS="../1-Credentials/creds.json"
DT_TOKEN=$(jq -r '.dynatraceApiToken' "$CREDS")
TENANTID=$(jq -r '.dynatraceTenantID' "$CREDS")
ENVIRONMENTID=$(jq -r '.dynatraceEnvironmentID' "$CREDS")

# --- Where the poller reaches the Dynatrace API -----------------------------
# Default: through the in-cluster DynaKube ActiveGate (no direct SaaS egress needed).
# ActiveGate service for a DynaKube named "dynakube" is "dynakube-activegate" in ns "dynatrace".
# For SaaS the environment id equals the tenant id; for Managed use the environment id.
AG_HOST="${AG_HOST:-dynakube-activegate.dynatrace.svc.cluster.local}"
if [ -z "$ENVIRONMENTID" ] || [ "$ENVIRONMENTID" = "null" ]; then
    DT_ENV_SEGMENT="$TENANTID"
else
    DT_ENV_SEGMENT="$ENVIRONMENTID"
fi
# Override DT_API_BASE to call SaaS directly instead of via ActiveGate, e.g.:
#   DT_API_BASE="https://<TENANTID>.live.dynatrace.com/api" ./deploy-remediation-poller.sh
DT_API_BASE="${DT_API_BASE:-https://$AG_HOST/e/$DT_ENV_SEGMENT/api}"

AWX_BASE="${AWX_BASE:-http://awx-service.awx.svc.cluster.local}"
PROBLEM_SELECTOR="${PROBLEM_SELECTOR:-status(%22open%22)}"   # URL-encoded status("open")
FROM_WINDOW="${FROM_WINDOW:-now-10m}"
TEMPLATE_NAME="${TEMPLATE_NAME:-remediation}"

echo "Poller configuration:"
echo "  DT_API_BASE      = $DT_API_BASE"
echo "  AWX_BASE         = $AWX_BASE"
echo "  PROBLEM_SELECTOR = $PROBLEM_SELECTOR"
echo "  FROM_WINDOW      = $FROM_WINDOW"
echo "  TEMPLATE_NAME    = $TEMPLATE_NAME"

# --- Token secret (needs scopes: problems.read + problems.write) ------------
echo "Creating dynatrace-remediation-token secret..."
kubectl -n awx create secret generic dynatrace-remediation-token \
    --from-literal="apiToken=$DT_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

# --- Config -----------------------------------------------------------------
echo "Creating remediation-poller-config..."
kubectl -n awx create configmap remediation-poller-config \
    --from-literal="DT_API_BASE=$DT_API_BASE" \
    --from-literal="AWX_BASE=$AWX_BASE" \
    --from-literal="PROBLEM_SELECTOR=$PROBLEM_SELECTOR" \
    --from-literal="FROM_WINDOW=$FROM_WINDOW" \
    --from-literal="TEMPLATE_NAME=$TEMPLATE_NAME" \
    --from-literal="AWX_USER=admin" \
    --dry-run=client -o yaml | kubectl apply -f -

# --- Script + CronJob -------------------------------------------------------
echo "Applying poller script and CronJob..."
kubectl apply -f ../manifests/remediation-poller/poller-script.yaml
kubectl apply -f ../manifests/remediation-poller/cronjob.yaml

echo "-----------------------------------------------------------------"
echo "Remediation poller deployed to namespace awx (runs every minute)."
echo "Watch it with:"
echo "  kubectl -n awx get cronjob,jobs"
echo "  kubectl -n awx logs -l job-name --tail=50 --prefix"
echo ""
echo "The Dynatrace API token needs scopes: problems.read AND problems.write."
echo "AWX is NOT exposed publicly; no Dynatrace webhook/notification is required."
echo "-----------------------------------------------------------------"

#!/bin/bash
#
# Deploy the Dynatrace Operator (Helm) + a DynaKube custom resource.
#
# 2026 update:
#   - Old flow installed the deprecated OneAgent Operator via install.sh and NEVER created a
#     monitoring CR, so nothing was actually monitored. It also spun up a separate Debian-9 GCE
#     ActiveGate VM (image removed) and registered the cluster through the classic
#     api/config/v1/kubernetes/credentials endpoint (utils/configureag.sh).
#   - New flow: Helm-install the Dynatrace Operator, then apply a DynaKube with
#     cloudNativeFullStack + an embedded ActiveGate (kubernetes-monitoring). The ActiveGate
#     auto-registers this cluster, so no VM and no classic API call are needed.
#
set -euo pipefail

CREDS="../1-Credentials/creds.json"
API_TOKEN=$(jq -r '.dynatraceApiToken' "$CREDS")
DATA_INGEST_TOKEN=$(jq -r '.dynatraceDataIngestToken // .dynatracePaaSToken' "$CREDS")
TENANTID=$(jq -r '.dynatraceTenantID' "$CREDS")
ENVIRONMENTID=$(jq -r '.dynatraceEnvironmentID' "$CREDS")

# Build the API URL. SaaS by default; Managed if an environment ID was supplied.
if [ -z "$ENVIRONMENTID" ] || [ "$ENVIRONMENTID" = "null" ]; then
    API_URL="https://$TENANTID.live.dynatrace.com/api"
else
    API_URL="https://$TENANTID.dynatrace-managed.com/e/$ENVIRONMENTID/api"
fi
echo "Using Dynatrace API URL: $API_URL"

# 1) Install the operator via Helm (official OCI chart).
echo "Installing Dynatrace Operator via Helm..."
helm install dynatrace-operator oci://public.ecr.aws/dynatrace/dynatrace-operator \
    --create-namespace \
    --namespace dynatrace \
    --atomic

echo "Waiting for the operator webhook to be ready..."
kubectl -n dynatrace wait pod --for=condition=ready \
    --selector=app.kubernetes.io/name=dynatrace-operator,app.kubernetes.io/component=webhook \
    --timeout=300s

# 2) Create/refresh the token secret (must be named the same as the DynaKube: "dynakube").
echo "Creating dynakube token secret..."
kubectl -n dynatrace create secret generic dynakube \
    --from-literal="apiToken=$API_TOKEN" \
    --from-literal="dataIngestToken=$DATA_INGEST_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

# 3) Apply the DynaKube CR with the rendered API URL.
echo "Applying DynaKube custom resource..."
sed "s~DT_API_URL_PLACEHOLDER~$API_URL~" ../manifests/dynatrace/dynakube.yaml | kubectl apply -f -

echo "Waiting for DynaKube to become available..."
kubectl -n dynatrace wait dynakube/dynakube --for=condition=ActiveGate --timeout=300s || \
    echo "NOTE: ActiveGate condition not ready yet; check 'kubectl -n dynatrace get dynakube' and pod logs."

echo "-----------------------------------------------------------------"
echo "Dynatrace Operator + DynaKube deployed."
echo "The embedded ActiveGate auto-registers this cluster in Dynatrace"
echo "(Settings > Cloud & virtualization > Kubernetes). No VM required."
echo "-----------------------------------------------------------------"

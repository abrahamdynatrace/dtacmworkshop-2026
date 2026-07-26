#!/bin/bash
#
# LEGACY / OPTIONAL — NOT part of the 2026 flow and NOT maintained.
# This imports a classic Kubernetes dashboard via the deprecated config/v1 dashboard API and
# expects a 'dynatraceK8sClusterID' field that the modern DynaKube flow no longer produces.
# The DynaKube ActiveGate already provides built-in Kubernetes dashboards in Dynatrace.
# Kept only for reference. Run at your own risk.

export TENANTID=$(cat ../1-Credentials/creds.json | jq -r '.dynatraceTenantID')
export ENVIRONMENTID=$(cat ../1-Credentials/creds.json | jq -r '.dynatraceEnvironmentID')
export API_TOKEN=$(cat ../1-Credentials/creds.json | jq -r '.dynatraceApiToken')
export K8S_CLUSTER_ID=$(cat ../1-Credentials/creds.json | jq -r '.dynatraceK8sClusterID')

case $ENVIRONMENTID in
        '')
        echo "SaaS Deplyoment"
        sed -i 's/TENANT_ID/'$TENANTID'/g' ../utils/config/k8sDashboard.json
        export DT_TENANT_URL="https://$TENANTID.live.dynatrace.com"
        ;;
        *)
        echo "Managed Deployment"
        sed -i 's/TENANT_ID.live.dynatrace.com/'$TENANTID'.dynatrace-managed.com\/e\/'$ENVIRONMENTID'/g' ../utils/config/k8sDashboard.json
        export DT_TENANT_URL="https://$TENANTID.dynatrace-managed.com/e/$ENVIRONMENTID"
        ;;
        ?)
        usage
        ;;
esac

sed -i 's/KUBERNETES_CLUSTER_ID/'$K8S_CLUSTER_ID'/' ../utils/config/k8sDashboard.json

DASHBOARD_ID=$(curl -XPOST --data @../utils/config/k8sDashboard.json "$DT_TENANT_URL/api/config/v1/dashboards" -H "accept: application/json; charset=utf-8" -H "Authorization: Api-Token $API_TOKEN" -H "Content-Type: application/json; charset=utf-8" | jq -r ".id")

echo "-----------------------"
echo "Dashboard URL: $DT_TENANT_URL/#dashboard/dashboard;id=$DASHBOARD_ID"
echo "-----------------------"
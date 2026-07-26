#!/bin/bash
#
# Collect the Dynatrace credentials needed by the workshop and write them to creds.json.
#
# 2026 update:
#   - The modern Dynatrace Operator needs an API/operator token AND a data-ingest token
#     (instead of the old API + PaaS token pair). See README for the exact token scopes.
#   - The old "configure an ActiveGate?" question was removed: the DynaKube always deploys an
#     embedded ActiveGate with kubernetes-monitoring, so cluster registration is automatic.

YLW='\033[1;33m'
NC='\033[0m'

CREDS=./creds.json
rm -f "$CREDS" 2>/dev/null

echo -e "${YLW}Please enter the credentials as requested below: ${NC}"
read -p "Dynatrace Tenant ID (e.g. abc12345 from https://<TENANT_ID>.live.dynatrace.com): " DTTEN
read -p "Dynatrace Environment ID (Managed only - https://<TENANT_ID>.dynatrace-managed.com/e/<ENVIRONMENT_ID>; leave blank for SaaS): " DTENV
read -p "Dynatrace API/Operator Token (dt0c01... - see README for required scopes): " DTAPI
read -p "Dynatrace Data Ingest Token (dt0c01... - metrics/logs/traces ingest scopes): " DTINGEST
read -p "Dynatrace PaaS Token (optional, used for legacy downloads - press Enter to skip): " DTPAAS
echo ""

echo -e "${YLW}Please confirm all are correct: ${NC}"
echo "Dynatrace Tenant ID:        $DTTEN"
echo "Dynatrace Environment ID:   $DTENV"
echo "Dynatrace API/Operator Token: $DTAPI"
echo "Dynatrace Data Ingest Token:  $DTINGEST"
echo "Dynatrace PaaS Token:       $DTPAAS"
read -p "Is this all correct? (y/n) : " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f "$CREDS" 2>/dev/null
    sed -e "s~DYNATRACE_TENANT_ID~$DTTEN~" \
        -e "s~DYNATRACE_ENVIRONMENT_ID~$DTENV~" \
        -e "s~DYNATRACE_API_TOKEN~$DTAPI~" \
        -e "s~DYNATRACE_DATA_INGEST_TOKEN~$DTINGEST~" \
        -e "s~DYNATRACE_PAAS_TOKEN~$DTPAAS~" \
        ./creds.sav > "$CREDS"
fi

echo ""
cat "$CREDS"
echo ""
echo "The credentials file can be found here: $CREDS"
echo ""

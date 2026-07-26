#!/bin/bash
#
# Configure AWX for the Dynatrace self-healing use case:
#   - a "dt-api" credential type + a credential holding the Dynatrace API token
#   - a git project pointing at this workshop repo (which contains playbooks/)
#   - an inventory with the Dynatrace/cart variables
#   - job templates: remediation, stop-campaign, start-campaign
#
# 2026 update: migrated from Ansible Tower api/v1 (admin:dynatrace, https/443) to AWX api/v2,
# using the operator-generated admin password and the awx-service LoadBalancer on http/80.
#
set -euo pipefail

CREDS="../1-Credentials/creds.json"
DT_TENANT_ID=$(jq -r '.dynatraceTenantID' "$CREDS")
DT_ENVIRONMENT_ID=$(jq -r '.dynatraceEnvironmentID' "$CREDS")
DT_API_TOKEN=$(jq -r '.dynatraceApiToken' "$CREDS")

# Point these at YOUR updated fork/branch (the one that contains the modernized playbooks/).
WORKSHOP_REPO_URL="${WORKSHOP_REPO_URL:-https://github.com/dynatrace-acm/dtacmworkshop.git}"
WORKSHOP_REPO_BRANCH="${WORKSHOP_REPO_BRANCH:-master}"

if [ -z "$DT_ENVIRONMENT_ID" ] || [ "$DT_ENVIRONMENT_ID" = "null" ]; then
    echo "SaaS deployment"
    DT_TENANT_URL="https://$DT_TENANT_ID.live.dynatrace.com"
else
    echo "Managed deployment ($DT_ENVIRONMENT_ID)"
    DT_TENANT_URL="https://$DT_TENANT_ID.dynatrace-managed.com/e/$DT_ENVIRONMENT_ID"
fi

# --- Resolve endpoints -------------------------------------------------------
echo "Resolving the production carts LoadBalancer IP..."
CART_URL=""
for i in $(seq 1 30); do
    CART_URL=$(kubectl -n production get svc carts -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "$CART_URL" ] && break
    sleep 10
done

echo "Resolving the AWX LoadBalancer IP..."
AWX_IP=""
for i in $(seq 1 60); do
    AWX_IP=$(kubectl -n awx get svc awx-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "$AWX_IP" ] && break
    echo "  ...waiting for awx-service IP ($i/60)"; sleep 10
done
[ -n "$AWX_IP" ] || { echo "Could not resolve awx-service IP. Check: kubectl -n awx get svc awx-service"; exit 1; }

AWX_URL="http://$AWX_IP"
AWX_USER="admin"
AWX_PASS=$(kubectl -n awx get secret awx-admin-password -o jsonpath='{.data.password}' | base64 --decode)
echo "AWX is reachable at $AWX_URL (user: $AWX_USER)"

# curl helper for the AWX REST API (api/v2).
awx_api() {
    local method="$1"; local path="$2"; local data="${3:-}"
    if [ -n "$data" ]; then
        curl -sk -X "$method" "$AWX_URL/api/v2/$path" --user "$AWX_USER:$AWX_PASS" \
            -H "Content-Type: application/json" --data "$data"
    else
        curl -sk -X "$method" "$AWX_URL/api/v2/$path" --user "$AWX_USER:$AWX_PASS" \
            -H "Content-Type: application/json"
    fi
}

# Default organization in AWX is id 1 ("Default").
ORG_ID=1

# --- Credential type + credential -------------------------------------------
echo "Creating dt-api credential type..."
DTAPICREDTYPE=$(awx_api POST "credential_types/" '{
  "name": "dt-api",
  "kind": "cloud",
  "description": "Dynatrace API Authentication Token",
  "inputs": { "fields": [ { "secret": true, "type": "string", "id": "dt_api_token", "label": "Dynatrace API Token" } ], "required": ["dt_api_token"] },
  "injectors": { "extra_vars": { "DYNATRACE_API_TOKEN": "{{dt_api_token}}" } }
}' | jq -r '.id')
# If it already exists, look it up.
if [ "$DTAPICREDTYPE" = "null" ] || [ -z "$DTAPICREDTYPE" ]; then
    DTAPICREDTYPE=$(awx_api GET "credential_types/?name=dt-api" | jq -r '.results[0].id')
fi
echo "  credential_type id: $DTAPICREDTYPE"

echo "Creating Dynatrace API credential..."
DTCRED=$(awx_api POST "credentials/" '{
  "name": "'"$DT_TENANT_ID"' API token",
  "credential_type": '"$DTAPICREDTYPE"',
  "organization": '"$ORG_ID"',
  "inputs": { "dt_api_token": "'"$DT_API_TOKEN"'" }
}' | jq -r '.id')
if [ "$DTCRED" = "null" ] || [ -z "$DTCRED" ]; then
    DTCRED=$(awx_api GET "credentials/?name=$DT_TENANT_ID%20API%20token" | jq -r '.results[0].id')
fi
echo "  credential id: $DTCRED"

# --- Project (git) -----------------------------------------------------------
echo "Creating self-healing git project ($WORKSHOP_REPO_URL @ $WORKSHOP_REPO_BRANCH)..."
PROJECT_ID=$(awx_api POST "projects/" '{
  "name": "self-healing",
  "organization": '"$ORG_ID"',
  "scm_type": "git",
  "scm_url": "'"$WORKSHOP_REPO_URL"'",
  "scm_branch": "'"$WORKSHOP_REPO_BRANCH"'",
  "scm_clean": true,
  "scm_update_on_launch": true
}' | jq -r '.id')
if [ "$PROJECT_ID" = "null" ] || [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(awx_api GET "projects/?name=self-healing" | jq -r '.results[0].id')
fi
echo "  project id: $PROJECT_ID"

echo "Waiting for the project to finish its initial SCM sync..."
for i in $(seq 1 30); do
    STATUS=$(awx_api GET "projects/$PROJECT_ID/" | jq -r '.status')
    echo "  project status: $STATUS"
    [ "$STATUS" = "successful" ] && break
    [ "$STATUS" = "failed" ] && { echo "Project sync failed - check the repo URL/branch."; break; }
    sleep 10
done

# --- Inventory ---------------------------------------------------------------
echo "Creating inventory..."
INVENTORY_ID=$(awx_api POST "inventories/" '{
  "name": "inventory",
  "organization": '"$ORG_ID"',
  "variables": "---\ntenanturl: \"'"$DT_TENANT_URL"'\"\ncarts_promotion_url: \"http://'"$CART_URL"'/carts/1/items/promotion\"\ncommentuser: \"Ansible Playbook\"\ntower_user: \"'"$AWX_USER"'\"\ntower_password: \"'"$AWX_PASS"'\"\ndtcommentapiurl: \"{{tenanturl}}/api/v1/problem/details/{{pid}}/comments?Api-Token={{DYNATRACE_API_TOKEN}}\"\ndteventapiurl: \"{{tenanturl}}/api/v1/events/?Api-Token={{DYNATRACE_API_TOKEN}}\""
}' | jq -r '.id')
if [ "$INVENTORY_ID" = "null" ] || [ -z "$INVENTORY_ID" ]; then
    INVENTORY_ID=$(awx_api GET "inventories/?name=inventory" | jq -r '.results[0].id')
fi
echo "  inventory id: $INVENTORY_ID"

# --- Job templates -----------------------------------------------------------
echo "Creating remediation job template..."
REMEDIATION_TEMPLATE_ID=$(awx_api POST "job_templates/" '{
  "name": "remediation",
  "job_type": "run",
  "inventory": '"$INVENTORY_ID"',
  "project": '"$PROJECT_ID"',
  "playbook": "playbooks/remediation.yaml",
  "ask_variables_on_launch": true
}' | jq -r '.id')
if [ "$REMEDIATION_TEMPLATE_ID" = "null" ] || [ -z "$REMEDIATION_TEMPLATE_ID" ]; then
    REMEDIATION_TEMPLATE_ID=$(awx_api GET "job_templates/?name=remediation" | jq -r '.results[0].id')
fi
echo "  remediation template id: $REMEDIATION_TEMPLATE_ID"

echo "Creating stop-campaign job template..."
STOP_CAMPAIGN_ID=$(awx_api POST "job_templates/" '{
  "name": "stop-campaign",
  "job_type": "run",
  "inventory": '"$INVENTORY_ID"',
  "project": '"$PROJECT_ID"',
  "playbook": "playbooks/campaign.yaml",
  "extra_vars": "---\npromotion_rate: \"0\"\ndt_application: \"carts\"\ndt_environment: \"prod\""
}' | jq -r '.id')
if [ "$STOP_CAMPAIGN_ID" = "null" ] || [ -z "$STOP_CAMPAIGN_ID" ]; then
    STOP_CAMPAIGN_ID=$(awx_api GET "job_templates/?name=stop-campaign" | jq -r '.results[0].id')
fi
echo "  stop-campaign template id: $STOP_CAMPAIGN_ID"

# campaign.yaml references {{remediation_action}}. Now that we know the stop-campaign id,
# patch it to point remediation_action at its own launch URL (matches the original design).
awx_api PATCH "job_templates/$STOP_CAMPAIGN_ID/" '{
  "extra_vars": "---\npromotion_rate: \"0\"\nremediation_action: \"'"$AWX_URL"'/api/v2/job_templates/'"$STOP_CAMPAIGN_ID"'/launch/\"\ndt_application: \"carts\"\ndt_environment: \"prod\""
}' >/dev/null

# Now that stop-campaign exists, set the remediation_action for start-campaign to launch it.
echo "Creating start-campaign job template..."
START_CAMPAIGN_ID=$(awx_api POST "job_templates/" '{
  "name": "start-campaign",
  "job_type": "run",
  "inventory": '"$INVENTORY_ID"',
  "project": '"$PROJECT_ID"',
  "playbook": "playbooks/campaign.yaml",
  "extra_vars": "---\npromotion_rate: \"50\"\nremediation_action: \"'"$AWX_URL"'/api/v2/job_templates/'"$STOP_CAMPAIGN_ID"'/launch/\"\ndt_application: \"carts\"\ndt_environment: \"prod\"",
  "ask_variables_on_launch": true
}' | jq -r '.id')
if [ "$START_CAMPAIGN_ID" = "null" ] || [ -z "$START_CAMPAIGN_ID" ]; then
    START_CAMPAIGN_ID=$(awx_api GET "job_templates/?name=start-campaign" | jq -r '.results[0].id')
fi
echo "  start-campaign template id: $START_CAMPAIGN_ID"

# --- Attach the Dynatrace API credential to each job template ----------------
echo "Attaching the Dynatrace credential to the job templates..."
for template in "$REMEDIATION_TEMPLATE_ID" "$STOP_CAMPAIGN_ID" "$START_CAMPAIGN_ID"; do
    awx_api POST "job_templates/$template/credentials/" '{ "id": '"$DTCRED"' }' >/dev/null
done

echo "----------------------------------------------------"
echo "AWX configured successfully!"
echo "AWX UI      : $AWX_URL  (user: admin / password above)"
echo "Set this remediation URL as the Ansible/AWX webhook target in Dynatrace notifications:"
echo "  $AWX_URL/api/v2/job_templates/$REMEDIATION_TEMPLATE_ID/launch/"
echo "----------------------------------------------------"

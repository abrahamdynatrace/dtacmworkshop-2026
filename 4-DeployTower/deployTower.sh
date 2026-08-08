#!/bin/bash
#
# Deploy AWX (self-healing automation) and configure the remediation job templates.
#
# 2026 update:
#   - Ansible Tower 3.3.1 (dynatraceacm/ansibletower image, EOL) replaced by the AWX Operator.
#   - The operator installs AWX (web/task/postgres) into the `awx` namespace and exposes it
#     via a LoadBalancer service `awx-service`.
#
set -euo pipefail

echo "Creating awx namespace..."
kubectl create namespace awx --dry-run=client -o yaml | kubectl apply -f -

echo "Installing the AWX Operator..."
kubectl apply -k ../manifests/awx

echo "Waiting for the AWX Operator to be ready..."
kubectl -n awx rollout status deploy/awx-operator-controller-manager --timeout=300s

echo "Creating the AWX instance..."
kubectl apply -f ../manifests/awx/awx-cr.yaml

echo "Waiting for AWX to be reconciled by the operator (this can take 5-10 minutes)..."
# The web deployment is named "awx-web" once the operator creates it.
for i in $(seq 1 60); do
    if kubectl -n awx get deploy awx-web >/dev/null 2>&1; then break; fi
    echo "  ...waiting for AWX deployments to appear ($i/60)"; sleep 15
done
kubectl -n awx rollout status deploy/awx-web --timeout=600s

echo "Configuring AWX (projects, inventory, job templates)..."
../utils/configureAnsible.sh

echo "Deploying the in-cluster self-healing poller (keeps AWX private)..."
../utils/deploy-remediation-poller.sh

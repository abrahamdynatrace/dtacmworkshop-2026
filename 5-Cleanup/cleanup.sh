#!/bin/bash
#
# Tear down the in-cluster workshop objects (keeps the GKE cluster itself).
#
# 2026 update: the old OneAgent Operator PodSecurityPolicies/CRD (PSP removed in k8s 1.25,
# oneagents.dynatrace.com CRD no longer used) are replaced by removing the Dynatrace Operator
# Helm release + DynaKube. AWX replaces the tower namespace.
set -uo pipefail

# Stop the carts load test if it is running.
CARTS_LOADTEST_PID=$(pgrep -f cartsLoadTest.sh || true)
if [ -n "$CARTS_LOADTEST_PID" ]; then
    kill $CARTS_LOADTEST_PID 2>/dev/null || true
    echo "Carts load test (PID $CARTS_LOADTEST_PID) stopped"
fi

# Remove Dynatrace (operator Helm release + DynaKube + namespace).
../utils/delete-dt-operator.sh || true

# Remove cluster role bindings and namespace-scoped role bindings.
kubectl delete clusterrolebinding cluster-admin-binding --ignore-not-found
kubectl -n dev delete rolebinding default-view --ignore-not-found
kubectl -n production delete rolebinding default-view --ignore-not-found

# Remove AWX.
kubectl delete namespace awx --ignore-not-found

# Remove application + tooling namespaces and their objects.
kubectl delete ns dev --ignore-not-found
kubectl delete ns production --ignore-not-found
kubectl delete ns cicd --ignore-not-found

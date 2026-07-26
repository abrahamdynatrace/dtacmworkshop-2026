#!/bin/bash
#
# Remove the Dynatrace Operator + DynaKube (2026 Helm-based install).
set -uo pipefail

# Delete the DynaKube first so the operator can clean up injected pods/ActiveGate.
kubectl delete -n dynatrace dynakube --all --ignore-not-found

# Uninstall the Helm release that installed the operator.
helm uninstall dynatrace-operator -n dynatrace || true

kubectl delete secret dynakube -n dynatrace --ignore-not-found
kubectl delete namespace dynatrace --ignore-not-found

echo "Dynatrace Operator removed. The cluster de-registers from Dynatrace automatically."

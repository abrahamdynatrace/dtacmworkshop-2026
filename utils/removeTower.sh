#!/bin/bash
#
# Remove AWX (the modern replacement for Ansible Tower).
set -uo pipefail

kubectl delete -f ../manifests/awx/awx-cr.yaml --ignore-not-found
kubectl delete -k ../manifests/awx --ignore-not-found
kubectl delete namespace awx --ignore-not-found

echo "----------------------------------------------------"
echo "AWX has been removed"
echo "----------------------------------------------------"

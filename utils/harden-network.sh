#!/bin/bash
#
# Restrict external exposure of the workshop (2026 security hardening, "medium" profile):
#   1. Patch every LoadBalancer service with loadBalancerSourceRanges = your office CIDR,
#      so the public IPs (Jenkins, AWX, front-end/carts in production) only accept your traffic.
#   2. Apply a NetworkPolicy allowing that same CIDR to reach the app pods (works together with
#      manifests/security/networkpolicy.yaml default-deny).
#
# Usage:
#   ALLOWED_CIDR="203.0.113.10/32" ./harden-network.sh
#   ./harden-network.sh 203.0.113.0/24
#
set -euo pipefail

ALLOWED_CIDR="${ALLOWED_CIDR:-${1:-}}"
if [ -z "$ALLOWED_CIDR" ]; then
    echo "ERROR: provide your office egress CIDR."
    echo "  Find it with:  curl -s ifconfig.me   (then append /32 for a single IP)"
    echo "  Usage:         ALLOWED_CIDR=<cidr> $0"
    exit 1
fi

echo "Restricting all LoadBalancer services to $ALLOWED_CIDR ..."
kubectl get svc -A -o json \
  | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
  | while read -r ns name; do
        echo "  patching $ns/$name"
        kubectl -n "$ns" patch svc "$name" --type merge \
            -p "{\"spec\":{\"loadBalancerSourceRanges\":[\"$ALLOWED_CIDR\"]}}"
    done

echo "Allowing $ALLOWED_CIDR ingress to the dev/production app pods..."
for ns in dev production; do
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-office-cidr
  namespace: $ns
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: $ALLOWED_CIDR
EOF
done

echo "-----------------------------------------------------------------"
echo "Network hardening applied. LoadBalancers now accept only $ALLOWED_CIDR."
echo "NOTE: the self-healing webhook Dynatrace(SaaS) -> AWX needs Dynatrace's"
echo "egress IPs allowed too. Add them to ALLOWED_CIDR set, or front AWX with a"
echo "Dynatrace ActiveGate, otherwise remediation calls from Dynatrace will be blocked."
echo "-----------------------------------------------------------------"

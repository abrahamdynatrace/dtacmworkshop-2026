#!/bin/bash
#
# Deploy Jenkins to the cluster and create the DeploySockShop pipeline job.
#
# 2026 update:
#   - kubectl create -> apply (idempotent re-runs).
#   - Replaced the fixed "sleep 120" waits with real readiness / LoadBalancer-IP polling.
#   - Dropped `kubectl exec -it` (the -i/-t TTY flags fail in non-interactive scripts / Cloud Shell).
#   - RBAC manifest bumped to rbac.authorization.k8s.io/v1 (see manifests/jenkins/k8s-jenkins-rbac.yaml).
#
set -euo pipefail

kubectl apply -f ../manifests/jenkins/k8s-jenkins-ns.yaml
kubectl apply -f ../manifests/jenkins/k8s-jenkins-pvcs.yaml
kubectl apply -f ../manifests/jenkins/k8s-jenkins-deployment.yaml
kubectl apply -f ../manifests/jenkins/k8s-jenkins-rbac.yaml
kubectl apply -f ../manifests/jenkins/k8s-jenkins-secret.yaml

echo "Waiting for the Jenkins pod to become ready..."
kubectl -n cicd rollout status deploy/jenkins-deployment --timeout=300s

echo "Waiting for the Jenkins LoadBalancer external IP..."
JENKINS_URL=""
for i in $(seq 1 60); do
    JENKINS_URL=$(kubectl -n cicd get svc jenkins -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "$JENKINS_URL" ] && break
    echo "  ...still waiting ($i/60)"; sleep 10
done
if [ -z "$JENKINS_URL" ]; then
    echo "Timed out waiting for the Jenkins LoadBalancer IP. Check: kubectl -n cicd get svc jenkins"
    exit 1
fi

JENKINS_URL_PORT=24711
JENKINS_USERNAME_DECODE=$(kubectl get secret jenkins-secret -n cicd -o jsonpath='{.data.username}' | base64 --decode)
JENKINS_PASSWORD_DECODE=$(kubectl get secret jenkins-secret -n cicd -o jsonpath='{.data.password}' | base64 --decode)
K8S_MASTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's~https\?://~~')
JENKINS_POD=$(kubectl get po -n cicd --no-headers -o custom-columns=:metadata.name | head -n1)
POD_IP=$(kubectl get pod "$JENKINS_POD" -n cicd -o jsonpath='{.status.podIP}')

# Patch the baked-in job config inside the running Jenkins pod (no TTY).
kubectl exec -n cicd "$JENKINS_POD" -- sed -i "s/JENKINS_SERVER_PLACEHOLDER/https:\/\/$K8S_MASTER/g" /var/jenkins_home/config.xml
kubectl exec -n cicd "$JENKINS_POD" -- sed -i "s/JENKINS_URL_PLACEHOLDER/http:\/\/$POD_IP:8080/g" /var/jenkins_home/config.xml

echo "Creating the DeploySockShop pipeline job..."
curl -s -X POST "http://$JENKINS_URL:$JENKINS_URL_PORT/createItem?name=DeploySockShop" \
    -u "$JENKINS_USERNAME_DECODE:$JENKINS_PASSWORD_DECODE" \
    --data-binary @config.xml -H "Content-Type:text/xml"

echo "Restarting Jenkins to load the new job..."
curl -s -X POST "http://$JENKINS_URL:$JENKINS_URL_PORT/restart" \
    -u "$JENKINS_USERNAME_DECODE:$JENKINS_PASSWORD_DECODE" || true

echo "----------------------------------------------------"
echo "Jenkins is running at : http://$JENKINS_URL:$JENKINS_URL_PORT"
echo "Username : $JENKINS_USERNAME_DECODE"
echo "Password : $JENKINS_PASSWORD_DECODE"
echo "----------------------------------------------------"

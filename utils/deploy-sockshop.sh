#!/bin/bash

# Deploy SockShop to dev and production namespaces
kubectl apply -f ../manifests/k8s-namespaces.yml

kubectl apply -f ../manifests/backend-services/user-db/dev/
kubectl apply -f ../manifests/backend-services/user-db/production/

kubectl apply -f ../manifests/backend-services/shipping-rabbitmq/dev/
kubectl apply -f ../manifests/backend-services/shipping-rabbitmq/production/

kubectl apply -f ../manifests/backend-services/carts-db/

kubectl apply -f ../manifests/backend-services/catalogue-db/

kubectl apply -f ../manifests/backend-services/orders-db/

kubectl apply -f ../manifests/sockshop-app/dev/
kubectl apply -f ../manifests/sockshop-app/production/

#Create RoleBinding View to pull labels and annotations for dev namespace (idempotent)
kubectl -n dev create rolebinding default-view --clusterrole=view --serviceaccount=dev:default \
    --dry-run=client -o yaml | kubectl apply -f -

#Create RoleBinding View to pull labels and annotations for prod namespace (idempotent)
kubectl -n production create rolebinding default-view --clusterrole=view --serviceaccount=production:default \
    --dry-run=client -o yaml | kubectl apply -f -

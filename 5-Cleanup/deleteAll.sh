#!/bin/bash
#
# Delete the entire GKE cluster (and everything on it).
#
# 2026 update: removed the classic ActiveGate de-registration (utils/deleteagConfiguration.sh)
# and the ActiveGate GCE VM deletion - the DynaKube ActiveGate de-registers automatically when
# the cluster is deleted.
set -uo pipefail

GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:-acmworkshop}"
GKE_ZONE="${GKE_ZONE:-us-central1-a}"

gcloud container clusters delete "$GKE_CLUSTER_NAME" --zone="$GKE_ZONE" -q

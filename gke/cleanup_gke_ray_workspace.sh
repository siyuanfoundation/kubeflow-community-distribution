#!/usr/bin/env bash

# ==============================================================================
# Automated Cleanup Script for Kubeflow Workspace & Ray on GKE
# ==============================================================================
# This script cleanly tears down the Kubeflow Workspace, RayCluster, GKE
# Dashboard overlay, and associated namespaces.

set -euo pipefail

USER_NS="kubeflow-user-example-com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
GKE_OVERLAY="${SCRIPT_DIR}/gke-dashboard-workspace"

echo "=========================================================================="
echo " 🧹 Tearing down Kubeflow Workspace + Distributed Ray on GKE"
echo "=========================================================================="

# Step 1: Clean up User Workloads (Workspace, PVC, RayClusters, WorkspaceKind)
echo "=== Step 1: Deleting User Workload Manifests ==="
kubectl delete -f "${MANIFESTS_DIR}/05-workspace.yaml" --ignore-not-found --wait=false || true
kubectl delete -f "${MANIFESTS_DIR}/04-workspace-pvc.yaml" --ignore-not-found --wait=false || true
kubectl delete rayclusters --all -n "${USER_NS}" --ignore-not-found --wait=false || true
kubectl delete -f "${MANIFESTS_DIR}/02-workspacekind-jupyterlab.yaml" --ignore-not-found --wait=false || true
kubectl delete -f "${MANIFESTS_DIR}/01-user-namespace.yaml" --ignore-not-found --wait=false || true

# Step 2: Delete GKE Minimal Dashboard & Workspaces Overlay
echo "=== Step 2: Deleting GKE Dashboard & Workspaces Overlay ==="
kustomize build "${GKE_OVERLAY}" | kubectl delete -f - --ignore-not-found --wait=false || true

# Step 3: Delete Cert-Manager
echo "=== Step 3: Deleting Cert-Manager ==="
kustomize build "${DIST_ROOT}/common/cert-manager/base" | kubectl delete -f - --ignore-not-found --wait=false || true

# Step 4: Delete and Wait for Namespaces to Terminate Completely
echo "=== Step 4: Deleting System and User Namespaces ==="
NAMESPACES=("${USER_NS}" "kubeflow-workspaces" "istio-system" "kubeflow" "kubeflow-system" "cert-manager")

for ns in "${NAMESPACES[@]}"; do
  kubectl delete namespace "${ns}" --ignore-not-found --wait=false || true
done

echo "Waiting for all deleted namespaces to terminate completely..."
for i in {1..30}; do
  REMAINING=0
  for ns in "${NAMESPACES[@]}"; do
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
      REMAINING=$((REMAINING + 1))
    fi
  done
  if [[ ${REMAINING} -eq 0 ]]; then
    echo "All namespaces terminated cleanly."
    break
  fi
  sleep 2
done

echo "=========================================================================="
echo " 🧼 Cleanup Completed Successfully!"
echo "=========================================================================="

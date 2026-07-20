#!/usr/bin/env bash

# ==============================================================================
# Automated Deployment Script for Kubeflow Workspace on GKE
# ==============================================================================
# This script deploys the dedicated GKE Minimal Dashboard & Workspaces overlay,
# registers the custom JupyterLab WorkspaceKind, and deploys the Workspace.
# The RayCluster is created directly from inside the JupyterLab Notebook!

set -euo pipefail

# Configurable registry and image tag
export REGISTRY="${REGISTRY:-us-west1-docker.pkg.dev/sizhang-gke-dev/sizhang-repo}"
export TAG="${TAG:-v1}"
export JUPYTER_IMAGE="${REGISTRY}/jupyter-custom:${TAG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
GKE_OVERLAY="${SCRIPT_DIR}/gke-dashboard-workspace"

echo "=========================================================================="
echo " 🚀 Deploying Kubeflow Workspace on GKE (RayCluster created from Notebook)"
echo " Registry:      ${REGISTRY}"
echo " Image Tag:     ${TAG}"
echo " Jupyter Image: ${JUPYTER_IMAGE}"
echo " GKE Overlay:   ${GKE_OVERLAY}"
echo " Manifests Dir: ${MANIFESTS_DIR}"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# Step 1: Authenticate Docker to GCP Artifact Registry
# ------------------------------------------------------------------------------
echo "=== Step 1: Authenticating Docker to Artifact Registry ==="
REGISTRY_HOST="$(echo "${REGISTRY}" | cut -d'/' -f1)"
gcloud auth configure-docker "${REGISTRY_HOST}" --quiet || true

# ------------------------------------------------------------------------------
# Step 2: Build & Push Custom Jupyter Docker Image with Ray SDK
# ------------------------------------------------------------------------------
echo "=== Step 2: Building and Pushing Custom Jupyter Image ==="
docker build -t "${JUPYTER_IMAGE}" -f "${SCRIPT_DIR}/jupyter-custom.Dockerfile" "${SCRIPT_DIR}"
docker push "${JUPYTER_IMAGE}"

# ------------------------------------------------------------------------------
# Step 3: Configure GKE StorageClasses
# ------------------------------------------------------------------------------
echo "=== Step 3: Labeling and Annotating GKE StorageClasses ==="
kubectl label storageclass standard-rwo "notebooks.kubeflow.org/can-use=true" --overwrite=true || true
kubectl annotate storageclass standard-rwo \
  "notebooks.kubeflow.org/display-name=Standard RWO (Persistent Disk)" \
  "notebooks.kubeflow.org/description=Compute Engine persistent disk storage on GKE." \
  --overwrite=true || true
kubectl label storageclass standard "notebooks.kubeflow.org/can-use=true" --overwrite=true || true

# ------------------------------------------------------------------------------
# Step 4: Deploy Cert-Manager
# ------------------------------------------------------------------------------
echo "=== Step 4: Deploying Cert-Manager ==="
kustomize build "${DIST_ROOT}/common/cert-manager/base" | kubectl apply --server-side --force-conflicts -f -
echo "Waiting for cert-manager-webhook rollout..."
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
sleep 5

# ------------------------------------------------------------------------------
# Step 5: Deploy GKE Minimal Dashboard & Workspaces Kustomize Overlay
# ------------------------------------------------------------------------------
echo "=== Step 5: Deploying GKE Minimal Dashboard and Workspaces Overlay ==="
for i in {1..5}; do
  if kustomize build "${GKE_OVERLAY}" | kubectl apply --server-side --force-conflicts -f -; then
    echo "GKE Minimal Dashboard and Workspaces overlay applied successfully."
    break
  fi
  echo "  (attempt ${i}/5) establishing CRDs and namespaces, retrying in 5s..."
  sleep 5
done

echo "Waiting for Control Plane deployments to be ready..."
kubectl rollout status deployment/istiod -n istio-system --timeout=120s
kubectl rollout status deployment/workspaces-controller -n kubeflow-workspaces --timeout=120s
kubectl rollout status deployment/profiles-deployment -n kubeflow --timeout=120s

# ------------------------------------------------------------------------------
# Step 6: Deploy User Namespace & Ensure default-editor ServiceAccount Exists
# ------------------------------------------------------------------------------
echo "=== Step 6: Initializing User Namespace & default-editor ServiceAccount ==="
USER_NS="kubeflow-user-example-com"
kubectl apply -f "${MANIFESTS_DIR}/01-user-namespace.yaml"

echo "Waiting for default-editor ServiceAccount in ${USER_NS}..."
for i in {1..30}; do
  if kubectl get serviceaccount default-editor -n "${USER_NS}" >/dev/null 2>&1; then
    echo "ServiceAccount default-editor is ready in ${USER_NS}!"
    break
  fi
  echo "  (attempt ${i}/30) waiting for default-editor ServiceAccount in ${USER_NS}..."
  sleep 2
done

# ------------------------------------------------------------------------------
# Step 7: Deploy WorkspaceKind, PVC, and Workspace Manifests (RayCluster from Notebook)
# ------------------------------------------------------------------------------
echo "=== Step 7: Deploying WorkspaceKind, PVC, and Workspace ==="
for i in {1..5}; do
  if kubectl apply -f "${MANIFESTS_DIR}/02-workspacekind-jupyterlab.yaml" && \
     kubectl apply -f "${MANIFESTS_DIR}/04-workspace-pvc.yaml" && \
     kubectl apply -f "${MANIFESTS_DIR}/05-workspace.yaml"; then
    echo "User workspace manifests applied successfully."
    break
  fi
  echo "  (attempt ${i}/5) waiting for Workspaces admission webhook readiness, retrying in 3s..."
  sleep 3
done

# ------------------------------------------------------------------------------
# Step 8: Wait for Workspace Pod & Copy Demo Notebook
# ------------------------------------------------------------------------------
echo "=== Step 8: Waiting for Workspace Pod to be Running ==="
for i in {1..30}; do
  STATE=$(kubectl get workspace jupyter-ray-workspace -n "${USER_NS}" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
  if [[ "${STATE}" == "Running" ]]; then
    echo "Workspace jupyter-ray-workspace is Running!"
    break
  fi
  echo "  (attempt ${i}/30) Workspace state: '${STATE}', waiting 5s..."
  sleep 5
done

WS_POD=""
for i in {1..15}; do
  WS_POD=$(kubectl get pods -n "${USER_NS}" -l notebooks.kubeflow.org/workspace-name=jupyter-ray-workspace -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "${WS_POD}" ]]; then
    break
  fi
  sleep 2
done

if [[ -n "${WS_POD}" ]]; then
  echo "Copying demo notebook into Workspace pod ${WS_POD}..."
  kubectl cp "${SCRIPT_DIR}/distributed_ray_demo.ipynb" "${USER_NS}/${WS_POD}:/home/jovyan/distributed_ray_demo.ipynb" -c main || true
fi

# ------------------------------------------------------------------------------
# Step 9: Retrieve Public LoadBalancer IP & Access Details
# ------------------------------------------------------------------------------
echo "=========================================================================="
echo " 🎉 Deployment Completed Successfully!"
echo "=========================================================================="

echo "Retrieving GKE LoadBalancer Public External IP..."
INGRESS_IP=""
for i in {1..20}; do
  INGRESS_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ -n "${INGRESS_IP}" ]]; then
    break
  fi
  sleep 3
done

if [[ -n "${INGRESS_IP}" ]]; then
  echo "🌐 Public Ingress IP: ${INGRESS_IP}"
  echo "  - Central Dashboard:  http://${INGRESS_IP}/"
  echo "  - Workspaces UI:      http://${INGRESS_IP}/workspaces/"
  echo "  - Direct JupyterLab:  http://${INGRESS_IP}/workspace/connect/${USER_NS}/jupyter-ray-workspace/jupyterlab/"
  echo ""
  echo "📓 Open 'distributed_ray_demo.ipynb' in JupyterLab to dynamically create the RayCluster and run distributed tasks!"
else
  echo "GKE LoadBalancer External IP is still provisioning."
  echo "You can check status with: kubectl get svc istio-ingressgateway -n istio-system"
  echo "Or use local port-forward:"
  echo "  kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80"
  echo "  - Central Dashboard:  http://localhost:8080/"
  echo "  - Workspaces UI:      http://localhost:8080/workspaces/"
  echo "  - Direct JupyterLab:  http://localhost:8080/workspace/connect/${USER_NS}/jupyter-ray-workspace/jupyterlab/"
fi
echo "=========================================================================="

#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKING_DIRECTORY="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure kustomize is installed
if ! command -v kustomize &> /dev/null; then
    echo "kustomize not found. Installing..."
    "${WORKING_DIRECTORY}/tests/kustomize_install.sh"
fi

CLUSTER_NAME="kubeflow-standalone"
NODE_IMAGE="kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5"
TEMPORARY_MANIFEST_DIRECTORY="${WORKING_DIRECTORY}/temporary_manifests"

# Function to clean up temporary manifest directory
cleanup() {
    if [ -d "${TEMPORARY_MANIFEST_DIRECTORY}" ]; then
        echo "Cleaning up temporary manifest directory..."
        rm -rf "${TEMPORARY_MANIFEST_DIRECTORY}"
    fi
}
trap cleanup EXIT

# 1. Recreate cluster if it already exists
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "KinD cluster ${CLUSTER_NAME} already exists. Deleting it..."
    kind delete cluster --name "${CLUSTER_NAME}"
fi

# 2. Create KinD cluster
echo "Creating KinD cluster..."
kind create cluster --name "${CLUSTER_NAME}" --image "${NODE_IMAGE}" --wait 120s

# 3. Create core namespaces
echo "Creating namespaces..."
kubectl create namespace kubeflow-workspaces
kubectl create namespace istio-system
kubectl create namespace kubeflow

# 4. Deploy Cert-Manager
echo "Deploying cert-manager..."
kustomize build "${WORKING_DIRECTORY}/common/cert-manager/base" | kubectl apply -f -
echo "Waiting for cert-manager-webhook to become ready..."
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s

# 5. Deploy Istio (Minimal configuration)
echo "Deploying Istio (Minimal)..."
kustomize build "${WORKING_DIRECTORY}/common/istio/istio-crds/base" | kubectl apply -f -
kustomize build "${WORKING_DIRECTORY}/common/istio/istio-namespace/base" | kubectl apply -f -
kustomize build "${WORKING_DIRECTORY}/common/istio/istio-install/base" | kubectl apply -f -
kustomize build "${WORKING_DIRECTORY}/common/istio/kubeflow-istio-resources/base" | kubectl apply -f -
echo "Waiting for Istio pods to become ready..."
kubectl wait --for=condition=Ready pods --all -n istio-system --timeout 180s

# 6. Deploy Workspaces Controller
echo "Deploying Workspaces Controller..."
kustomize build "${WORKING_DIRECTORY}/applications/workspaces/overlays/istio" | kubectl apply -f -
echo "Waiting for workspaces-controller to become ready..."
kubectl wait --for=condition=Available deployment/workspaces-controller -n kubeflow-workspaces --timeout=300s

# 7. Create standalone workspace namespace and ServiceAccount
echo "Creating user namespace..."
NAMESPACE_NAME="my-workspace-namespace"
kubectl create namespace "${NAMESPACE_NAME}"
kubectl create serviceaccount default-editor -n "${NAMESPACE_NAME}"
kubectl label namespace "${NAMESPACE_NAME}" pod-security.kubernetes.io/enforce=baseline --overwrite

# 8. Apply WorkspaceKind
echo "Applying WorkspaceKind..."
kubectl apply -f "${WORKING_DIRECTORY}/applications/workspaces/upstream/controller/samples/jupyterlab_v1beta1_workspacekind.yaml"

# 9. Create Workspace and PersistentVolumeClaim
echo "Creating Workspace..."
mkdir -p "${TEMPORARY_MANIFEST_DIRECTORY}"
cat <<EOF > "${TEMPORARY_MANIFEST_DIRECTORY}/workspace-manifest.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: workspace-home-pvc
  namespace: ${NAMESPACE_NAME}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
apiVersion: kubeflow.org/v1beta1
kind: Workspace
metadata:
  name: jupyter-workspace
  namespace: ${NAMESPACE_NAME}
spec:
  paused: false
  kind: "jupyterlab"
  podTemplate:
    volumes:
      home: "workspace-home-pvc"
    options:
      imageConfig: "jupyter-scipy:v1.10.0"
      podConfig: "tiny_cpu"
EOF

kubectl apply -f "${TEMPORARY_MANIFEST_DIRECTORY}/workspace-manifest.yaml"

# 10. Verify workspace pod execution
echo "Waiting for Workspace to become Running..."
kubectl wait --for=jsonpath='{.status.state}'=Running workspace/jupyter-workspace -n "${NAMESPACE_NAME}" --timeout=600s

echo "Standalone Workspaces deployment completed and verified successfully!"

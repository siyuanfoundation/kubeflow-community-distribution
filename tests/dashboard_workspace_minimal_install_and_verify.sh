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

# Support cleanup execution mode
if [[ "${1:-}" == "--cleanup" || "${1:-}" == "destroy" ]]; then
    echo "Running cleanup..."
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        echo "Deleting KinD cluster ${CLUSTER_NAME}..."
        kind delete cluster --name "${CLUSTER_NAME}"
    else
        echo "KinD cluster ${CLUSTER_NAME} does not exist. No actions taken."
    fi
    exit 0
fi


# 1. Recreate cluster if it already exists
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "KinD cluster ${CLUSTER_NAME} already exists. Deleting it..."
    kind delete cluster --name "${CLUSTER_NAME}"
fi

# 2. Create KinD cluster
echo "Creating KinD cluster..."
kind create cluster --name "${CLUSTER_NAME}" --image "${NODE_IMAGE}" --wait 120s

# 2.1 Configure default StorageClass for Workspaces
echo "Configuring default StorageClass..."
kubectl label storageclass standard "notebooks.kubeflow.org/can-use=true" --overwrite
kubectl annotate storageclass standard \
  "notebooks.kubeflow.org/display-name=Standard (Local Path)" \
  "notebooks.kubeflow.org/description=Local path provisioner for development. Data is stored on the node and not replicated." \
  --overwrite

# 3. Create namespaces and label for Istio sidecar injection
echo "Creating namespaces..."
kubectl create namespace kubeflow-workspaces || true
kubectl label namespace kubeflow-workspaces istio-injection=enabled --overwrite
kubectl create namespace istio-system || true
kubectl create namespace kubeflow || true
kubectl label namespace kubeflow istio-injection=enabled --overwrite

# 4. Deploy Cert-Manager
echo "Deploying cert-manager..."
kustomize build "${WORKING_DIRECTORY}/common/cert-manager/base" | kubectl apply -f -
echo "Waiting for cert-manager-webhook to become ready..."
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s

# 5. Deploy CRDs first and wait for them to be established
echo "Deploying CRDs first..."
kustomize build "${WORKING_DIRECTORY}/common/istio/istio-crds/base" | kubectl apply -f -
kubectl apply -f "${WORKING_DIRECTORY}/applications/dashboard/upstream/profile-controller/base/crd/kubeflow.org_profiles.yaml"
kubectl apply -f "${WORKING_DIRECTORY}/applications/dashboard/upstream/poddefaults-webhooks/base/crd.yaml"
kustomize build "${WORKING_DIRECTORY}/applications/workspaces/upstream/controller/base/crd" | kubectl apply -f -

echo "Waiting for CRDs to be established..."
kubectl wait --for=condition=Established crd/gateways.networking.istio.io --timeout=60s
kubectl wait --for=condition=Established crd/virtualservices.networking.istio.io --timeout=60s
kubectl wait --for=condition=Established crd/destinationrules.networking.istio.io --timeout=60s
kubectl wait --for=condition=Established crd/sidecars.networking.istio.io --timeout=60s
kubectl wait --for=condition=Established crd/authorizationpolicies.security.istio.io --timeout=60s
kubectl wait --for=condition=Established crd/profiles.kubeflow.org --timeout=60s
kubectl wait --for=condition=Established crd/poddefaults.kubeflow.org --timeout=60s
kubectl wait --for=condition=Established crd/workspaces.kubeflow.org --timeout=60s
kubectl wait --for=condition=Established crd/workspacekinds.kubeflow.org --timeout=60s

# 6. Deploy Istio core infrastructure first
echo "Deploying Istio core infrastructure..."
kustomize build "${WORKING_DIRECTORY}/common/istio/istio-namespace/base" | kubectl apply -f -
kustomize build "${WORKING_DIRECTORY}/common/istio/istio-install/base" | kubectl apply -f -
kustomize build "${WORKING_DIRECTORY}/common/istio/kubeflow-istio-resources/base" | kubectl apply -f -
kubectl apply -f "${WORKING_DIRECTORY}/experimental/minimal-dashboard-workspace/envoy-filter.yaml"

echo "Waiting for Istio Control Plane (istiod) and Ingress Gateway to be ready..."
kubectl wait --for=condition=Available deployment/istiod -n istio-system --timeout 180s
kubectl wait --for=condition=Ready pods -l app=istio-ingressgateway -n istio-system --timeout 180s

# 7. Deploy Dashboard, Workspaces, and user namespaces
echo "Deploying Dashboard, Workspaces, and user namespaces..."
kustomize build "${WORKING_DIRECTORY}/experimental/minimal-dashboard-workspace" | kubectl apply -f -

# 8. Wait for Core Components to become ready
echo "Waiting for Central Dashboard to be ready..."
kubectl wait --for=condition=Available deployment/dashboard -n kubeflow --timeout=300s

echo "Waiting for Profile Controller to be ready..."
kubectl wait --for=condition=Available deployment/profiles-deployment -n kubeflow --timeout=300s

echo "Waiting for Workspaces Controller to be ready..."
kubectl wait --for=condition=Available deployment/workspaces-controller -n kubeflow-workspaces --timeout=300s

echo "Waiting for Workspaces Backend to be ready..."
kubectl wait --for=condition=Available deployment/workspaces-backend -n kubeflow-workspaces --timeout=300s

echo "Waiting for Workspaces Frontend to be ready..."
kubectl wait --for=condition=Available deployment/workspaces-frontend -n kubeflow-workspaces --timeout=300s

# 9. Apply WorkspaceKind
echo "Applying WorkspaceKind..."
kubectl apply -f "${WORKING_DIRECTORY}/applications/workspaces/upstream/controller/samples/jupyterlab_v1beta1_workspacekind.yaml"

# 10. Verify the Profile Namespace was initialized
echo "Waiting for default profile namespace (kubeflow-user-example-com) to be created by the profile controller..."
for i in {1..30}; do
    if kubectl get namespace kubeflow-user-example-com &>/dev/null; then
        echo "Namespace kubeflow-user-example-com is created!"
        break
    fi
    sleep 2
done

if ! kubectl get namespace kubeflow-user-example-com &>/dev/null; then
    echo "Error: Namespace kubeflow-user-example-com was not created."
    exit 1
fi

echo "Verifying default-editor ServiceAccount exists in user namespace..."
kubectl wait --for=jsonpath='{.metadata.name}'=default-editor serviceaccount/default-editor -n kubeflow-user-example-com --timeout=60s

# 11. Create Workspace and PersistentVolumeClaim
echo "Creating Workspace..."
mkdir -p "${TEMPORARY_MANIFEST_DIRECTORY}"
cat <<EOF > "${TEMPORARY_MANIFEST_DIRECTORY}/workspace-manifest.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: workspace-home-pvc
  namespace: kubeflow-user-example-com
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
  namespace: kubeflow-user-example-com
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

# 12. Verify workspace pod execution
echo "Waiting for Workspace to become Running..."
kubectl wait --for=jsonpath='{.status.state}'=Running workspace/jupyter-workspace -n kubeflow-user-example-com --timeout=300s

echo "Minimal Dashboard and Workspaces deployment completed and verified successfully!"
echo ""
echo "========================================================================="
echo "How to connect:"
echo "========================================================================="
echo "1. Port-forward the ingress gateway:"
echo "   kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80"
echo ""
echo "2. Open the Central Dashboard in your browser:"
echo "   http://localhost:8080/"
echo ""
echo "3. Connect directly to the Jupyter notebook server:"
echo "   http://localhost:8080/workspace/connect/kubeflow-user-example-com/jupyter-workspace/jupyterlab/"
echo "========================================================================="

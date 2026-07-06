# Standalone Workspaces Deployment Guide

This guide describes how to deploy the Kubeflow Workspaces (Notebooks 2.0) controller on a local Kubernetes in Docker (KinD) cluster without the full multi-tenancy and authentication stack.

---

## Prerequisites
Before beginning the deployment, ensure the following parameters and tools are configured:
- **System Settings**: Increase the inotify limits to handle a high volume of pods and watches:
  ```bash
  sudo sysctl fs.inotify.max_user_instances=2280
  sudo sysctl fs.inotify.max_user_watches=1255360
  ```
- **CLI Tools**: Ensure `kind`, `kubectl`, and `kustomize` are installed on your host system.

---

## Step 1: Create the KinD Cluster
Create a standard cluster named `kubeflow-standalone`:
```bash
kind create cluster --name kubeflow-standalone --wait 120s
```

---

## Step 2: Establish Namespaces and Core Infrastructure
1. Create the system namespaces:
   ```bash
   kubectl create namespace kubeflow-workspaces
   kubectl create namespace istio-system
   kubectl create namespace kubeflow
   ```

2. Deploy `cert-manager` for admission webhook certificate configuration:
   ```bash
   kustomize build common/cert-manager/base | kubectl apply -f -
   kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
   ```

3. Install Istio custom resource definitions, the core ingress plane, and the Kubeflow gateway:
   ```bash
   kustomize build common/istio/istio-crds/base | kubectl apply -f -
   kustomize build common/istio/istio-namespace/base | kubectl apply -f -
   kustomize build common/istio/istio-install/base | kubectl apply -f -
   kustomize build common/istio/kubeflow-istio-resources/base | kubectl apply -f -
   ```

---

## Step 3: Deploy the Workspaces Controller
1. Apply the controller overlay with Istio integration:
   ```bash
   kustomize build applications/workspaces/overlays/istio | kubectl apply -f -
   ```

2. Verify the Workspaces deployment status:
   ```bash
   kubectl wait --for=condition=Available deployment/workspaces-controller -n kubeflow-workspaces --timeout=300s
   ```

---

## Step 4: Configure the Workspace Namespace
Because the Profile Controller is not deployed, you must manually set up the workspace namespace and service account.

1. Create a namespace:
   ```bash
   kubectl create namespace my-workspace-namespace
   ```

2. Create the `default-editor` ServiceAccount expected by the workspace template:
   ```bash
   kubectl create serviceaccount default-editor -n my-workspace-namespace
   ```

3. Label the namespace to enforce the baseline Pod Security Standard:
   ```bash
   kubectl label namespace my-workspace-namespace pod-security.kubernetes.io/enforce=baseline --overwrite
   ```

---

## Step 5: Define a WorkspaceKind and Launch a Workspace
1. Register the JupyterLab `WorkspaceKind` template:
   ```bash
   kubectl apply -f applications/workspaces/upstream/controller/samples/jupyterlab_v1beta1_workspacekind.yaml
   ```

2. Save the following manifest as `workspace-definition.yaml`:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: workspace-home-pvc
     namespace: my-workspace-namespace
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
     namespace: my-workspace-namespace
   spec:
     paused: false
     kind: "jupyterlab"
     podTemplate:
       volumes:
         home: "workspace-home-pvc"
       options:
         imageConfig: "jupyter-scipy:v1.10.0"
         podConfig: "tiny_cpu"
   ```

3. Apply the workspace manifest:
   ```bash
   kubectl apply -f workspace-definition.yaml
   ```

4. Wait for the workspace state to become `Running`:
   ```bash
   kubectl wait --for=jsonpath='{.status.state}'=Running workspace/jupyter-workspace -n my-workspace-namespace --timeout=600s
   ```

---

## Access the Workspace
Port-forward the Istio Ingress Gateway service to your local machine:
```bash
kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80
```
Navigate to your workspace in the web browser at:
```
http://localhost:8080/workspace/connect/my-workspace-namespace/jupyter-workspace/
```

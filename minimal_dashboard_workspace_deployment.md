# Minimal Dashboard and Workspaces Deployment Guide

This guide describes how to deploy the Kubeflow Central Dashboard and Workspaces (Notebooks 2.0) components on a local Kubernetes in Docker (KinD) cluster without multi-tenancy authentication layers (Dex and OAuth2 Proxy). It automatically sets up header injection to log the user in as a default mock user (`user@example.com`).

---

## Architectural Context: Authentication Bypass
In standard Kubeflow deployments, user identity is verified at the ingress gateway by Dex (OIDC) and OAuth2-Proxy, which then inject the `kubeflow-userid` header into all downstream requests. The user namespace is protected by an Istio `AuthorizationPolicy` (`ns-owner-access-istio`) that denies any request without this header.

Since this minimal development environment runs without Dex and OAuth2-Proxy to reduce overhead, we bypass authentication by deploying a global `EnvoyFilter` on the `istio-ingressgateway`. This filter automatically injects the `kubeflow-userid: user@example.com` header on all incoming HTTP traffic, ensuring that the dashboard, backend services, and dynamically spawned workspaces authorize your connection.

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

Configure the default `standard` StorageClass so it is selectable in the Workspaces UI:
```bash
kubectl label storageclass standard "notebooks.kubeflow.org/can-use=true" --overwrite
kubectl annotate storageclass standard \
  "notebooks.kubeflow.org/display-name=Standard (Local Path)" \
  "notebooks.kubeflow.org/description=Local path provisioner for development. Data is stored on the node and not replicated." \
  --overwrite
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

---

## Step 3: Deploy the Dashboard and Workspaces Custom Overlay
Deploy the aggregated minimal dashboard and workspaces overlay:
```bash
kustomize build experimental/minimal-dashboard-workspace | kubectl apply -f -
```

Wait for all core services to roll out and reach a healthy state:
```bash
kubectl wait --for=condition=Ready pods -l app=istio-ingressgateway -n istio-system --timeout 180s
kubectl wait --for=condition=Available deployment/dashboard -n kubeflow --timeout=300s
kubectl wait --for=condition=Available deployment/profiles-deployment -n kubeflow --timeout=300s
kubectl wait --for=condition=Available deployment/workspaces-controller -n kubeflow-workspaces --timeout=300s
kubectl wait --for=condition=Available deployment/workspaces-backend -n kubeflow-workspaces --timeout=300s
kubectl wait --for=condition=Available deployment/workspaces-frontend -n kubeflow-workspaces --timeout=300s
```

---

## Step 4: Define a WorkspaceKind
Register the JupyterLab `WorkspaceKind` template:
```bash
kubectl apply -f applications/workspaces/upstream/controller/samples/jupyterlab_v1beta1_workspacekind.yaml
```

The Profile Controller automatically reconciles the default Profile and creates the namespace `kubeflow-user-example-com` (with `default-editor` ServiceAccount and the correct baseline pod security labels).

---

## Step 5: Access the Dashboard and Create a Workspace
1. Port-forward the Istio Ingress Gateway service to your local machine:
   ```bash
   kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80
   ```

2. Open your web browser and navigate to:
   ```
   http://localhost:8080/
   ```

3. You will be greeted by the Kubeflow Central Dashboard logged in as `user@example.com`. The namespace dropdown in the top-left will show `kubeflow-user-example-com`.

4. Click **Notebooks v2 -> Workspaces** in the left menu.

5. Click **New Workspace** inside the workspaces panel to spawn a notebook workspace by choosing configuration settings like `Tiny CPU` or `Small CPU`.

---

## Step 6: Create a Workspace directly via YAML Manifest
Alternatively, you can deploy a Workspace and its required PersistentVolumeClaim directly using a Kubernetes manifest:

1. Create a file named `workspace.yaml`:
   ```yaml
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
   ```

2. Apply the manifest:
   ```bash
   kubectl apply -f workspace.yaml
   ```

3. Verify it reaches the `Running` state:
   ```bash
   kubectl wait --for=jsonpath='{.status.state}'=Running workspace/jupyter-workspace -n kubeflow-user-example-com --timeout=300s
   ```

---

## Step 7: Connect directly to the Jupyter Notebook
If you want to bypass the dashboard UI and connect to your notebook server directly, you can access it via the Istio Ingress Gateway port-forward:

1. Ensure the gateway is port-forwarded:
   ```bash
   kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80
   ```

2. Open your web browser and navigate to the connection URL matching your workspace's namespace, name, and port (e.g., `jupyterlab`):
   ```
   http://localhost:8080/workspace/connect/kubeflow-user-example-com/jupyter-workspace/jupyterlab/
   ```

---

## Step 8: Clean Up Resources

To clean up and remove the deployed services and configurations, you can choose one of the following methods depending on whether you want to preserve the underlying cluster:

### Option A: Complete Cluster Teardown (Recommended)
If you created the KinD cluster specifically for this installation, deleting the cluster is the fastest and cleanest way to remove all resources:
```bash
kind delete cluster --name kubeflow-standalone
```
Alternatively, if you deployed the cluster using the automated setup script, you can execute the script with the `destroy` argument to clean up the KinD cluster:
```bash
./tests/dashboard_workspace_minimal_install_and_verify.sh destroy
```

### Option B: Delete Manifests Only
If you are running on an existing Kubernetes cluster and want to remove only the Kubeflow resources:

1. Delete the Workspace instance and PVC:
   ```bash
   kubectl delete workspace/jupyter-workspace -n kubeflow-user-example-com --ignore-not-found
   kubectl delete pvc/workspace-home-pvc -n kubeflow-user-example-com --ignore-not-found
   ```

2. Delete the minimal dashboard and workspaces overlay:
   ```bash
   kustomize build experimental/minimal-dashboard-workspace | kubectl delete -f -
   ```

3. Delete `cert-manager` core infrastructure:
   ```bash
   kustomize build common/cert-manager/base | kubectl delete -f -
   ```

4. Delete the namespaces (Note: Deleting the `kubeflow` namespace will also delete the Profile and automatically clean up associated user namespaces like `kubeflow-user-example-com`):
   ```bash
   kubectl delete namespace kubeflow-workspaces istio-system kubeflow
   ```

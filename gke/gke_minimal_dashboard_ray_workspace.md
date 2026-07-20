# Kubeflow Workspace with Distributed Ray Creation from JupyterLab on GKE

This guide explains how to deploy a lightweight **Kubeflow Central Dashboard & Workspaces (Notebooks 2.0)** stack on Google Kubernetes Engine (GKE) using a dedicated GKE Kustomize overlay, build a custom JupyterLab image with Ray & Kubernetes Python SDKs, and **dynamically create, coordinate, and tear down a RayCluster directly from inside the JupyterLab notebook**.

---

## 1. Architecture & Workflow Design

```
                          ┌────────────────────────┐
                          │   Istio IngressGateway │
                          │ (GKE LoadBalancer:     │
                          │  Public IP & Port 80)  │
                          └──────────┬─────────────┘
                                     │
                 ┌───────────────────┴───────────────────┐
                 │                                       │
        ┌────────▼────────┐                     ┌────────▼────────┐
        │ Kubeflow Central│                     │    Workspaces   │
        │    Dashboard    │                     │ Frontend/Backend│
        └─────────────────┘                     └────────┬────────┘
                                                         │
                                        ┌────────────────▼────────────────┐
                                        │  Kubeflow User Namespace        │
                                        │  (kubeflow-user-example-com)    │
                                        │                                 │
                                        │ ┌─────────────────────────────┐ │
                                        │ │ JupyterLab Workspace Pod    │ │
                                        │ │ (default-editor SA)         │ │
                                        │ └──────────────┬──────────────┘ │
                                        │                │                │
                                        │   1. client.CustomObjectsApi()  │
                                        │      creates RayCluster CR      │
                                        │   2. ray.init("ray://...:10001")│
                                        │   3. delete RayCluster CR       │
                                        │                │                │
                                        │ ┌──────────────▼──────────────┐ │
                                        │ │ Ray Head Pod & Service      │ │
                                        │ └──────┬──────────────┬───────┘ │
                                        │        │              │         │
                                        │ ┌──────▼──────┐┌──────▼──────┐  │
                                        │ │ Ray Worker 1││ Ray Worker 2│  │
                                        │ └─────────────┘└─────────────┘  │
                                        └─────────────────────────────────┘
```

### Key Highlights:
1. **Dynamic RayCluster Lifecycle from Python**: The user creates, monitors, uses, and deletes RayClusters directly from notebook cells via the Kubernetes Python SDK without needing shell access or separate `kubectl apply` commands.
2. **ServiceAccount RBAC Permissions**: The in-cluster `default-editor` ServiceAccount is bound to `kubeflow-kuberay-edit`, `kubeflow-edit`, and standard `edit` ClusterRoles, granting full CRUD authorization over RayCluster resources (`ray.io/v1`).
3. **Dedicated GKE Control Plane Overlay**: Handles GKE LoadBalancer external IP routing, removes CNI requirements for COS nodes, and configures plaintext Workspaces routing.

---

## 2. Directory & Manifests Structure

```
kubeflow-community-distribution/gke/
├── deploy_gke_ray_workspace.sh          # Automated deployment script
├── cleanup_gke_ray_workspace.sh         # Clean teardown script (guarantees clean cluster)
├── verify_ray_workspace.sh              # Automated test runner (creates & deletes RayCluster from notebook)
├── jupyter-custom.Dockerfile            # Custom Jupyter image with Ray SDK & kubectl CLI
├── distributed_ray_demo.ipynb           # Interactive demo Jupyter notebook
├── gke_minimal_dashboard_ray_workspace.md # This documentation
├── gke-dashboard-workspace/             # Dedicated GKE Control Plane Overlay
│   ├── kustomization.yaml               # Builds full control plane with GKE patches
│   ├── envoy-filter.yaml                # UI path prefix injection
│   └── patches/
│       ├── service-loadbalancer.yaml    # Ingress Gateway LoadBalancer
│       ├── workspaces-destinationrules.yaml # Plaintext DestinationRules (no 503/404)
│       ├── istio-sidecar-injector-gke.yaml  # ConfigMap patch disabling CNI
│       └── istio-values-gke.yaml            # Istio mesh values for GKE
└── manifests/                            # User Workload Manifests
    ├── 01-user-namespace.yaml           # User namespace + default-editor RBAC (RayCluster CRUD)
    ├── 02-workspacekind-jupyterlab.yaml # Registers WorkspaceKind with custom image
    ├── 04-workspace-pvc.yaml            # 5Gi PersistentVolumeClaim (standard-rwo)
    └── 05-workspace.yaml                # Deploys JupyterLab Workspace resource
```

---

## 3. Quick Start (Automated Lifecycle)

```bash
# 1. Clean up cluster to start completely from scratch
./kubeflow-community-distribution/gke/cleanup_gke_ray_workspace.sh

# 2. Deploy GKE Control Plane & Workspace
./kubeflow-community-distribution/gke/deploy_gke_ray_workspace.sh

# 3. Run automated verification (Notebook creates RayCluster, executes tasks, and deletes RayCluster)
./kubeflow-community-distribution/gke/verify_ray_workspace.sh
```

---

## 4. RayCluster Python API Lifecycle in JupyterLab

Inside the running JupyterLab workspace pod (`/home/jovyan/distributed_ray_demo.ipynb`):

### 1. Create RayCluster Resource
```python
import yaml, time
from kubernetes import client, config

config.load_incluster_config()
custom_api = client.CustomObjectsApi()
core_v1 = client.CoreV1Api()

namespace = "kubeflow-user-example-com"
cluster_name = "kubeflow-raycluster"

# Custom RayCluster manifest spec
manifest = { ... }

custom_api.create_namespaced_custom_object(
    group="ray.io",
    version="v1",
    namespace=namespace,
    plural="rayclusters",
    body=manifest
)
print("✅ RayCluster created successfully from notebook!")
```

### 2. Connect & Run Distributed Tasks
```python
import ray, socket

ray.init(address="ray://kubeflow-raycluster-head-svc:10001")

@ray.remote
def distributed_task(x):
    return {"input": x, "result": x * x, "node": socket.gethostname()}

futures = [distributed_task.remote(i) for i in range(8)]
print(ray.get(futures))
```

### 3. Teardown RayCluster
```python
ray.shutdown()

custom_api.delete_namespaced_custom_object(
    group="ray.io",
    version="v1",
    namespace=namespace,
    plural="rayclusters",
    name=cluster_name
)
print("✅ RayCluster deleted from notebook!")
```

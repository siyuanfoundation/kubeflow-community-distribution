#!/usr/bin/env bash

# ==============================================================================
# Automated Verification Script for RayCluster Creation & Deletion from Notebook
# ==============================================================================
# This script executes Python inside the running JupyterLab workspace pod to:
# 1. Create the RayCluster dynamically via Kubernetes in-cluster API.
# 2. Wait for RayCluster head and worker pods to become ready.
# 3. Connect via Ray Client (ray://kubeflow-raycluster-head-svc:10001).
# 4. Execute distributed tasks and stateful actors across multiple cluster nodes.
# 5. Delete the RayCluster dynamically from inside the notebook pod and wait for teardown.

set -euo pipefail

USER_NS="kubeflow-user-example-com"

echo "=========================================================================="
echo " 🧪 Verifying Kubeflow Workspace + RayCluster Lifecycle from Notebook"
echo "=========================================================================="

echo "--> Checking Workspace Pod in namespace '${USER_NS}'..."
WS_POD=""
for i in {1..30}; do
  WS_POD=$(kubectl get pods -n "${USER_NS}" -l notebooks.kubeflow.org/workspace-name=jupyter-ray-workspace -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "${WS_POD}" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${WS_POD}" ]]; then
  echo "❌ Error: Workspace pod not found in namespace ${USER_NS}"
  exit 1
fi

echo "Found Workspace Pod: ${WS_POD}"
kubectl wait --for=condition=Ready pod/"${WS_POD}" -n "${USER_NS}" --timeout=120s

echo "--> Executing Notebook RayCluster creation, distributed execution, and teardown inside pod '${WS_POD}'..."

kubectl exec -i "${WS_POD}" -n "${USER_NS}" -c main -- python3 -c '
import sys, time, os, socket, yaml
from kubernetes import client, config
import ray

print("======================================================================")
print(f"1. Ray Python SDK Version in Notebook Pod: {ray.__version__}")
print("======================================================================")

# Step A: Create RayCluster dynamically from inside the Workspace Pod
config.load_incluster_config()
custom_api = client.CustomObjectsApi()
core_v1 = client.CoreV1Api()

namespace = "kubeflow-user-example-com"
cluster_name = "kubeflow-raycluster"

raycluster_yaml = """
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: kubeflow-raycluster
  namespace: kubeflow-user-example-com
spec:
  rayVersion: "2.56.1"
  headGroupSpec:
    rayStartParams:
      num-cpus: "1"
      dashboard-host: "0.0.0.0"
    template:
      metadata:
        labels:
          sidecar.istio.io/inject: "false"
      spec:
        serviceAccountName: default-editor
        containers:
        - name: ray-head
          image: rayproject/ray:2.56.1-py311-cpu
          resources:
            limits:
              cpu: "1"
              memory: "2G"
            requests:
              cpu: "200m"
              memory: "512Mi"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
  workerGroupSpecs:
    - replicas: 2
      minReplicas: 1
      maxReplicas: 4
      groupName: worker-group
      rayStartParams:
        num-cpus: "1"
      template:
        metadata:
          labels:
            sidecar.istio.io/inject: "false"
        spec:
          serviceAccountName: default-editor
          containers:
          - name: ray-worker
            image: rayproject/ray:2.56.1-py311-cpu
            resources:
              limits:
                cpu: "1"
                memory: "1G"
              requests:
                cpu: "200m"
                memory: "512Mi"
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              runAsNonRoot: true
              seccompProfile:
                type: RuntimeDefault
"""

print(f"Creating RayCluster {cluster_name} from inside notebook pod via Kubernetes API...")
manifest = yaml.safe_load(raycluster_yaml)
try:
    custom_api.create_namespaced_custom_object(
        group="ray.io",
        version="v1",
        namespace=namespace,
        plural="rayclusters",
        body=manifest
    )
    print(f"✅ RayCluster {cluster_name} created successfully from inside notebook!")
except client.exceptions.ApiException as e:
    if e.status == 409:
        print(f"ℹ️ RayCluster {cluster_name} already exists.")
    else:
        raise e

# Step B: Wait for Ray pods to be Running
print("\nWaiting for RayCluster pods (1 Head + 2 Workers) to be Running...")
for i in range(40):
    pods = core_v1.list_namespaced_pod(namespace=namespace, label_selector=f"ray.io/cluster={cluster_name}")
    running = [p.metadata.name for p in pods.items if p.status.phase == "Running"]
    if len(running) >= 3:
        print(f"✅ All 3 RayCluster pods running: {running}")
        break
    time.sleep(3)

# Step C: Connect via Ray Client and run distributed tasks
ray_head_address = "ray://kubeflow-raycluster-head-svc:10001"
print(f"\nConnecting to RayCluster at {ray_head_address} ...")
ray.init(address=ray_head_address)
resources = ray.cluster_resources()
cpus = resources.get("CPU", 0)
mem_gb = resources.get("memory", 0) / (1024**3)
print(f"Connection Successful! Total Cluster CPUs: {cpus}, Memory: {mem_gb:.2f} GB")

@ray.remote
def square(x):
    time.sleep(0.1)
    return {"input": x, "result": x * x, "node": socket.gethostname(), "pid": os.getpid()}

print("\n2. Executing 8 Distributed Remote Tasks...")
futures = [square.remote(i) for i in range(8)]
results = ray.get(futures)

nodes = set()
for r in results:
    nodes.add(r["node"])
    inp = r["input"]
    res = r["result"]
    nd = r["node"]
    pd = r["pid"]
    print(f"   -> Input: {inp:2d} | Result: {res:3d} | Computed on Node: {nd} (PID {pd})")

print(f"\nTasks executed across {len(nodes)} distinct nodes in the RayCluster: {nodes}")

@ray.remote
class StateCounter:
    def __init__(self, name):
        self.name = name
        self.val = 0
        self.host = socket.gethostname()
    def inc(self, n=1):
        self.val += n
        return self.val
    def info(self):
        return {"name": self.name, "val": self.val, "node": self.host}

print("\n3. Executing Distributed Stateful Ray Actors...")
actors = [StateCounter.remote(f"worker_actor_{i}") for i in range(4)]
ray.get([a.inc.remote(10) for a in actors])
states = ray.get([a.info.remote() for a in actors])
for s in states:
    nm = s["name"]
    nd = s["node"]
    vl = s["val"]
    print(f"   -> Actor [{nm}] on Node [{nd}] -> New Count = {vl}")

# Step D: Teardown and delete RayCluster from inside notebook
print("\n4. Deleting RayCluster from inside notebook pod...")
ray.shutdown()
try:
    custom_api.delete_namespaced_custom_object(
        group="ray.io",
        version="v1",
        namespace=namespace,
        plural="rayclusters",
        name=cluster_name
    )
    print(f"✅ RayCluster {cluster_name} deletion requested.")
except client.exceptions.ApiException as e:
    if e.status != 404:
        raise e

print("Waiting for RayCluster pods to terminate...")
for i in range(30):
    pods = core_v1.list_namespaced_pod(namespace=namespace, label_selector=f"ray.io/cluster={cluster_name}")
    if len(pods.items) == 0:
        print(f"✅ All RayCluster pods terminated cleanly!")
        break
    time.sleep(3)

if len(nodes) > 1:
    print("\n" + "="*70)
    print(" ✅ SUCCESS: Full RayCluster lifecycle from notebook verified!")
    print("="*70)
else:
    print("❌ Error: Tasks did not distribute across nodes.")
    sys.exit(1)
'

echo ""
echo "All validation checks passed successfully!"

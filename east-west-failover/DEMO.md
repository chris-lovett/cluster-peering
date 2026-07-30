# East-West Service Failover Demo

**Environment:** Consul Enterprise 2.0.1-ent · OpenShift · Kubernetes CRD-based peering

This demo shows automatic east-west traffic failover across a cluster peering boundary. Under normal conditions, `frontend` on cluster-01 calls a local `backend` (the primary). When the primary becomes unhealthy, a `ServiceResolver` on cluster-01 automatically redirects traffic to `backend` on cluster-02 (the failover target) — no application changes, no manual intervention.

---

## Topology

```
  cluster-01  (DIALER)                      cluster-02  (ACCEPTOR)
  ┌──────────────────────────────┐               ┌──────────────────────────────┐
  │  namespace: default          │               │  namespace: default           │
  │                              │               │                               │
  │  ┌──────────┐                │               │  ┌────────────────────────┐   │
  │  │ frontend │                │               │  │ backend                │   │
  │  └────┬─────┘                │               │  │ (FAILOVER target)      │   │
  │       │ http://backend       │               │  └────────────────────────┘   │
  │  ┌────▼──────────────────┐   │               │                               │
  │  │ backend  (PRIMARY)    │   │               │  ExportedServices             │
  │  └───────────────────────┘   │               │  backend → peer: cluster-01   │
  │                              │               │                               │
  │  ServiceResolver             │               │  ServiceIntentions            │
  │  failover → cluster-02       │               │  frontend@cluster-01 → allow  │
  │                              │               │                               │
  │  ┌────────────────────────┐  │  mTLS / 443   │  ┌────────────────────────┐   │
  │  │     mesh-gateway       │◄─┼───────────────┼──│     mesh-gateway       │   │
  │  └────────────────────────┘  │               │  └────────────────────────┘   │
  │  PeeringDialer: cluster-01   │               │  PeeringAcceptor: cluster-02  │
  └──────────────────────────────┘               └──────────────────────────────┘

  Normal path:   frontend → backend (cluster-01 PRIMARY)
  Failover path: frontend → backend (cluster-02 FAILOVER, via mesh gateway)
```

---

## Prerequisites

Consul must already be installed and healthy on both clusters before running this demo. The peering connection does not need to exist yet — this demo establishes it.

| Requirement | Expected state |
|---|---|
| Consul Enterprise | `2.0.1-ent` installed via Helm on both clusters |
| Peering enabled | `global.peering.enabled: true` in Helm values |
| Mesh gateway | `meshGateway.enabled: true`, LoadBalancer Service has an external IP |
| Transparent proxy | `connectInject.transparentProxy.defaultEnabled: true` |
| ACLs | `global.acls.manageSystemACLs: true` |
| TLS | `global.tls.enabled: true` |
| OpenShift CNI | `connectInject.cni.multus: true` |

Set your kubectl context names before running any commands:

```bash
export CONTEXT_C1=<kubectl context for cluster-01>
export CONTEXT_C2=<kubectl context for cluster-02>
```

Verify the Consul control plane is healthy on both clusters before continuing:

```bash
kubectl --context $CONTEXT_C1 rollout status deployment/consul-connect-injector    -n consul
kubectl --context $CONTEXT_C1 rollout status deployment/consul-webhook-cert-manager -n consul
kubectl --context $CONTEXT_C2 rollout status deployment/consul-connect-injector    -n consul
kubectl --context $CONTEXT_C2 rollout status deployment/consul-webhook-cert-manager -n consul
```

---

## Quick start (automated)

The `runbook.sh` script runs all setup phases end-to-end and leaves the environment in a state ready for the failover demo:

```bash
chmod +x runbook.sh
CONTEXT_C1=<your-cluster1-context> CONTEXT_C2=<your-cluster2-context> ./runbook.sh
```

Once the script completes, skip to [Trigger the failover](#trigger-the-failover).

Individual phases can also be run by sourcing the script and calling the function directly:

```bash
source runbook.sh
phase2_peering      # establish peering only
phase4_intentions   # apply exported services and intentions only
```

---

## Step-by-step walkthrough

### Phase 1 — Configure mesh gateways

Both clusters must have matching mesh gateway configuration before a peering connection can be established.

```bash
kubectl --context $CONTEXT_C1 apply -f 01-mesh-cluster1.yaml
kubectl --context $CONTEXT_C2 apply -f 02-mesh-cluster2.yaml
```

Verify sync on cluster-01 before continuing:

```bash
kubectl --context $CONTEXT_C1 get mesh mesh -n consul \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected: True
```

### Phase 2 — Establish the peering

**2a. Apply the acceptor on cluster-02.** The controller generates a one-time peering token and stores it as a Kubernetes Secret.

```bash
kubectl --context $CONTEXT_C2 apply -f 03-acceptor-cluster2.yaml

# Wait for the token Secret to be populated
kubectl --context $CONTEXT_C2 get secret peering-token -n consul -w
# Wait until the DATA column shows a value
```

**2b. Copy the token to cluster-01.** The token must exist in the `consul` namespace on cluster-01 before the dialer is applied. This command is idempotent:

```bash
TOKEN=$(kubectl --context $CONTEXT_C2 \
  get secret peering-token -n consul -o jsonpath='{.data.data}')

kubectl --context $CONTEXT_C1 create secret generic peering-token \
  --namespace=consul \
  --from-literal=data="${TOKEN}" \
  --dry-run=client -o yaml | kubectl --context $CONTEXT_C1 apply -f -
```

**2c. Apply the dialer on cluster-01.** This initiates the connection:

```bash
kubectl --context $CONTEXT_C1 apply -f 04-dialer-cluster1.yaml
```

Verify both sides show `SYNCED: True` (allow 15–30 seconds):

```bash
kubectl --context $CONTEXT_C1 get peeringdialers  -n consul
# Expected: cluster-01   True

kubectl --context $CONTEXT_C2 get peeringacceptors -n consul
# Expected: cluster-02   True
```

### Phase 3 — Deploy services

```bash
# Failover target — backend on cluster-02
kubectl --context $CONTEXT_C2 apply -f 05-backend-cluster2.yaml

# Primary — backend on cluster-01
kubectl --context $CONTEXT_C1 apply -f 06-backend-cluster1.yaml

# Frontend on cluster-01 (calls http://backend via transparent proxy)
kubectl --context $CONTEXT_C1 apply -f 07-frontend-cluster1.yaml
```

Wait for all pods to be ready (`2/2` means both the app container and Envoy sidecar are running):

```bash
kubectl --context $CONTEXT_C1 get pods -n default -w
# Expected: frontend-* and backend-* both Running 2/2

kubectl --context $CONTEXT_C2 get pods -n default -w
# Expected: backend-* Running 2/2
```

### Phase 4 — Export services and set intentions

Export `backend` from cluster-02 to cluster-01:

```bash
kubectl --context $CONTEXT_C2 apply -f 08-exported-services-cluster2.yaml
```

Allow `frontend` on cluster-01 to reach `backend` on cluster-02:

```bash
kubectl --context $CONTEXT_C2 apply -f 09-intentions-cluster2.yaml
```

Verify both are synced:

```bash
kubectl --context $CONTEXT_C2 get exportedservices  -n consul
kubectl --context $CONTEXT_C2 get serviceintentions -n consul
# Both SYNCED columns should show True
```

### Phase 5 — Apply the failover policy

```bash
kubectl --context $CONTEXT_C1 apply -f 10-service-resolver-cluster1.yaml
```

Verify it has synced:

```bash
kubectl --context $CONTEXT_C1 get serviceresolver backend -n default \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected: True
```

### Phase 6 — Verify baseline traffic

Confirm that requests are hitting the **local primary** before triggering failover:

```bash
FRONTEND_POD=$(kubectl --context $CONTEXT_C1 \
  get pod -n default -l app=frontend -o jsonpath='{.items[0].metadata.name}')

kubectl --context $CONTEXT_C1 exec -n default "${FRONTEND_POD}" -c frontend -- \
  wget -qO- http://backend
```

Expected — the upstream name confirms traffic is on the local primary:

```json
{
  "name": "frontend",
  "upstream_calls": {
    "http://backend": {
      "name": "backend (cluster-01 — PRIMARY)",
      "body": "Primary response from cluster-01"
    }
  }
}
```

---

## Trigger the failover

### Step 1 — Simulate an outage on cluster-01

```bash
kubectl --context $CONTEXT_C1 scale deployment/backend -n default --replicas=0
```

### Step 2 — Watch traffic shift to cluster-02

Consul detects the failure within approximately 5–10 seconds. Run requests in a loop to observe the transition in real time:

```bash
watch -n 1 "kubectl --context $CONTEXT_C1 exec -n default \
  \$(kubectl --context $CONTEXT_C1 get pod -n default -l app=frontend \
    -o jsonpath='{.items[0].metadata.name}') \
  -c frontend -- wget -qO- http://backend 2>/dev/null"
```

Once Consul marks the local backend unhealthy, the response body changes to reflect the failover target:

```json
{
  "name": "frontend",
  "upstream_calls": {
    "http://backend": {
      "name": "backend (cluster-02 — FAILOVER)",
      "body": "Failover response from cluster-02"
    }
  }
}
```

> The shift latency is controlled by Consul's health check interval (default ~10 seconds). The `connectTimeout: 5s` set in `10-service-resolver-cluster1.yaml` bounds the maximum time Envoy waits for a backend connection before failing over.

### Step 3 — Restore the primary (failback)

```bash
kubectl --context $CONTEXT_C1 scale deployment/backend -n default --replicas=1
```

Once the pod passes its health check and re-registers with Consul, traffic automatically routes back to the local primary. No configuration changes are needed.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Peering stuck in `Pending` | Token not copied to cluster-01, or expired | Re-generate: delete and re-apply `03-acceptor-cluster2.yaml`, copy the new token, then re-apply `04-dialer-cluster1.yaml` |
| `connection refused` after failover | Intention missing or `peer` name mismatch | Verify `09-intentions-cluster2.yaml` — `peer: cluster1` must exactly match `PeeringDialer.metadata.name` on cluster-01 |
| `wget` returns 503 | Envoy sidecar not injected | Confirm the pod shows `2/2` containers; check for `consul.hashicorp.com/connect-inject: "true"` annotation |
| ServiceResolver not activating | `ExportedServices` not applied or not synced | Apply `08-exported-services-cluster2.yaml` and confirm `SYNCED: True` |
| Traffic stays on cluster-02 after failback | Health check re-registration lag | Wait 15–20 seconds; check `consul catalog services -peer cluster-02` on cluster-01 |
| Mesh gateway not reachable | LoadBalancer Service has no external IP | Verify `kubectl get svc consul-mesh-gateway -n consul` shows an external hostname |

For deeper diagnosis, see [troubleshooting.md](../troubleshooting.md).

---

## Teardown

```bash
# Using the runbook
source runbook.sh && teardown

# Or manually
kubectl --context $CONTEXT_C1 delete -f 10-service-resolver-cluster1.yaml
kubectl --context $CONTEXT_C1 delete -f 07-frontend-cluster1.yaml
kubectl --context $CONTEXT_C1 delete -f 06-backend-cluster1.yaml
kubectl --context $CONTEXT_C1 delete -f 04-dialer-cluster1.yaml
kubectl --context $CONTEXT_C1 delete secret peering-token -n consul
kubectl --context $CONTEXT_C1 delete -f 01-mesh-cluster1.yaml

kubectl --context $CONTEXT_C2 delete -f 09-intentions-cluster2.yaml
kubectl --context $CONTEXT_C2 delete -f 08-exported-services-cluster2.yaml
kubectl --context $CONTEXT_C2 delete -f 05-backend-cluster2.yaml
kubectl --context $CONTEXT_C2 delete -f 03-acceptor-cluster2.yaml
kubectl --context $CONTEXT_C2 delete secret peering-token -n consul
kubectl --context $CONTEXT_C2 delete -f 02-mesh-cluster2.yaml
```

---

## File reference

| File | Cluster | Purpose |
|---|---|---|
| `01-mesh-cluster1.yaml` | cluster-01 | Mesh + ProxyDefaults (dialer side) |
| `02-mesh-cluster2.yaml` | cluster-02 | Mesh + ProxyDefaults (acceptor side) |
| `03-acceptor-cluster2.yaml` | cluster-02 | PeeringAcceptor — generates the token |
| `04-dialer-cluster1.yaml` | cluster-01 | PeeringDialer — establishes the connection |
| `05-backend-cluster2.yaml` | cluster-02 | backend deployment (failover target) |
| `06-backend-cluster1.yaml` | cluster-01 | backend deployment (primary) |
| `07-frontend-cluster1.yaml` | cluster-01 | frontend deployment (calls backend) |
| `08-exported-services-cluster2.yaml` | cluster-02 | Exports backend to cluster-01 |
| `09-intentions-cluster2.yaml` | cluster-02 | Allows frontend@cluster-01 → backend |
| `10-service-resolver-cluster1.yaml` | cluster-01 | Failover policy to cluster-02 |
| `runbook.sh` | both | End-to-end automation script |

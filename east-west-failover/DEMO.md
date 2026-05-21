# Consul Cluster Peering: East-West Service Failover

Two-cluster Consul Enterprise demo showing east-west traffic failover across a
cluster peering boundary. `frontend` on **cluster-01** calls a local `backend`
(primary). A `ServiceResolver` automatically redirects traffic to `backend` on
**cluster-02** (failover target) when the local instance becomes unhealthy.

---

## Topology

```
  cluster-01  (DIALER)                  cluster-02  (ACCEPTOR)
  ┌────────────────────────────┐         ┌──────────────────────────────┐
  │  namespace: default        │         │  namespace: default           │
  │                            │         │                               │
  │  ┌──────────┐              │         │  ┌───────────────────────┐    │
  │  │ frontend │              │         │  │ backend               │    │
  │  └────┬─────┘              │         │  │ (FAILOVER target)     │    │
  │       │ http://backend     │         │  └───────────────────────┘    │
  │  ┌────▼─────────────────┐  │         │                               │
  │  │ backend  (PRIMARY)   │  │         │                               │
  │  └──────────────────────┘  │         │                               │
  │                            │         │                               │
  │  ServiceResolver           │         │  ExportedServices             │
  │  failover → cluster-02     │         │  backend → peer: cluster-01   │
  │                            │         │                               │
  │  ┌─────────────────────┐   │  mTLS   │  ┌─────────────────────┐     │
  │  │   mesh gateway      │◄──┼─────────┼──│   mesh gateway      │     │
  │  └─────────────────────┘   │         │  └─────────────────────┘     │
  │  PeeringDialer              │         │  PeeringAcceptor              │
  │  name: cluster-01           │         │  name: cluster-02             │
  └────────────────────────────┘         └──────────────────────────────┘

  Normal path:    frontend → backend (cluster-01 PRIMARY)
  Failover path:  frontend → backend (cluster-02 FAILOVER, via mesh gateway)
```

---

## Prerequisites

| Requirement | Details |
|---|---|
| Consul Enterprise | `1.22.3-ent` installed via Helm on both clusters |
| Helm values | `global.peering.enabled: true`, `meshGateway.enabled: true`, `connectInject.transparentProxy.defaultEnabled: true` |
| kubectl contexts | Two contexts configured: one for each cluster |
| ACLs | Enabled (`global.acls.manageSystemACLs: true`) — token is auto-managed by the controller |
| TLS | Enabled (`global.tls.enabled: true`) |
| OpenShift | CNI Multus configured (`connectInject.cni.multus: true`) |
| Namespace | `consul` namespace exists on both clusters |

Verify Consul is running before starting:

```bash
# cluster-01
kubectl --context=cluster-01 get pods -n consul
# Expected: consul-server-0, consul-mesh-gateway-*, consul-connect-injector-* all Running

# cluster-02
kubectl --context=cluster-02 get pods -n consul
# Expected: same
```

---

## Quick Start (automated)

```bash
# Set your kubectl context names
export CONTEXT_C1=cluster-01   # replace with your actual context name
export CONTEXT_C2=cluster-02

chmod +x runbook.sh
./runbook.sh
```

Then jump to [Demo: Trigger Failover](#demo-trigger-failover).

---

## Step-by-Step Walkthrough

### Phase 1 — Mesh Gateway Config

Enable mesh gateway peering on both clusters. Both must be configured before
establishing a peering connection.

```bash
kubectl --context=cluster-01 apply -f 01-mesh-cluster01.yaml
kubectl --context=cluster-02 apply -f 02-mesh-cluster02.yaml
```

Verify sync (expect `True`):

```bash
kubectl --context=cluster-01 get mesh mesh -n consul \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected output: True
```

---

### Phase 2 — Establish Cluster Peering

#### 2a — Create the Acceptor (cluster-02)

```bash
kubectl --context=cluster-02 apply -f 03-acceptor-cluster02.yaml
```

The controller generates a one-time peering token and stores it as a Kubernetes
Secret. Wait for it:

```bash
kubectl --context=cluster-02 get secret peering-token -n consul -w
# Wait until DATA column shows a value (not <none>)
```

#### 2b — Copy the Token to cluster-01

The token must exist in the `consul` namespace on cluster-01 **before** the
Dialer is applied. The `--dry-run=client` approach is idempotent:

```bash
TOKEN=$(kubectl --context=cluster-02 \
  get secret peering-token -n consul -o jsonpath='{.data.data}')

kubectl --context=cluster-01 create secret generic peering-token \
  --namespace=consul \
  --from-literal=data="${TOKEN}" \
  --dry-run=client -o yaml | kubectl --context=cluster-01 apply -f -
```

#### 2c — Create the Dialer (cluster-01)

```bash
kubectl --context=cluster-01 apply -f 04-dialer-cluster01.yaml
```

Verify peering is ACTIVE (may take 15–30 seconds):

```bash
kubectl --context=cluster-01 get peeringdialers -n consul
# Expected:
#   NAME         SYNCED   LAST SYNCED   AGE
#   cluster-01   True     10s           30s

kubectl --context=cluster-02 get peeringacceptors -n consul
# Expected:
#   NAME         SYNCED   LAST SYNCED   AGE
#   cluster-02   True     10s           2m
```

---

### Phase 3 — Deploy Services

```bash
# Failover target on cluster-02
kubectl --context=cluster-02 apply -f 05-backend-cluster02.yaml

# Primary backend on cluster-01
kubectl --context=cluster-01 apply -f 06-backend-cluster01.yaml

# Frontend on cluster-01 (calls http://backend — transparent proxy handles routing)
kubectl --context=cluster-01 apply -f 07-frontend-cluster01.yaml
```

Wait for pods:

```bash
kubectl --context=cluster-01 get pods -n default -w
# Expected: frontend-*, backend-* both Running 2/2 (app + envoy sidecar)

kubectl --context=cluster-02 get pods -n default -w
# Expected: backend-* Running 2/2
```

---

### Phase 4 — Exported Services & Intentions

#### Export backend from cluster-02 to cluster-01

```bash
kubectl --context=cluster-02 apply -f 08-exported-services-cluster02.yaml
```

#### Allow only frontend@cluster-01 to reach backend@cluster-02

```bash
kubectl --context=cluster-02 apply -f 09-intentions-cluster02.yaml
```

Verify:

```bash
kubectl --context=cluster-02 get serviceintentions backend -n consul \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected: True
```

---

### Phase 5 — Failover Policy

```bash
kubectl --context=cluster-01 apply -f 10-service-resolver-cluster01.yaml
```

Verify:

```bash
kubectl --context=cluster-01 get serviceresolver backend -n default \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected: True
```

---

### Phase 6 — Verify Baseline Traffic

Confirm requests hit the **local primary** before triggering failover:

```bash
FRONTEND_POD=$(kubectl --context=cluster-01 \
  get pod -n default -l app=frontend -o jsonpath='{.items[0].metadata.name}')

kubectl --context=cluster-01 exec -n default "${FRONTEND_POD}" -c frontend -- \
  wget -qO- http://backend
```

Expected response body:

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

## Demo: Trigger Failover

### Step 1 — Simulate an outage on cluster-01

```bash
kubectl --context=cluster-01 scale deployment/backend -n default --replicas=0
```

### Step 2 — Watch traffic shift to cluster-02

```bash
# Run in a loop to see the shift in real time
watch -n 1 "kubectl --context=cluster-01 exec -n default \
  \$(kubectl --context=cluster-01 get pod -n default -l app=frontend \
    -o jsonpath='{.items[0].metadata.name}') \
  -c frontend -- wget -qO- http://backend 2>/dev/null"
```

Expected response **after** Consul detects the failure (~5–10 seconds):

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

> **Note:** The shift latency is controlled by Consul health check intervals
> (default ~10s). Use `connectTimeout: 5s` in the ServiceResolver to bound
> max wait time.

### Step 3 — Failback: restore the primary

```bash
kubectl --context=cluster-01 scale deployment/backend -n default --replicas=1
```

Once the pod is `Ready`, Consul automatically routes traffic back to the local
primary. No config changes needed.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Peering stuck in `Pending` | Token not copied or expired | Re-generate: delete and re-apply `03-acceptor-cluster02.yaml`, copy new token |
| `connection refused` after failover | Intention missing or wrong peer name | Verify `09-intentions-cluster02.yaml` — `peer: cluster-01` must match `PeeringDialer.metadata.name` |
| ServiceResolver not activating | ExportedServices not applied | Apply `08-exported-services-cluster02.yaml`; verify `consul.hashicorp.com/peering-token` label on secret |
| `wget` returns 503 | Pod not injected with sidecar | Check `consul.hashicorp.com/connect-inject: "true"` annotation; verify `connectInject.default: true` in Helm values |
| Traffic stays on cluster-02 after failback | Health check re-registration lag | Wait 15–20s; check `consul catalog services -peer cluster-02` on cluster-01 |
| Mesh gateway not reachable | `wanAddress.source: Service` not resolving | Verify mesh gateway Service has an external IP/hostname assigned |

---

## Teardown

```bash
# Using the runbook function
source runbook.sh && teardown

# Or manually
kubectl --context=cluster-01 delete -f 10-service-resolver-cluster01.yaml
kubectl --context=cluster-01 delete -f 07-frontend-cluster01.yaml
kubectl --context=cluster-01 delete -f 06-backend-cluster01.yaml
kubectl --context=cluster-01 delete -f 04-dialer-cluster01.yaml
kubectl --context=cluster-01 delete secret peering-token -n consul
kubectl --context=cluster-01 delete -f 01-mesh-cluster01.yaml

kubectl --context=cluster-02 delete -f 09-intentions-cluster02.yaml
kubectl --context=cluster-02 delete -f 08-exported-services-cluster02.yaml
kubectl --context=cluster-02 delete -f 05-backend-cluster02.yaml
kubectl --context=cluster-02 delete -f 03-acceptor-cluster02.yaml
kubectl --context=cluster-02 delete secret peering-token -n consul
kubectl --context=cluster-02 delete -f 02-mesh-cluster02.yaml
```

---

## File Reference

| File | Cluster | Purpose |
|---|---|---|
| `01-mesh-cluster01.yaml` | cluster-01 | Mesh + ProxyDefaults (dialer side) |
| `02-mesh-cluster02.yaml` | cluster-02 | Mesh + ProxyDefaults (acceptor side) |
| `03-acceptor-cluster02.yaml` | cluster-02 | PeeringAcceptor — generates token |
| `04-dialer-cluster01.yaml` | cluster-01 | PeeringDialer — establishes connection |
| `05-backend-cluster02.yaml` | cluster-02 | backend deployment (failover target) |
| `06-backend-cluster01.yaml` | cluster-01 | backend deployment (primary) |
| `07-frontend-cluster01.yaml` | cluster-01 | frontend deployment (calls backend) |
| `08-exported-services-cluster02.yaml` | cluster-02 | Exports backend to cluster-01 peer |
| `09-intentions-cluster02.yaml` | cluster-02 | Allow frontend@cluster-01 → backend |
| `10-service-resolver-cluster01.yaml` | cluster-01 | Failover policy to cluster-02 peer |
| `runbook.sh` | both | End-to-end automation script |

# East-West Service Failover Demo

**Environment:** Consul Enterprise 2.0.1-ent · OpenShift · Kubernetes CRD-based peering

This demo validates a working cluster peering setup by deploying a realistic two-service application and triggering an automatic east-west failover. Under normal conditions, `frontend` on cluster-01 calls a local `backend` (the primary). When the primary becomes unhealthy, a `ServiceResolver` automatically redirects traffic to `backend` on cluster-02 — no application changes, no manual intervention.

> **Before starting:** Complete [setup-guide.md](../setup-guide.md) first. This demo assumes cluster peering is already established and `ACTIVE` between cluster-01 and cluster-02.

---

## What this demo adds

The setup guide leaves you with a verified peering connection and a basic `frontend → backend` communication test. This demo goes further by deploying a second `backend` instance on cluster-02 and configuring a `ServiceResolver` that makes Consul automatically fail traffic over to it when the primary goes down.

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

| Requirement | How to verify |
|---|---|
| Cluster peering `ACTIVE` | `kubectl --context $CONTEXT_C1 get peeringdialers -n consul` → `SYNCED: True` |
| `frontend` and `backend` running on cluster-01 | `kubectl --context $CONTEXT_C1 get pods -n default` → both `2/2` |
| `backend` running on cluster-02 | `kubectl --context $CONTEXT_C2 get pods -n default` → `2/2` |
| `ExportedServices` synced on cluster-02 | `kubectl --context $CONTEXT_C2 get exportedservices -n consul` → `SYNCED: True` |
| `ServiceIntentions` synced on cluster-02 | `kubectl --context $CONTEXT_C2 get serviceintentions -n consul` → `SYNCED: True` |

If any of these are not met, return to [setup-guide.md](../setup-guide.md) and complete the missing steps.

Set your context variables if you haven't already:

```bash
export CONTEXT_C1=<kubectl context for cluster-01>
export CONTEXT_C2=<kubectl context for cluster-02>
```

---

## Step 1 — Apply the failover policy

The `ServiceResolver` is the only new resource this demo adds on top of the setup guide. It tells Consul that when all healthy instances of `backend` on cluster-01 are unavailable, traffic should automatically route to `backend` on cluster-02.

```bash
kubectl --context $CONTEXT_C1 apply -f 10-service-resolver-cluster1.yaml
```

Verify it has synced into Consul:

```bash
kubectl --context $CONTEXT_C1 get serviceresolver backend -n default \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected: True
```

---

## Step 2 — Verify baseline traffic

Confirm that requests are hitting the local primary before triggering failover. This establishes the pre-failover baseline.

```bash
FRONTEND_POD=$(kubectl --context $CONTEXT_C1 \
  get pod -n default -l app=frontend -o jsonpath='{.items[0].metadata.name}')

kubectl --context $CONTEXT_C1 exec -n default "${FRONTEND_POD}" -c frontend -- \
  wget -qO- http://backend
```

Expected — traffic is on the local primary:

```json
{
  "name": "backend",
  "body": "Hello World",
  "code": 200
}
```

> The exact response body depends on the sample application image. The key indicator is that the response is returned without error — no `503` or `connection refused`.

---

## Step 3 — Trigger the failover

Scale the primary backend to zero replicas to simulate an outage:

```bash
kubectl --context $CONTEXT_C1 scale deployment/backend -n default --replicas=0
```

Consul detects the failure within approximately 5–10 seconds. Run requests in a loop to observe the transition in real time:

```bash
watch -n 1 "kubectl --context $CONTEXT_C1 exec -n default \
  \$(kubectl --context $CONTEXT_C1 get pod -n default -l app=frontend \
    -o jsonpath='{.items[0].metadata.name}') \
  -c frontend -- wget -qO- http://backend 2>/dev/null"
```

Once Consul marks the local backend unhealthy, responses shift to the failover target:

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

> The shift latency is controlled by Consul's health check interval (default ~10 seconds). The `connectTimeout: 5s` set in `10-service-resolver-cluster1.yaml` bounds the maximum time Envoy waits before failing over.

---

## Step 4 — Restore the primary (failback)

```bash
kubectl --context $CONTEXT_C1 scale deployment/backend -n default --replicas=1
```

Once the pod passes its health check and re-registers with Consul, traffic automatically routes back to the local primary. No configuration changes are needed.

---

## Teardown

Remove only the resources added by this demo. The peering connection, exported services, intentions, and sample application deployed by the setup guide are left intact.

```bash
kubectl --context $CONTEXT_C1 delete -f 10-service-resolver-cluster1.yaml
```

To tear down the full demo environment including the setup guide resources, see the teardown section of [setup-guide.md](../setup-guide.md) or run:

```bash
# Full teardown via runbook
source runbook.sh && teardown
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `wget` returns 503 before failover | `ExportedServices` or `ServiceIntentions` not synced | Run prerequisite checks above; re-apply from `../config/` if needed |
| Traffic does not shift after scaling to 0 | `ServiceResolver` not synced | Verify `SyncedToConsul: True` on the ServiceResolver — see Step 1 |
| Traffic stays on cluster-02 after failback | Health check re-registration lag | Wait 15–20 seconds; check `consul catalog services -peer cluster-02` on cluster-01 |
| `connection refused` from cluster-02 backend | `peer` name mismatch in intentions | Verify `09-intentions-cluster2.yaml` — `peer: cluster-01` must exactly match `PeeringDialer.metadata.name` |

For deeper diagnosis, see [troubleshooting.md](../troubleshooting.md).

---

## File reference

| File | Cluster | Purpose |
|---|---|---|
| `05-backend-cluster2.yaml` | cluster-02 | backend deployment (failover target) — deployed by setup guide |
| `06-backend-cluster1.yaml` | cluster-01 | backend deployment (primary) — deployed by setup guide |
| `07-frontend-cluster1.yaml` | cluster-01 | frontend deployment — deployed by setup guide |
| `08-exported-services-cluster2.yaml` | cluster-02 | Exports backend to cluster-01 — applied by setup guide |
| `09-intentions-cluster2.yaml` | cluster-02 | Allows frontend@cluster-01 → backend — applied by setup guide |
| `10-service-resolver-cluster1.yaml` | cluster-01 | Failover policy — **applied by this demo** |
| `runbook.sh` | both | Full end-to-end automation including setup and teardown |

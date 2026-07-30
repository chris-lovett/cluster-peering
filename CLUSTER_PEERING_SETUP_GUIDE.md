# Consul Cluster Peering — Setup Guide

**Environment:** Consul Enterprise 2.0.1-ent · OpenShift · Kubernetes CRD-based peering  
**Last Updated:** May 2026

> **New to this repo?** Start with the [README](README.md) for an overview of all documents and files.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Install Consul on Both Clusters](#step-1--install-consul-on-both-clusters)
4. [Step 2 — Configure Mesh Gateway Settings](#step-2--configure-mesh-gateway-settings)
5. [Step 3 — Generate the Peering Token (Acceptor)](#step-3--generate-the-peering-token-acceptor)
6. [Step 4 — Establish the Peering Connection (Dialer)](#step-4--establish-the-peering-connection-dialer)
7. [Step 5 — Export Services](#step-5--export-services)
8. [Step 6 — Create Service Intentions](#step-6--create-service-intentions)
9. [Step 7 — Deploy and Verify Services](#step-7--deploy-and-verify-services)
10. [Quick Reference Commands](#quick-reference-commands)

> **Hitting an error?** See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for issue-by-issue resolution steps.

---

## 1. Architecture Overview

```
  cluster-01  (DIALER)                    cluster-02  (ACCEPTOR)
  ┌──────────────────────────┐               ┌──────────────────────────────┐
  │  namespace: consul       │               │  namespace: consul            │
  │                          │               │                               │
  │  PeeringDialer           │               │  PeeringAcceptor              │
  │  name: cluster-01        │               │  name: cluster-02             │
  │                          │               │  → generates peering-token    │
  │  ┌────────────────────┐  │   mTLS/443    │  ┌─────────────────────────┐ │
  │  │  mesh-gateway      │◄─┼───────────────┼──│  mesh-gateway           │ │
  │  └────────────────────┘  │               │  └─────────────────────────┘ │
  │                          │               │                               │
  │  namespace: default      │               │  namespace: default           │
  │  frontend → backend      │               │  backend (exported service)   │
  └──────────────────────────┘               └──────────────────────────────┘
```

**Key naming rule:** The `PeeringDialer.metadata.name` on cluster-01 (`cluster-01`) becomes the peer identifier that cluster-02 references in `ExportedServices` and `ServiceIntentions`. Conversely, the `PeeringAcceptor.metadata.name` on cluster-02 (`cluster-02`) is the peer name used on cluster-01. Keep these consistent throughout.

**Traffic flow:** `frontend` (cluster-01) → local mesh gateway → remote mesh gateway → `backend` (cluster-02)

---

## 2. Prerequisites

### 2.1 Set Environment Variables

Run these in every terminal session before executing any commands in this guide.

```bash
kubectl config get-contexts

export CLUSTER1_CONTEXT=<context for cluster-01>
export CLUSTER2_CONTEXT=<context for cluster-02>
export CONSUL_VERSION=2.0.1-ent
export HELM_RELEASE_NAME1=cluster-01
export HELM_RELEASE_NAME2=cluster-02
```

### 2.2 Verify Cluster Access

```bash
kubectl --context $CLUSTER1_CONTEXT get nodes
kubectl --context $CLUSTER2_CONTEXT get nodes
```

### 2.3 Required Secrets (Before Helm Install)

Both secrets must exist in the `consul` namespace **before** running `helm install`.

```bash
# Enterprise license
kubectl --context $CLUSTER1_CONTEXT create secret generic consul-ent-license \
  --namespace consul --from-literal=key="<your-license-string>"
kubectl --context $CLUSTER2_CONTEXT create secret generic consul-ent-license \
  --namespace consul --from-literal=key="<your-license-string>"

# Image pull secret for the enterprise registry
# (The values.yaml references: 19261309-openshift-secret-pull-secret)
# Create this from your HashiCorp entitlement credentials on both clusters.
```

### 2.4 Required Helm Values

| Value | Required Setting | Why |
|---|---|---|
| `global.peering.enabled` | `true` | Activates peering CRD controllers |
| `connectInject.enabled` | `true` | **Mandatory** — CRDs never reconcile without this |
| `meshGateway.enabled` | `true` | Cross-cluster traffic routing |
| `meshGateway.wanAddress.source` | `"Service"` | Advertises LoadBalancer hostname, not internal pod IP |
| `meshGateway.wanAddress.port` | `443` | Must be reachable from the peer cluster |
| `global.acls.manageSystemACLs` | `true` | ACL token auto-management |
| `global.tls.enabled` | `true` | Required for mTLS peering |
| `global.openshift.enabled` | `true` | OpenShift SCC compatibility |
| `connectInject.cni.multus` | `true` | Required for OpenShift CNI |
| `connectInject.transparentProxy.defaultEnabled` | `true` | Transparent proxy service routing |

> The complete `values.yaml` with all settings is in the root of this repo.

---

## Step 1 — Install Consul on Both Clusters

### 1.1 Add the HashiCorp Helm repository

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

### 1.2 Install on cluster-01

```bash
helm install $HELM_RELEASE_NAME1 hashicorp/consul \
  --create-namespace \
  --namespace consul \
  --version $CONSUL_VERSION \
  --values values.yaml \
  --set global.datacenter=dc1 \
  --kube-context $CLUSTER1_CONTEXT
```

### 1.3 Install on cluster-02

```bash
helm install $HELM_RELEASE_NAME2 hashicorp/consul \
  --create-namespace \
  --namespace consul \
  --version $CONSUL_VERSION \
  --values values.yaml \
  --set global.datacenter=dc2 \
  --kube-context $CLUSTER2_CONTEXT
```

> **⚠️ Critical:** cluster-01 **must** use `dc1` and cluster-02 **must** use `dc2`. Mismatched or swapped datacenter names cause continuous reconciliation errors. See [TROUBLESHOOTING.md — ProxyDefaults Datacenter Mismatch](TROUBLESHOOTING.md#proxyd-efaults-datacenter-mismatch).

### 1.4 Verify Installation

Wait until all pods are `Running` before proceeding.

```bash
kubectl --context $CLUSTER1_CONTEXT get pods -n consul
kubectl --context $CLUSTER2_CONTEXT get pods -n consul
```

### 1.5 ✅ Verify Consul Control Plane Is Healthy

> **Do not proceed to Step 2 until both checks below pass.** All peering CRDs (`Mesh`, `ProxyDefaults`, `PeeringAcceptor`, `PeeringDialer`, `ExportedServices`, `ServiceIntentions`, `ServiceResolver`) require a healthy Consul Kubernetes control plane to reconcile.

```bash
# Verify required deployments exist and are ready on both clusters
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-connect-injector   -n consul
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-connect-injector   -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul
```

```bash
# Verify all required peering CRDs are installed
kubectl --context $CLUSTER1_CONTEXT get crd \
  peeringacceptors.consul.hashicorp.com \
  peeringdialers.consul.hashicorp.com \
  exportedservices.consul.hashicorp.com \
  serviceintentions.consul.hashicorp.com \
  serviceresolvers.consul.hashicorp.com
```

If any component is missing or not ready, see [TROUBLESHOOTING.md — CRDs Apply but Never Reconcile](TROUBLESHOOTING.md#crds-apply-but-never-reconcile).

---

## Step 2 — Configure Mesh Gateway Settings

> **Apply to both clusters before establishing a peering connection.** Both clusters must agree on `peerThroughMeshGateways: true` and `mode: local` before a peering can be established.

### 2.1 Apply `mesh.yaml` to both clusters

```bash
kubectl --context $CLUSTER1_CONTEXT apply -f mesh.yaml
kubectl --context $CLUSTER2_CONTEXT apply -f mesh.yaml
```

### 2.2 Apply `proxy-defaults.yaml` to both clusters

```bash
kubectl --context $CLUSTER1_CONTEXT apply -f proxy-defaults.yaml
kubectl --context $CLUSTER2_CONTEXT apply -f proxy-defaults.yaml
```

### 2.3 ✅ Verify sync

```bash
kubectl --context $CLUSTER1_CONTEXT get mesh mesh -n consul \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected: True

kubectl --context $CLUSTER2_CONTEXT get mesh mesh -n consul \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected: True
```

If `SyncedToConsul` is not `True`, see [TROUBLESHOOTING.md — CRDs Apply but Never Reconcile](TROUBLESHOOTING.md#crds-apply-but-never-reconcile).

---

## Step 3 — Generate the Peering Token (Acceptor)

The **acceptor** is cluster-02. It generates the peering token that cluster-01 will use to dial in.

> **⚠️ Namespace is critical.** The `PeeringAcceptor` must be in the `consul` namespace. If created in `default`, the token will never be generated and no error will surface. The `acceptor.yaml` file in this repo already has `namespace: consul` set.

### 3.1 Apply `acceptor.yaml` to cluster-02

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f acceptor.yaml
```

### 3.2 ✅ Wait for the token to be generated

```bash
kubectl --context $CLUSTER2_CONTEXT get secret peering-token -n consul -w
# Wait until the DATA column shows a value — this confirms the token is ready
```

> **⚠️ Single-use token.** The peering token is generated once. Re-applying or deleting and re-applying `acceptor.yaml` generates a **new** token and invalidates the previous one. If the Dialer has already been applied with an old token, the peering state must be fully reset. See [TROUBLESHOOTING.md — Reset Corrupted Peering State](TROUBLESHOOTING.md#reset-corrupted-peering-state).

### 3.3 Copy the token to cluster-01

The token Secret must exist in the `consul` namespace on cluster-01 **before** the Dialer is applied.

```bash
TOKEN=$(kubectl --context $CLUSTER2_CONTEXT \
  get secret peering-token -n consul -o jsonpath='{.data.data}')

kubectl --context $CLUSTER1_CONTEXT create secret generic peering-token \
  --namespace=consul \
  --from-literal=data="${TOKEN}" \
  --dry-run=client -o yaml | kubectl --context $CLUSTER1_CONTEXT apply -f -
```

> Using `--dry-run=client -o yaml | apply -f -` makes this operation idempotent — safe to re-run if needed.

### 3.4 ✅ Confirm the token exists on cluster-01

```bash
kubectl --context $CLUSTER1_CONTEXT get secret peering-token -n consul
# Expected: NAME           TYPE     DATA   AGE
#           peering-token  Opaque   1      <time>
```

---

## Step 4 — Establish the Peering Connection (Dialer)

The **dialer** is cluster-01. It initiates the connection to cluster-02 using the token.

> **Prerequisite:** The `peering-token` Secret must exist on cluster-01 (Step 3.3) before applying the Dialer.

### 4.1 Apply `dialer.yaml` to cluster-01

```bash
kubectl --context $CLUSTER1_CONTEXT apply -f dialer.yaml
```

### 4.2 ✅ Verify peering is Active (allow 15–30 seconds)

```bash
kubectl --context $CLUSTER1_CONTEXT get peeringdialers -n consul
# Expected:
#   NAME         SYNCED   LAST SYNCED   AGE
#   cluster-01   True     10s           30s

kubectl --context $CLUSTER2_CONTEXT get peeringacceptors -n consul
# Expected:
#   NAME         SYNCED   LAST SYNCED   AGE
#   cluster-02   True     10s           2m
```

```bash
# Confirm ACTIVE state via Consul API
TOKEN=$(kubectl --context $CLUSTER1_CONTEXT get secret consul-bootstrap-acl-token \
  -n consul -o jsonpath='{.data.token}' | base64 --decode)

kubectl --context $CLUSTER1_CONTEXT exec -n consul consul-server-0 \
  -- consul peering list -token $TOKEN
# Expected: State: ACTIVE
```

If `SYNCED` is not `True` or `State` is not `ACTIVE`, see [TROUBLESHOOTING.md — Peering Stuck in Pending](TROUBLESHOOTING.md#peering-stuck-in-pending).

---

## Step 5 — Export Services

Services are **not** visible across a peering by default. The acceptor cluster (cluster-02) must explicitly export each service it wants to share.

> **Apply to cluster-02 only.** `ExportedServices` is always applied on the cluster whose services are being shared.

### 5.1 Apply `exported-service.yaml` to cluster-02

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f exported-service.yaml
```

The `peer` value in `exported-service.yaml` must match the `PeeringDialer.metadata.name` on cluster-01 — in this repo that is `cluster-01`.

### 5.2 ✅ Verify export is synced

```bash
kubectl --context $CLUSTER2_CONTEXT get exportedservices -n consul
# Expected: SYNCED column shows True
```

---

## Step 6 — Create Service Intentions

Consul enforces **default-deny** for all cross-cluster traffic. Intentions must explicitly allow the traffic you want.

> **Apply to cluster-02 only.** Intentions protecting a service are always defined on the cluster where that service runs (the acceptor/exporter).

### 6.1 Apply `intention.yaml` to cluster-02

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f intention.yaml
```

The `peer` value in `intention.yaml` must match the `PeeringDialer.metadata.name` on cluster-01 — in this repo that is `cluster-01`.

### 6.2 ✅ Verify intentions are synced

```bash
kubectl --context $CLUSTER2_CONTEXT get serviceintentions -n consul
# Expected: SYNCED column shows True
```

---

## Step 7 — Deploy and Verify Services

### 7.1 Deploy the backend on cluster-02

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f backend.yaml
kubectl --context $CLUSTER2_CONTEXT get pods -n default -w
# Expected: backend-* Running 2/2 (app + envoy sidecar)
```

### 7.2 Deploy the frontend on cluster-01

```bash
kubectl --context $CLUSTER1_CONTEXT apply -f frontend.yaml
kubectl --context $CLUSTER1_CONTEXT get pods -n default -w
# Expected: frontend-* Running 2/2 (app + envoy sidecar)
```

> **Note — Transparent proxy DNS:** The `frontend` deployment calls the backend using the virtual DNS format for peered services:
> ```
> http://backend.virtual.cluster-02.consul
> ```
> The pattern is: `<service-name>.virtual.<peer-name>.consul`

### 7.3 ✅ Test cross-cluster communication

```bash
FRONTEND_POD=$(kubectl --context $CLUSTER1_CONTEXT \
  get pod -n default -l app=frontend -o jsonpath='{.items[0].metadata.name}')

kubectl --context $CLUSTER1_CONTEXT exec -n default "${FRONTEND_POD}" -c frontend -- \
  wget -qO- http://backend.virtual.cluster-02.consul
```

**Expected response:**

```json
{
  "name": "frontend",
  "body": "Hello World",
  "upstream_calls": {
    "http://backend.virtual.cluster-02.consul": {
      "name": "backend",
      "body": "Response from backend",
      "code": 200
    }
  },
  "code": 200
}
```

If you see a `503` or `connection refused`, check:
1. `ExportedServices` is applied on cluster-02 and SYNCED (Step 5)
2. `ServiceIntentions` is applied on cluster-02 and SYNCED (Step 6)
3. The `backend` pod shows `2/2` — both app and Envoy sidecar are running
4. The `peer` value in both `exported-service.yaml` and `intention.yaml` matches `cluster-01`

---

## Quick Reference Commands

### Check Peering Status

```bash
# CRD status
kubectl --context $CLUSTER1_CONTEXT get peeringdialers  -n consul
kubectl --context $CLUSTER2_CONTEXT get peeringacceptors -n consul

# Consul API
TOKEN=$(kubectl --context $CLUSTER1_CONTEXT get secret consul-bootstrap-acl-token \
  -n consul -o jsonpath='{.data.token}' | base64 --decode)
kubectl --context $CLUSTER1_CONTEXT exec -n consul consul-server-0 \
  -- consul peering list -token $TOKEN
```

### Check Mesh Gateway WAN Address

```bash
kubectl --context $CLUSTER1_CONTEXT get svc consul-mesh-gateway -n consul
# EXTERNAL-IP must show a hostname — not <pending> or an internal IP
```

### Check Pod Logs

```bash
# Connect injector
kubectl --context $CLUSTER1_CONTEXT logs -n consul deployment/consul-connect-injector

# Mesh gateway
kubectl --context $CLUSTER1_CONTEXT logs -n consul deployment/consul-mesh-gateway

# Server (filter for peering activity)
kubectl --context $CLUSTER1_CONTEXT logs -n consul consul-server-0 --tail=100 \
  | grep -i "peer\|grpc\|error"
```

### View Exported Services and Intentions

```bash
kubectl --context $CLUSTER2_CONTEXT get exportedservices  -n consul
kubectl --context $CLUSTER2_CONTEXT get serviceintentions -n consul
```

### Check Catalog Services Across Peering

```bash
# After peering is Active — verify backend is visible from cluster-01
TOKEN=$(kubectl --context $CLUSTER1_CONTEXT get secret consul-bootstrap-acl-token \
  -n consul -o jsonpath='{.data.token}' | base64 --decode)
kubectl --context $CLUSTER1_CONTEXT exec -n consul consul-server-0 \
  -- consul catalog services -peer cluster-02 -token $TOKEN
```

---

> For issue-by-issue troubleshooting, see **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)**.  
> For the east-west failover demo, see **[east-west-failover/DEMO.md](east-west-failover/DEMO.md)**.

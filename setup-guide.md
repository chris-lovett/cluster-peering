# Consul Cluster Peering — Setup Guide

**Environment:** Consul Enterprise 2.0.1-ent · OpenShift · Kubernetes CRD-based peering  
**Last updated:** May 2026

> New to this repo? Start with the [README](README.md) for an architecture overview.  
> Running into errors? Jump to [troubleshooting.md](troubleshooting.md).

This guide assumes Consul Enterprise is already installed and running on both clusters. The goal is to enable cluster peering between them and verify that services can communicate across the boundary.

---

## Table of contents

1. [Before you begin](#1-before-you-begin)
2. [Enable peering on both clusters](#2-enable-peering-on-both-clusters)
3. [Configure mesh gateway settings](#3-configure-mesh-gateway-settings)
4. [Generate the peering token](#4-generate-the-peering-token)
5. [Establish the peering connection](#5-establish-the-peering-connection)
6. [Export services and set intentions](#6-export-services-and-set-intentions)
7. [Deploy sample services and verify connectivity](#7-deploy-sample-services-and-verify-connectivity)
8. [Quick reference](#8-quick-reference)

---

## 1. Before you begin

### Set environment variables

Run these exports in every terminal session before executing commands from this guide.

```bash
kubectl config get-contexts   # find your context names

export CLUSTER1_CONTEXT=<context for cluster-01>
export CLUSTER2_CONTEXT=<context for cluster-02>
```

Verify you can reach both clusters:

```bash
kubectl --context $CLUSTER1_CONTEXT get nodes
kubectl --context $CLUSTER2_CONTEXT get nodes
```

### Verify Consul is running on both clusters

```bash
kubectl --context $CLUSTER1_CONTEXT get pods -n consul
kubectl --context $CLUSTER2_CONTEXT get pods -n consul
```

All pods should be `Running`. The following two deployments are specifically required for peering CRDs to reconcile — confirm they are ready on both clusters before proceeding:

```bash
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-connect-injector    -n consul
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-connect-injector    -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul
```

If either deployment is missing or not ready, see [troubleshooting.md — CRDs Apply but Never Reconcile](troubleshooting.md#2-crds-apply-but-never-reconcile).

### Confirm datacenter names

Cluster peering requires each cluster to have a distinct datacenter name. Verify:

```bash
kubectl --context $CLUSTER1_CONTEXT get configmap consul-server-config \
  -n consul -o yaml | grep datacenter
# Expected: dc1

kubectl --context $CLUSTER2_CONTEXT get configmap consul-server-config \
  -n consul -o yaml | grep datacenter
# Expected: dc2
```

The two names must be different. If they are the same, or if either cluster was installed with the wrong name, see [troubleshooting.md — ProxyDefaults Datacenter Mismatch](troubleshooting.md#4-proxydefaults-datacenter-mismatch) before continuing.

---

## 2. Enable peering on both clusters

Cluster peering requires several Helm values to be active. Check whether they are already enabled, then upgrade only if needed.

### Check current values

```bash
# Inspect the current Helm values for each release
helm get values <your-release-name> -n consul --context $CLUSTER1_CONTEXT
helm get values <your-release-name> -n consul --context $CLUSTER2_CONTEXT
```

The following values must all be `true`. If any are missing or set to `false`, upgrade the release using the instructions below.

| Value | Required | Purpose |
|---|---|---|
| `global.peering.enabled` | `true` | Activates the peering CRD controllers |
| `connectInject.enabled` | `true` | Required for any peering CRD to reconcile — the most common silent failure when missing |
| `meshGateway.enabled` | `true` | All cross-cluster traffic routes through the mesh gateway |
| `meshGateway.wanAddress.source` | `"Service"` | Advertises the LoadBalancer hostname as the WAN address — without this the mesh gateway registers its internal pod IP and remote clusters cannot reach it |
| `meshGateway.wanAddress.port` | `443` | Port exposed by the LoadBalancer Service |
| `global.acls.manageSystemACLs` | `true` | ACL tokens for peering are managed automatically |
| `global.tls.enabled` | `true` | Required for mTLS between clusters |
| `global.openshift.enabled` | `true` | Creates required OpenShift Security Context Constraints |
| `connectInject.cni.multus` | `true` | Required for transparent proxy injection with OpenShift CNI |
| `connectInject.transparentProxy.defaultEnabled` | `true` | Enables virtual DNS-based service routing |

The `values.yaml` in this repo has all of the above set correctly and can be used as a reference.

### Upgrade if needed

If any required values are missing from your current install, perform a Helm upgrade. Delete the immutable ACL jobs first — Helm cannot update them in place:

```bash
# cluster-01
kubectl --context $CLUSTER1_CONTEXT delete jobs \
  consul-server-acl-init consul-server-acl-init-cleanup consul-gateway-resources \
  -n consul --ignore-not-found

helm upgrade <your-release-name> hashicorp/consul \
  --namespace consul \
  --version 2.0.1-ent \
  --values values.yaml \
  --set global.datacenter=dc1 \
  --kube-context $CLUSTER1_CONTEXT \
  --cleanup-on-fail

# cluster-02
kubectl --context $CLUSTER2_CONTEXT delete jobs \
  consul-server-acl-init consul-server-acl-init-cleanup consul-gateway-resources \
  -n consul --ignore-not-found

helm upgrade <your-release-name> hashicorp/consul \
  --namespace consul \
  --version 2.0.1-ent \
  --values values.yaml \
  --set global.datacenter=dc2 \
  --kube-context $CLUSTER2_CONTEXT \
  --cleanup-on-fail
```

> The ACL init job re-runs automatically after deletion. This is safe — it is idempotent and will not overwrite existing tokens.

After upgrading, confirm the control-plane deployments are ready and all five peering CRDs are installed:

```bash
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-connect-injector    -n consul
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-connect-injector    -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul

kubectl --context $CLUSTER1_CONTEXT get crd \
  peeringacceptors.consul.hashicorp.com \
  peeringdialers.consul.hashicorp.com \
  exportedservices.consul.hashicorp.com \
  serviceintentions.consul.hashicorp.com \
  serviceresolvers.consul.hashicorp.com
```

---

## 3. Configure mesh gateway settings

Both clusters must agree on mesh gateway configuration before a peering connection can be established. Apply `mesh.yaml` and `proxy-defaults.yaml` to both clusters:

```bash
kubectl --context $CLUSTER1_CONTEXT apply -f config/mesh.yaml
kubectl --context $CLUSTER2_CONTEXT apply -f config/mesh.yaml

kubectl --context $CLUSTER1_CONTEXT apply -f config/proxy-defaults.yaml
kubectl --context $CLUSTER2_CONTEXT apply -f config/proxy-defaults.yaml
```

`mesh.yaml` enables `peerThroughMeshGateways: true`. `proxy-defaults.yaml` sets `meshGateway.mode: local`, which tells every Envoy sidecar to route outbound cross-cluster traffic through the local mesh gateway rather than attempting a direct connection.

Verify both resources have synced into Consul on each cluster before continuing:

```bash
kubectl --context $CLUSTER1_CONTEXT get mesh mesh -n consul \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected: True

kubectl --context $CLUSTER2_CONTEXT get mesh mesh -n consul \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected: True
```

If `SyncedToConsul` is not `True`, the control plane is not healthy. See [troubleshooting.md — CRDs Apply but Never Reconcile](troubleshooting.md#2-crds-apply-but-never-reconcile).

---

## 4. Generate the peering token

The acceptor cluster (cluster-02) generates a single-use token that the dialer will use to authenticate the connection. This token is stored as a Kubernetes Secret and must be copied to cluster-01 before the dialer is applied.

> **The peering token is single-use.** Re-applying `config/acceptor.yaml` generates a new token and permanently invalidates the previous one. If the dialer has already been applied with an old token, the full peering state must be reset. See [troubleshooting.md — Reset Corrupted Peering State](troubleshooting.md#6-reset-corrupted-peering-state).

Apply the acceptor on cluster-02:

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f config/acceptor.yaml
```

Wait for the controller to populate the token Secret:

```bash
kubectl --context $CLUSTER2_CONTEXT get secret peering-token -n consul -w
# Wait until the DATA column shows a value
```

Copy the token to cluster-01. This command is idempotent — safe to re-run:

```bash
TOKEN=$(kubectl --context $CLUSTER2_CONTEXT \
  get secret peering-token -n consul -o jsonpath='{.data.data}')

kubectl --context $CLUSTER1_CONTEXT create secret generic peering-token \
  --namespace=consul \
  --from-literal=data="${TOKEN}" \
  --dry-run=client -o yaml | kubectl --context $CLUSTER1_CONTEXT apply -f -
```

Confirm the Secret exists on cluster-01 before continuing:

```bash
kubectl --context $CLUSTER1_CONTEXT get secret peering-token -n consul
# Expected: NAME           TYPE     DATA   AGE
#           peering-token  Opaque   1      <seconds>
```

---

## 5. Establish the peering connection

Apply the dialer on cluster-01. This initiates the connection to cluster-02 using the token copied in the previous step:

```bash
kubectl --context $CLUSTER1_CONTEXT apply -f config/dialer.yaml
```

The connection takes 15–30 seconds to establish. Verify that both sides show `SYNCED: True`:

```bash
kubectl --context $CLUSTER1_CONTEXT get peeringdialers  -n consul
# Expected:  NAME         SYNCED   LAST SYNCED   AGE
#            cluster-01   True     10s           30s

kubectl --context $CLUSTER2_CONTEXT get peeringacceptors -n consul
# Expected:  NAME         SYNCED   LAST SYNCED   AGE
#            cluster-02   True     10s           2m
```

Confirm the peering is `ACTIVE` via the Consul API:

```bash
TOKEN=$(kubectl --context $CLUSTER1_CONTEXT get secret consul-bootstrap-acl-token \
  -n consul -o jsonpath='{.data.token}' | base64 --decode)

kubectl --context $CLUSTER1_CONTEXT exec -n consul consul-server-0 \
  -- consul peering list -token $TOKEN
# Expected: State: ACTIVE
```

If `SYNCED` is not `True` or `State` is not `ACTIVE`, see [troubleshooting.md — Peering Stuck in Pending](troubleshooting.md#1-peering-stuck-in-pending).

---

## 6. Export services and set intentions

With the peering `ACTIVE`, services still cannot communicate. Two resources on cluster-02 are required: one to make services visible to cluster-01, and one to allow the traffic through.

### Export a service

Apply `config/exported-service.yaml` to cluster-02. Without this, cluster-01 cannot discover any service through the peering:

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f config/exported-service.yaml
```

The `peer: cluster-01` value in this file references the `metadata.name` of the `PeeringDialer` on cluster-01. These must match exactly.

### Allow the traffic

Consul enforces default-deny on all cross-cluster traffic. Apply `config/intention.yaml` to cluster-02 to explicitly allow `frontend` on cluster-01 to reach `backend`:

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f config/intention.yaml
```

The `peer: cluster-01` value here must also match the `PeeringDialer` name exactly.

### Verify both resources have synced

```bash
kubectl --context $CLUSTER2_CONTEXT get exportedservices  -n consul
kubectl --context $CLUSTER2_CONTEXT get serviceintentions -n consul
# Both SYNCED columns should show True
```

---

## 7. Deploy sample services and verify connectivity

Steps 6 and 7 use the sample `frontend` and `backend` applications in the `app/` directory to confirm the peering is functioning end-to-end. These are lightweight test services — replace them with your own applications once connectivity is confirmed.

### Deploy the sample backend on cluster-02

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f app/backend.yaml
kubectl --context $CLUSTER2_CONTEXT get pods -n default -w
# Expected: backend-* Running 2/2  (app container + Envoy sidecar)
```

### Deploy the sample frontend on cluster-01

```bash
kubectl --context $CLUSTER1_CONTEXT apply -f app/frontend.yaml
kubectl --context $CLUSTER1_CONTEXT get pods -n default -w
# Expected: frontend-* Running 2/2  (app container + Envoy sidecar)
```

Services on cluster-01 reach peered services on cluster-02 using the virtual DNS format: `<service-name>.virtual.<peer-name>.consul`. The sample frontend is configured to call `http://backend.virtual.cluster-02.consul`. Transparent proxy resolves this automatically — no changes to the application are needed.

### Test cross-cluster communication

```bash
FRONTEND_POD=$(kubectl --context $CLUSTER1_CONTEXT \
  get pod -n default -l app=frontend -o jsonpath='{.items[0].metadata.name}')

kubectl --context $CLUSTER1_CONTEXT exec -n default "${FRONTEND_POD}" -c frontend -- \
  wget -qO- http://backend.virtual.cluster-02.consul
```

A successful response confirms the complete path is working — peering active, service exported, intention allowing the connection, Envoy routing correctly:

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

If you see a `503` or `connection refused`, work through this checklist:

1. `ExportedServices` on cluster-02 shows `SYNCED: True` — if not, re-apply `config/exported-service.yaml`
2. `ServiceIntentions` on cluster-02 shows `SYNCED: True` — if not, re-apply `config/intention.yaml`
3. `backend` pod shows `2/2` — if only `1/2`, the Envoy sidecar was not injected; verify `consul.hashicorp.com/connect-inject: "true"` is set in the pod annotations
4. The `peer` value in both `config/exported-service.yaml` and `config/intention.yaml` exactly matches `cluster-01`

---

## 8. Quick reference

### Check peering status

```bash
# CRD sync status on both sides
kubectl --context $CLUSTER1_CONTEXT get peeringdialers  -n consul
kubectl --context $CLUSTER2_CONTEXT get peeringacceptors -n consul

# Peering state via Consul API
TOKEN=$(kubectl --context $CLUSTER1_CONTEXT get secret consul-bootstrap-acl-token \
  -n consul -o jsonpath='{.data.token}' | base64 --decode)
kubectl --context $CLUSTER1_CONTEXT exec -n consul consul-server-0 \
  -- consul peering list -token $TOKEN
```

### Verify the mesh gateway has a public WAN address

```bash
kubectl --context $CLUSTER1_CONTEXT get svc consul-mesh-gateway -n consul
# EXTERNAL-IP must show a hostname — not <pending> or an internal IP
```

### View exported services and intentions

```bash
kubectl --context $CLUSTER2_CONTEXT get exportedservices  -n consul
kubectl --context $CLUSTER2_CONTEXT get serviceintentions -n consul
```

### Check catalog services visible across the peering

```bash
TOKEN=$(kubectl --context $CLUSTER1_CONTEXT get secret consul-bootstrap-acl-token \
  -n consul -o jsonpath='{.data.token}' | base64 --decode)
kubectl --context $CLUSTER1_CONTEXT exec -n consul consul-server-0 \
  -- consul catalog services -peer cluster-02 -token $TOKEN
```

### Check pod logs

```bash
# Connect injector
kubectl --context $CLUSTER1_CONTEXT logs -n consul deployment/consul-connect-injector

# Mesh gateway
kubectl --context $CLUSTER1_CONTEXT logs -n consul deployment/consul-mesh-gateway

# Server — filter for peering and gRPC activity
kubectl --context $CLUSTER1_CONTEXT logs -n consul consul-server-0 --tail=100 \
  | grep -i "peer\|grpc\|error"
```

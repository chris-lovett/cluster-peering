# Consul Cluster Peering — Setup Guide

**Environment:** Consul Enterprise 2.0.1-ent · OpenShift · Kubernetes CRD-based peering  
**Last updated:** May 2026

> New to this repo? Start with the [README](README.md) for an architecture overview and file index.  
> Running into errors? Jump to [troubleshooting.md](troubleshooting.md).

---

## Table of contents

1. [Before you begin](#1-before-you-begin)
2. [Install Consul on both clusters](#2-install-consul-on-both-clusters)
3. [Configure mesh gateway settings](#3-configure-mesh-gateway-settings)
4. [Generate the peering token](#4-generate-the-peering-token)
5. [Establish the peering connection](#5-establish-the-peering-connection)
6. [Export services and set intentions](#6-export-services-and-set-intentions)
7. [Deploy services and verify connectivity](#7-deploy-services-and-verify-connectivity)
8. [Quick reference](#8-quick-reference)

---

## 1. Before you begin

### Set environment variables

Run these exports in every terminal session before executing commands from this guide. All subsequent commands use these variables.

```bash
kubectl config get-contexts   # find your context names

export CLUSTER1_CONTEXT=<context for cluster-01>
export CLUSTER2_CONTEXT=<context for cluster-02>
export CONSUL_VERSION=2.0.1-ent
export HELM_RELEASE_NAME1=cluster-01
export HELM_RELEASE_NAME2=cluster-02
```

Verify you can reach both clusters:

```bash
kubectl --context $CLUSTER1_CONTEXT get nodes
kubectl --context $CLUSTER2_CONTEXT get nodes
```

### Create required secrets before installing

Both secrets must exist in the `consul` namespace on each cluster **before** `helm install` runs. Missing either one causes pods to fail immediately.

```bash
# Enterprise license — required on both clusters
kubectl --context $CLUSTER1_CONTEXT create secret generic consul-ent-license \
  --namespace consul --from-literal=key="<your-license-string>"
kubectl --context $CLUSTER2_CONTEXT create secret generic consul-ent-license \
  --namespace consul --from-literal=key="<your-license-string>"
```

The image pull secret (`19261309-openshift-secret-pull-secret`) referenced in `values.yaml` must also exist in the `consul` namespace on both clusters before installation. Create it from your HashiCorp entitlement credentials. See [troubleshooting.md — OpenShift-Specific Issues](troubleshooting.md#8-openshift-specific-issues) if pods end up in `ImagePullBackOff`.

### Understand the required Helm values

The `values.yaml` in this repo already has these set correctly. This table explains why each one is required — if you adapt `values.yaml` for your environment, do not remove them.

| Value | Required setting | Why it matters |
|---|---|---|
| `global.peering.enabled` | `true` | Activates the peering CRD controllers |
| `connectInject.enabled` | `true` | Required for any peering CRD to reconcile — omitting this is the most common silent failure |
| `meshGateway.enabled` | `true` | All cross-cluster traffic routes through the mesh gateway |
| `meshGateway.wanAddress.source` | `"Service"` | Tells Consul to advertise the LoadBalancer hostname as the WAN address; without this, the mesh gateway registers its internal pod IP and remote clusters cannot reach it |
| `meshGateway.wanAddress.port` | `443` | Port exposed by the LoadBalancer Service |
| `global.acls.manageSystemACLs` | `true` | ACL tokens for peering are managed automatically |
| `global.tls.enabled` | `true` | Required for mTLS between clusters |
| `global.openshift.enabled` | `true` | Creates required OpenShift Security Context Constraints |
| `connectInject.cni.multus` | `true` | Required for transparent proxy injection with OpenShift CNI |
| `connectInject.transparentProxy.defaultEnabled` | `true` | Enables virtual DNS-based service routing |

---

## 2. Install Consul on both clusters

### Add the HashiCorp Helm repository

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

### Install on cluster-01 (the dialer)

```bash
helm install $HELM_RELEASE_NAME1 hashicorp/consul \
  --create-namespace \
  --namespace consul \
  --version $CONSUL_VERSION \
  --values values.yaml \
  --set global.datacenter=dc1 \
  --kube-context $CLUSTER1_CONTEXT
```

### Install on cluster-02 (the acceptor)

```bash
helm install $HELM_RELEASE_NAME2 hashicorp/consul \
  --create-namespace \
  --namespace consul \
  --version $CONSUL_VERSION \
  --values values.yaml \
  --set global.datacenter=dc2 \
  --kube-context $CLUSTER2_CONTEXT
```

> **cluster-01 must use `dc1` and cluster-02 must use `dc2`.** These names cannot be the same and cannot be swapped. Mismatched datacenter names cause ProxyDefaults and Mesh CRDs to fail sync with a `config entry managed in different datacenter` error. See [troubleshooting.md — ProxyDefaults Datacenter Mismatch](troubleshooting.md#5-proxydefaults-datacenter-mismatch).

### Verify the installation and control plane health

Wait for all pods to reach `Running` status before continuing:

```bash
kubectl --context $CLUSTER1_CONTEXT get pods -n consul
kubectl --context $CLUSTER2_CONTEXT get pods -n consul
```

Then confirm the two control-plane components that peering CRD reconciliation depends on are fully ready. **Do not proceed to step 3 until both commands exit cleanly on both clusters.**

```bash
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-connect-injector    -n consul
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-connect-injector    -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul
```

Finally, confirm all five peering-related CRDs were installed by Helm:

```bash
kubectl --context $CLUSTER1_CONTEXT get crd \
  peeringacceptors.consul.hashicorp.com \
  peeringdialers.consul.hashicorp.com \
  exportedservices.consul.hashicorp.com \
  serviceintentions.consul.hashicorp.com \
  serviceresolvers.consul.hashicorp.com
```

If any CRD is missing or a deployment is not ready, see [troubleshooting.md — CRDs Apply but Never Reconcile](troubleshooting.md#3-crds-apply-but-never-reconcile).

---

## 3. Configure mesh gateway settings

Both clusters must have identical mesh gateway configuration before a peering connection can be established. Apply `mesh.yaml` and `proxy-defaults.yaml` to both clusters:

```bash
kubectl --context $CLUSTER1_CONTEXT apply -f config/mesh.yaml
kubectl --context $CLUSTER2_CONTEXT apply -f config/mesh.yaml

kubectl --context $CLUSTER1_CONTEXT apply -f config/proxy-defaults.yaml
kubectl --context $CLUSTER2_CONTEXT apply -f config/proxy-defaults.yaml
```

`mesh.yaml` enables `peerThroughMeshGateways: true`. `proxy-defaults.yaml` sets `meshGateway.mode: local`, which tells every Envoy sidecar to send outbound cross-cluster traffic to the local mesh gateway rather than attempting a direct connection.

Verify both resources have synced into Consul on each cluster:

```bash
kubectl --context $CLUSTER1_CONTEXT get mesh mesh -n consul \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected: True

kubectl --context $CLUSTER2_CONTEXT get mesh mesh -n consul \
  -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'
# Expected: True
```

If `SyncedToConsul` is not `True`, the control plane is not healthy. See [troubleshooting.md — CRDs Apply but Never Reconcile](troubleshooting.md#3-crds-apply-but-never-reconcile).

---

## 4. Generate the peering token

The acceptor cluster (cluster-02) generates a single-use token that the dialer will use to authenticate the connection. This token is stored as a Kubernetes Secret.

> **The peering token is single-use.** Deleting and re-applying `acceptor.yaml` generates a new token and permanently invalidates the previous one. If a dialer has already been applied using the old token, the full peering state must be reset before retrying. See [troubleshooting.md — Reset Corrupted Peering State](troubleshooting.md#7-reset-corrupted-peering-state).

Apply the acceptor on cluster-02:

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f config/acceptor.yaml
```

Wait for the controller to populate the token Secret. The `DATA` column will be empty until the token is ready:

```bash
kubectl --context $CLUSTER2_CONTEXT get secret peering-token -n consul -w
# Wait until the DATA column shows a value
```

Once the token is ready, copy it to cluster-01. The token Secret must exist in the `consul` namespace on cluster-01 **before** the dialer is applied. This command is idempotent — safe to re-run:

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

If `SYNCED` is not `True` or `State` is not `ACTIVE`, see [troubleshooting.md — Peering Stuck in Pending](troubleshooting.md#2-peering-stuck-in-pending).

---

## 6. Export services and set intentions

With the peering established, services still cannot communicate. Two more resources on cluster-02 are required: one to make `backend` visible to cluster-01, and one to allow the traffic.

### Export the backend service

Apply `exported-service.yaml` to cluster-02. Without this, cluster-01 cannot resolve `backend` through the peering at all:

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f config/exported-service.yaml
```

The `peer: cluster-01` value in this file must match the `metadata.name` of the `PeeringDialer` on cluster-01.

### Allow the traffic with a service intention

Consul enforces default-deny on all cross-cluster connections. Apply `intention.yaml` to cluster-02 to explicitly allow `frontend` on cluster-01 to reach `backend`:

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f config/intention.yaml
```

Again, the `peer: cluster-01` value must match the `PeeringDialer` name.

### Verify both resources have synced

```bash
kubectl --context $CLUSTER2_CONTEXT get exportedservices  -n consul
kubectl --context $CLUSTER2_CONTEXT get serviceintentions -n consul
# Both SYNCED columns should show True
```

---

## 7. Deploy services and verify connectivity

### Deploy the backend on cluster-02

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f app/backend.yaml
kubectl --context $CLUSTER2_CONTEXT get pods -n default -w
# Expected: backend-* Running 2/2  (app container + Envoy sidecar)
```

### Deploy the frontend on cluster-01

```bash
kubectl --context $CLUSTER1_CONTEXT apply -f app/frontend.yaml
kubectl --context $CLUSTER1_CONTEXT get pods -n default -w
# Expected: frontend-* Running 2/2  (app container + Envoy sidecar)
```

The frontend reaches the backend using the virtual DNS name for peered services: `<service>.<peer>.consul`. In this repo, that is `http://backend.virtual.cluster-02.consul`. Transparent proxy handles the resolution automatically — no application changes are needed.

### Test cross-cluster communication

```bash
FRONTEND_POD=$(kubectl --context $CLUSTER1_CONTEXT \
  get pod -n default -l app=frontend -o jsonpath='{.items[0].metadata.name}')

kubectl --context $CLUSTER1_CONTEXT exec -n default "${FRONTEND_POD}" -c frontend -- \
  wget -qO- http://backend.virtual.cluster-02.consul
```

A successful response confirms the full path is working — peering active, service exported, intention allowing the connection, and Envoy routing correctly:

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

1. `ExportedServices` on cluster-02 shows `SYNCED: True` — if not, re-apply `exported-service.yaml`
2. `ServiceIntentions` on cluster-02 shows `SYNCED: True` — if not, re-apply `intention.yaml`
3. `backend` pod shows `2/2` containers running — if only `1/2`, the Envoy sidecar was not injected; verify `consul.hashicorp.com/connect-inject: "true"` is in the pod annotations
4. The `peer` value in both `exported-service.yaml` and `intention.yaml` exactly matches `cluster-01`

---

## 8. Quick reference

### Check peering status

```bash
# CRD sync status (both sides)
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

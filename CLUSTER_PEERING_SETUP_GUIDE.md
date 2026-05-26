# Consul Cluster Peering on Kubernetes
## Complete Step-by-Step Implementation Guide

**Document Version:** 2.0  
**Last Updated:** May 2026

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Step 1: Install Consul on Both Clusters](#step-1-install-consul-on-both-clusters)
4. [Step 2: Configure Mesh Gateway Settings](#step-2-configure-mesh-gateway-settings)
5. [Step 3: Create Peering Token](#step-3-create-peering-token)
6. [Step 4: Establish Peering Connection](#step-4-establish-peering-connection)
7. [Step 5: Export Services](#step-5-export-services)
8. [Step 6: Create Service Intentions](#step-6-create-service-intentions)
9. [Step 7: Deploy and Test Services](#step-7-deploy-and-test-services)
10. [Verification](#verification)
11. [Troubleshooting](#troubleshooting)

---

## Overview

Cluster peering connects two or more independent Consul clusters so that services deployed to different datacenters can communicate securely.

**Key Components:**
- **Peering Token:** Securely establishes communication between clusters
- **Mesh Gateway:** Encrypts/decrypts traffic and routes to healthy services
- **Exported Services:** Explicitly defines which services can communicate across clusters
- **Service Intentions:** Enforces identity-based access control via mTLS

**Use Cases:**
- Multi-cloud architectures
- Service failover and sameness groups
- Cross-team service sharing
- Disaster recovery

---

## Prerequisites

### Set Environment Variables

```bash
kubectl config get-contexts

export CLUSTER1_CONTEXT=<CONTEXT for first Kubernetes cluster>
export CLUSTER2_CONTEXT=<CONTEXT for second Kubernetes cluster>
export CONSUL_VERSION=<CONSUL VERSION, e.g., "1.16.0">
export HELM_RELEASE_NAME1=cluster-01
export HELM_RELEASE_NAME2=cluster-02
```

### Verify Cluster Access

```bash
kubectl --context $CLUSTER1_CONTEXT get nodes
kubectl --context $CLUSTER2_CONTEXT get nodes
```

---

## Step 1: Install Consul on Both Clusters

### 1.1 Create values.yaml

Create a `values.yaml` file with the following **complete** configuration:

```yaml
global:
  name: consul
  image: "hashicorp/consul:1.16.0"
  peering:
    enabled: true
  tls:
    enabled: true

connectInject:
  enabled: true          # REQUIRED for peering

meshGateway:
  enabled: true
  wanAddress:
    source: "Service"    # Advertises LoadBalancer hostname
    port: 443
```

> **⚠️ Critical:** `connectInject.enabled: true` and `meshGateway.wanAddress` are **required**. Peering CRDs also require healthy Consul Kubernetes control-plane components.

### 1.2 Install Consul on Cluster 1

```bash
helm install ${HELM_RELEASE_NAME1} hashicorp/consul \
  --create-namespace \
  --namespace consul \
  --version ${CONSUL_VERSION} \
  --values values.yaml \
  --set global.datacenter=dc1 \
  --kube-context $CLUSTER1_CONTEXT
```

### 1.3 Install Consul on Cluster 2

```bash
helm install ${HELM_RELEASE_NAME2} hashicorp/consul \
  --create-namespace \
  --namespace consul \
  --version ${CONSUL_VERSION} \
  --values values.yaml \
  --set global.datacenter=dc2 \
  --kube-context $CLUSTER2_CONTEXT
```

> **⚠️ Critical:** Cluster 1 **must** use `dc1` and Cluster 2 **must** use `dc2`. Mismatched datacenter names cause continuous reconciliation errors.

### 1.4 Verify Installation

```bash
# Check Cluster 1
kubectl --context $CLUSTER1_CONTEXT get pods -n consul

# Check Cluster 2
kubectl --context $CLUSTER2_CONTEXT get pods -n consul
```

Wait until all pods show `Running` status.

### 1.5 Verify Consul Control Plane Is Healthy

These CRD workflows require healthy Consul Kubernetes control-plane components:

- `Mesh`
- `ProxyDefaults`
- `PeeringAcceptor`
- `PeeringDialer`
- `ExportedServices`
- `ServiceIntentions`
- `ServiceResolver`

Run:

```bash
# Verify required deployments exist
kubectl --context $CLUSTER1_CONTEXT get deploy consul-connect-injector consul-webhook-cert-manager -n consul
kubectl --context $CLUSTER2_CONTEXT get deploy consul-connect-injector consul-webhook-cert-manager -n consul

# Verify readiness
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-connect-injector -n consul
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-connect-injector -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul
```

Verify peering CRDs are installed:

```bash
kubectl --context $CLUSTER1_CONTEXT get crd peeringacceptors.consul.hashicorp.com peeringdialers.consul.hashicorp.com exportedservices.consul.hashicorp.com serviceintentions.consul.hashicorp.com serviceresolvers.consul.hashicorp.com
```

If components are missing or unhealthy, reconcile both releases:

```bash
helm upgrade ${HELM_RELEASE_NAME1} hashicorp/consul \
  --namespace consul \
  --version ${CONSUL_VERSION} \
  --values values.yaml \
  --set global.datacenter=dc1 \
  --kube-context $CLUSTER1_CONTEXT \
  --cleanup-on-fail

helm upgrade ${HELM_RELEASE_NAME2} hashicorp/consul \
  --namespace consul \
  --version ${CONSUL_VERSION} \
  --values values.yaml \
  --set global.datacenter=dc2 \
  --kube-context $CLUSTER2_CONTEXT \
  --cleanup-on-fail
```

---

## Step 2: Configure Mesh Gateway Settings

### 2.1 Create mesh.yaml

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: Mesh
metadata:
  name: mesh
  namespace: consul
spec:
  peering:
    peerThroughMeshGateways: true
```

### 2.2 Apply to Both Clusters

```bash
# Apply to Cluster 1
kubectl --context $CLUSTER1_CONTEXT apply -f mesh.yaml

# Apply to Cluster 2
kubectl --context $CLUSTER2_CONTEXT apply -f mesh.yaml
```

### 2.3 Create proxy-defaults.yaml

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ProxyDefaults
metadata:
  name: global
  namespace: consul
spec:
  meshGateway:
    mode: local
```

> **Note:** `mode: local` ensures traffic always exits through the local mesh gateway.

### 2.4 Apply to Both Clusters

```bash
# Apply to Cluster 1
kubectl --context $CLUSTER1_CONTEXT apply -f proxy-defaults.yaml

# Apply to Cluster 2
kubectl --context $CLUSTER2_CONTEXT apply -f proxy-defaults.yaml
```

---

## Step 3: Create Peering Token

### 3.1 Create acceptor.yaml

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: PeeringAcceptor
metadata:
  name: cluster-02
  namespace: consul    # REQUIRED - must be in consul namespace
spec:
  peer:
    secret:
      name: "peering-token"
      key: "data"
      backend: "kubernetes"
```

> **⚠️ Critical:** The `namespace: consul` field is **required**. If omitted, the token will not be generated.

### 3.2 Apply to Cluster 1

```bash
kubectl --context $CLUSTER1_CONTEXT apply -f acceptor.yaml
```

### 3.3 Verify Token Generation

```bash
# Verify acceptor is in consul namespace
kubectl --context $CLUSTER1_CONTEXT get peeringacceptors -A

# Verify token secret was created
kubectl --context $CLUSTER1_CONTEXT get secret peering-token -n consul
```

Expected output should show the secret exists in the `consul` namespace.

### 3.4 Export Token

```bash
kubectl --context $CLUSTER1_CONTEXT get secret peering-token -n consul -o yaml > peering-token.yaml
```

> **⚠️ Warning:** Peering tokens are **single-use**. Regenerating the acceptor invalidates previous tokens. Always use the most recently generated token.

---

## Step 4: Establish Peering Connection

### 4.1 Apply Token to Cluster 2

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f peering-token.yaml
```

### 4.2 Create dialer.yaml

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: PeeringDialer
metadata:
  name: cluster-01
  namespace: consul    # REQUIRED - must be in consul namespace
spec:
  peer:
    secret:
      name: "peering-token"
      key: "data"
      backend: "kubernetes"
```

### 4.3 Apply to Cluster 2

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f dialer.yaml
```

### 4.4 Verify Peering Status

```bash
# Check CRD sync status
kubectl --context $CLUSTER1_CONTEXT get peeringacceptors -n consul
kubectl --context $CLUSTER2_CONTEXT get peeringdialers -n consul
```

Both should show `SYNCED: True`.

### 4.5 Verify via Consul API

```bash
# Get ACL token
TOKEN=$(kubectl --context $CLUSTER1_CONTEXT get secret consul-bootstrap-acl-token \
  -n consul -o jsonpath='{.data.token}' | base64 --decode)

# Check peering status
kubectl --context $CLUSTER1_CONTEXT exec -n consul consul-server-0 \
  -- consul peering list -token $TOKEN
```

Expected output: `State: ACTIVE`

---

## Step 5: Export Services

### 5.1 Create backend.yaml

Deploy a backend service in Cluster 2:

```yaml
# Service to expose backend
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: default
spec:
  selector:
    app: backend
  ports:
  - name: http
    protocol: TCP
    port: 80
    targetPort: 9090
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend
  namespace: default
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: default
  labels:
    app: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
      annotations:
        "consul.hashicorp.com/connect-inject": "true"
    spec:
      serviceAccountName: backend
      containers:
      - name: backend
        image: nicholasjackson/fake-service:v0.22.4
        ports:
        - containerPort: 9090
        env:
        - name: "LISTEN_ADDR"
          value: "0.0.0.0:9090"
        - name: "NAME"
          value: "backend"
        - name: "MESSAGE"
          value: "Response from backend"
```

### 5.2 Deploy Backend

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f backend.yaml
```

### 5.3 Create exported-service.yaml

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ExportedServices
metadata:
  name: default
  namespace: consul
spec:
  services:
  - name: backend
    consumers:
    - peer: cluster-01    # Must match PeeringDialer name
```

### 5.4 Apply Export Configuration

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f exported-service.yaml
```

---

## Step 6: Create Service Intentions

### 6.1 Create intention.yaml

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceIntentions
metadata:
  name: backend-deny
  namespace: consul
spec:
  destination:
    name: backend
  sources:
  - name: "*"
    action: deny
  - name: frontend
    action: allow
    peer: cluster-01    # Must match PeeringDialer name
```

### 6.2 Apply Intentions

```bash
kubectl --context $CLUSTER2_CONTEXT apply -f intention.yaml
```

---

## Step 7: Deploy and Test Services

### 7.1 Create frontend.yaml

Deploy a frontend service in Cluster 1 that calls the backend in Cluster 2:

```yaml
# Service to expose frontend
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: default
spec:
  selector:
    app: frontend
  ports:
  - name: http
    protocol: TCP
    port: 9090
    targetPort: 9090
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend
  namespace: default
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: default
  labels:
    app: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
      annotations:
        "consul.hashicorp.com/connect-inject": "true"
    spec:
      serviceAccountName: frontend
      containers:
      - name: frontend
        image: nicholasjackson/fake-service:v0.22.4
        securityContext:
          capabilities:
            add: ["NET_ADMIN"]
        ports:
        - containerPort: 9090
        env:
        - name: "LISTEN_ADDR"
          value: "0.0.0.0:9090"
        - name: "UPSTREAM_URIS"
          value: "http://backend.virtual.cluster-02.consul"
        - name: "NAME"
          value: "frontend"
        - name: "MESSAGE"
          value: "Hello World"
        - name: "HTTP_CLIENT_KEEP_ALIVES"
          value: "false"
```

> **Note:** The DNS format for peered services is: `service-name.virtual.peer-name.consul`

### 7.2 Deploy Frontend

```bash
kubectl --context $CLUSTER1_CONTEXT apply -f frontend.yaml
```

---

## Verification

### Test Cross-Cluster Communication

```bash
kubectl --context $CLUSTER1_CONTEXT exec -it \
  $(kubectl --context $CLUSTER1_CONTEXT get pod -l app=frontend -o name) \
  -- curl localhost:9090
```

### Expected Successful Response

```json
{
  "name": "frontend",
  "uri": "/",
  "type": "HTTP",
  "ip_addresses": ["10.16.2.11"],
  "start_time": "2022-08-26T23:40:01.167199",
  "end_time": "2022-08-26T23:40:01.226951",
  "duration": "59.752279ms",
  "body": "Hello World",
  "upstream_calls": {
    "http://backend.virtual.cluster-02.consul": {
      "name": "backend",
      "uri": "http://backend.virtual.cluster-02.consul",
      "type": "HTTP",
      "ip_addresses": ["10.32.2.10"],
      "start_time": "2022-08-26T23:40:01.223503",
      "end_time": "2022-08-26T23:40:01.224653",
      "duration": "1.149666ms",
      "body": "Response from backend",
      "code": 200
    }
  },
  "code": 200
}
```

---

## Troubleshooting

### Issue 1: Peering Status Stuck in "Pending"

**Symptoms:** Consul UI shows peering in "Pending" state with no heartbeat data.

**Resolution Steps:**

#### Step 1: Verify CRDs are in Correct Namespace

```bash
kubectl --context $CLUSTER1_CONTEXT get peeringacceptors -A
kubectl --context $CLUSTER2_CONTEXT get peeringdialers -A
```

Both must show `namespace: consul`. If showing `namespace: default`:

```bash
# Delete and recreate with correct namespace
kubectl --context $CLUSTER1_CONTEXT delete peeringacceptor cluster-02 -n default
kubectl --context $CLUSTER1_CONTEXT apply -f acceptor.yaml
```

#### Step 2: Verify Peering Token Exists

```bash
kubectl --context $CLUSTER1_CONTEXT get secret peering-token -n consul
kubectl --context $CLUSTER2_CONTEXT get secret peering-token -n consul
```

If missing, regenerate and copy the token.

#### Step 3: Verify Mesh Gateway WAN Address

```bash
TOKEN=$(kubectl --context $CLUSTER1_CONTEXT get secret consul-bootstrap-acl-token \
  -n consul -o jsonpath='{.data.token}' | base64 --decode)

kubectl --context $CLUSTER1_CONTEXT exec -n consul consul-server-0 \
  -- wget -qO- --no-check-certificate \
  --header "X-Consul-Token: $TOKEN" \
  "https://localhost:8501/v1/catalog/service/mesh-gateway"
```

Look for `ServiceTaggedAddresses.wan` - it must show the LoadBalancer hostname, **not** an internal IP:

```json
"ServiceTaggedAddresses": {
  "lan": { "Address": "10.x.x.x", "Port": 8443 },
  "wan": { "Address": "<elb-hostname>.elb.amazonaws.com", "Port": 443 }
}
```

If showing internal IP, ensure `meshGateway.wanAddress` is set in `values.yaml` and restart:

```bash
helm upgrade consul hashicorp/consul \
  --namespace consul \
  --values values.yaml \
  --set global.datacenter=dc1 \
  --kube-context $CLUSTER1_CONTEXT

kubectl --context $CLUSTER1_CONTEXT rollout restart deployment consul-mesh-gateway -n consul
```

#### Step 4: Check Consul Server Logs

```bash
kubectl --context $CLUSTER2_CONTEXT logs -n consul consul-server-0 \
  --tail=50 | grep -i "peer\|error\|grpc"
```

**Common Errors:**

| Error | Cause | Resolution |
|-------|-------|------------|
| `invalid peering establishment secret` | Stale token | Generate fresh token (see Issue 2) |
| `initial subscription for unknown PeerID` | Corrupted state | Reset peering (see Issue 2) |
| `authentication handshake failed` | TLS mismatch | Verify TLS config matches on both clusters |
| `dial tcp <internal-ip>:8443: i/o timeout` | Wrong WAN address | Fix `meshGateway.wanAddress` config |

---

### Issue 2: Reset Corrupted Peering State

If tokens have been regenerated multiple times or peer IDs are mismatched:

```bash
# Get ACL tokens
TOKEN1=$(kubectl --context $CLUSTER1_CONTEXT get secret consul-bootstrap-acl-token \
  -n consul -o jsonpath='{.data.token}' | base64 --decode)

TOKEN2=$(kubectl --context $CLUSTER2_CONTEXT get secret consul-bootstrap-acl-token \
  -n consul -o jsonpath='{.data.token}' | base64 --decode)

# Delete peering from Consul state
kubectl --context $CLUSTER1_CONTEXT exec -n consul consul-server-0 \
  -- consul peering delete -name cluster-02 -token $TOKEN1

kubectl --context $CLUSTER2_CONTEXT exec -n consul consul-server-0 \
  -- consul peering delete -name cluster-01 -token $TOKEN2

# Delete Kubernetes resources
kubectl --context $CLUSTER1_CONTEXT delete peeringacceptor cluster-02 -n consul --ignore-not-found
kubectl --context $CLUSTER1_CONTEXT delete secret peering-token -n consul --ignore-not-found
kubectl --context $CLUSTER2_CONTEXT delete peeringdialer cluster-01 -n consul --ignore-not-found
kubectl --context $CLUSTER2_CONTEXT delete secret peering-token -n consul --ignore-not-found

# Wait for state to clear
sleep 30

# Start fresh
kubectl --context $CLUSTER1_CONTEXT apply -f acceptor.yaml
```

---

### Issue 3: Webhook Certificate Errors

**Symptoms:** Errors like `failed calling webhook: tls: failed to verify certificate`

**Resolution:**

```bash
# Restart connect-injector
kubectl --context $CLUSTER1_CONTEXT rollout restart deployment consul-connect-injector -n consul
kubectl --context $CLUSTER1_CONTEXT rollout status deployment consul-connect-injector -n consul

# Delete stale webhook configurations
kubectl --context $CLUSTER1_CONTEXT delete mutatingwebhookconfiguration \
  consul-connect-injector --ignore-not-found
kubectl --context $CLUSTER1_CONTEXT delete mutatingwebhookconfiguration \
  consul-mutating-webhook-configuration --ignore-not-found

# Restart again to recreate webhooks
kubectl --context $CLUSTER1_CONTEXT rollout restart deployment consul-connect-injector -n consul
```

If a CRD is stuck in `Terminating` state:

```bash
kubectl --context $CLUSTER1_CONTEXT patch peeringacceptor cluster-02 \
  -n consul --type=merge \
  -p '{"metadata":{"finalizers":[]}}'
```

---

### Issue 4: ProxyDefaults Datacenter Mismatch

**Symptoms:** Logs show `config entry managed in different datacenter: "dc2"`

**Resolution:**

```bash
# Verify datacenter names
kubectl --context $CLUSTER1_CONTEXT get configmap consul-server-config \
  -n consul -o yaml | grep datacenter

kubectl --context $CLUSTER2_CONTEXT get configmap consul-server-config \
  -n consul -o yaml | grep datacenter
```

Cluster 1 must show `dc1`, Cluster 2 must show `dc2`.

If incorrect, upgrade with correct datacenter:

```bash
# Delete immutable jobs first
kubectl --context $CLUSTER2_CONTEXT delete jobs \
  consul-server-acl-init \
  consul-server-acl-init-cleanup \
  consul-gateway-resources \
  -n consul --ignore-not-found

# Upgrade with correct datacenter
helm upgrade consul hashicorp/consul \
  --namespace consul \
  --version ${CONSUL_VERSION} \
  --values values.yaml \
  --set global.datacenter=dc2 \
  --kube-context $CLUSTER2_CONTEXT \
  --cleanup-on-fail

# Delete stale ProxyDefaults
kubectl --context $CLUSTER2_CONTEXT delete proxydefaults global -n default --ignore-not-found
```

---

### Issue 5: Helm Upgrade Blocked by Immutable Jobs

**Symptoms:** `helm upgrade` fails with "field is immutable" error

**Resolution:**

```bash
# Delete immutable jobs before upgrading
kubectl --context $CLUSTER1_CONTEXT delete jobs \
  consul-server-acl-init \
  consul-server-acl-init-cleanup \
  consul-gateway-resources \
  -n consul --ignore-not-found

# Run upgrade with cleanup flag
helm upgrade consul hashicorp/consul \
  --namespace consul \
  --version ${CONSUL_VERSION} \
  --values values.yaml \
  --set global.datacenter=dc1 \
  --set global.peering.enabled=true \
  --set connectInject.enabled=true \
  --kube-context $CLUSTER1_CONTEXT \
  --cleanup-on-fail
```

---

### Issue 6: CRDs Apply but Never Reconcile

**Symptoms:** `Mesh`, `PeeringAcceptor`, `PeeringDialer`, `ExportedServices`, `ServiceIntentions`, or `ServiceResolver` stay unsynced, and token generation does not complete.

**Likely Cause:** Consul Kubernetes control-plane components are missing/unhealthy, or peering CRDs were not installed.

**Resolution:**

```bash
# Check control-plane components
kubectl --context $CLUSTER1_CONTEXT get deploy consul-connect-injector consul-webhook-cert-manager -n consul
kubectl --context $CLUSTER2_CONTEXT get deploy consul-connect-injector consul-webhook-cert-manager -n consul

# Check peering CRDs
kubectl --context $CLUSTER1_CONTEXT get crd peeringacceptors.consul.hashicorp.com peeringdialers.consul.hashicorp.com exportedservices.consul.hashicorp.com serviceintentions.consul.hashicorp.com serviceresolvers.consul.hashicorp.com

# If missing/unhealthy, upgrade both releases
helm upgrade ${HELM_RELEASE_NAME1} hashicorp/consul \
  --namespace consul \
  --version ${CONSUL_VERSION} \
  --values values.yaml \
  --set global.datacenter=dc1 \
  --kube-context $CLUSTER1_CONTEXT \
  --cleanup-on-fail

helm upgrade ${HELM_RELEASE_NAME2} hashicorp/consul \
  --namespace consul \
  --version ${CONSUL_VERSION} \
  --values values.yaml \
  --set global.datacenter=dc2 \
  --kube-context $CLUSTER2_CONTEXT \
  --cleanup-on-fail

# Verify control-plane readiness after upgrade
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-connect-injector -n consul
kubectl --context $CLUSTER1_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-connect-injector -n consul
kubectl --context $CLUSTER2_CONTEXT rollout status deployment/consul-webhook-cert-manager -n consul
```

---

## Quick Reference Commands

### Check Peering Status

```bash
# Via Consul API
TOKEN=$(kubectl --context $CLUSTER1_CONTEXT get secret consul-bootstrap-acl-token \
  -n consul -o jsonpath='{.data.token}' | base64 --decode)

kubectl --context $CLUSTER1_CONTEXT exec -n consul consul-server-0 \
  -- consul peering list -token $TOKEN
```

### View Exported Services

```bash
kubectl --context $CLUSTER2_CONTEXT get exportedservices -n consul
```

### Check Mesh Gateway Status

```bash
kubectl --context $CLUSTER1_CONTEXT get svc -n consul | grep mesh-gateway
kubectl --context $CLUSTER1_CONTEXT get pods -n consul | grep mesh-gateway
```

### View Service Intentions

```bash
kubectl --context $CLUSTER2_CONTEXT get serviceintentions -n consul
```

### Check Pod Logs

```bash
# Connect injector logs
kubectl --context $CLUSTER1_CONTEXT logs -n consul deployment/consul-connect-injector

# Mesh gateway logs
kubectl --context $CLUSTER1_CONTEXT logs -n consul deployment/consul-mesh-gateway

# Server logs
kubectl --context $CLUSTER1_CONTEXT logs -n consul consul-server-0
```

---

## Summary of Critical Requirements

✅ **Must Have:**
- `connectInject.enabled: true` in values.yaml
- `meshGateway.wanAddress` configured in values.yaml
- Cluster 1 uses `dc1`, Cluster 2 uses `dc2`
- All CRDs created in `consul` namespace
- Fresh peering token (not regenerated)

❌ **Common Mistakes:**
- Missing `namespace: consul` in CRD metadata
- Using internal IP instead of LoadBalancer hostname
- Mismatched datacenter names
- Regenerating tokens without cleanup
- Missing `connectInject.enabled: true`

---

## Additional Resources

- [Consul Cluster Peering Documentation](https://developer.hashicorp.com/consul/docs/connect/cluster-peering)
- [Mesh Gateway Configuration](https://developer.hashicorp.com/consul/docs/connect/gateways/mesh-gateway)
- [Service Mesh on Kubernetes](https://developer.hashicorp.com/consul/docs/k8s)
- [Consul CRD Reference](https://developer.hashicorp.com/consul/docs/k8s/crds)

---

**Document End**
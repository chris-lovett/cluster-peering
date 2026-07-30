# Consul Cluster Peering on OpenShift

**Environment:** Consul Enterprise 2.0.1-ent · OpenShift · Kubernetes CRD-based peering

Cluster peering lets two independent Consul clusters discover and call each other's services over mTLS — without sharing a root CA, merging datacenters, or centralizing administrative control. Each cluster retains full autonomy. Only the services you explicitly export become visible to the peer.

This repo contains the Helm configuration, Consul CRDs, and sample application manifests needed to establish and validate a peering connection, along with a runnable east-west failover demo.

---

## Where to start

If you are setting up peering for the first time, follow the **[Setup Guide](CLUSTER_PEERING_SETUP_GUIDE.md)** in order. It will walk you through every step with inline verification checkpoints. When something goes wrong, the **[Troubleshooting Guide](TROUBLESHOOTING.md)** covers every known failure mode with exact remediation commands.

| Document | Purpose |
|---|---|
| [CLUSTER_PEERING_SETUP_GUIDE.md](CLUSTER_PEERING_SETUP_GUIDE.md) | Step-by-step installation from Helm install through verified cross-cluster communication |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Issue-by-issue diagnosis and remediation for pre-activation and activation failures |
| [east-west-failover/DEMO.md](east-west-failover/DEMO.md) | Runnable demo showing automatic east-west traffic failover across the peering boundary |

---

## How it works

All cross-cluster traffic flows through a **mesh gateway** on each side. The gateways terminate and re-establish mTLS at the cluster boundary, so services never need a direct network path to each other — only the two mesh gateways need to reach each other over port 443.

```
  cluster-01  (DIALER)                      cluster-02  (ACCEPTOR)
  ┌────────────────────────────┐               ┌────────────────────────────┐
  │  namespace: consul         │               │  namespace: consul          │
  │                            │               │                             │
  │  PeeringDialer             │               │  PeeringAcceptor            │
  │  name: cluster-01          │               │  name: cluster-02           │
  │                            │               │  → generates peering-token  │
  │  ┌──────────────────────┐  │   mTLS / 443  │  ┌──────────────────────┐  │
  │  │    mesh-gateway      │◄─┼───────────────┼──│    mesh-gateway      │  │
  │  └──────────────────────┘  │               │  └──────────────────────┘  │
  │                            │               │                             │
  │  namespace: default        │               │  namespace: default         │
  │  frontend                  │               │  backend  (exported)        │
  └────────────────────────────┘               └────────────────────────────┘
```

The **acceptor** (cluster-02) generates a single-use peering token. The **dialer** (cluster-01) uses that token to initiate the connection. Once the peering is `ACTIVE`, cluster-02 can export services and cluster-01 can resolve them — but only after explicit `ExportedServices` and `ServiceIntentions` resources allow it. Consul's default is deny.

The peer name each side uses to reference the other is set by `metadata.name` on the `PeeringAcceptor` and `PeeringDialer` CRDs. Every downstream resource — `ExportedServices`, `ServiceIntentions`, `ServiceResolver` — must use these names exactly.

---

## Repository contents

### Helm configuration

| File | Purpose |
|---|---|
| [`values.yaml`](values.yaml) | Complete Helm values for Consul Enterprise 2.0.1-ent on OpenShift |

### Consul CRDs — apply in this order

| File | Cluster | What it does |
|---|---|---|
| [`mesh.yaml`](mesh.yaml) | Both | Enables `peerThroughMeshGateways: true` |
| [`proxy-defaults.yaml`](proxy-defaults.yaml) | Both | Sets all proxies to route cross-cluster traffic via the local mesh gateway |
| [`acceptor.yaml`](acceptor.yaml) | cluster-02 | Creates the peering endpoint and generates the peering token |
| [`dialer.yaml`](dialer.yaml) | cluster-01 | Initiates the peering connection using the token |
| [`exported-service.yaml`](exported-service.yaml) | cluster-02 | Makes `backend` discoverable by cluster-01 |
| [`intention.yaml`](intention.yaml) | cluster-02 | Allows `frontend` on cluster-01 to reach `backend` on cluster-02 |

### Sample application

| File | Cluster | What it does |
|---|---|---|
| [`backend.yaml`](backend.yaml) | cluster-02 | The service being exported across the peering |
| [`frontend.yaml`](frontend.yaml) | cluster-01 | Calls `backend` across the peering using virtual DNS |

---

## Additional resources

- [Consul Cluster Peering — HashiCorp Docs](https://developer.hashicorp.com/consul/docs/connect/cluster-peering)
- [Mesh Gateway Configuration](https://developer.hashicorp.com/consul/docs/connect/gateways/mesh-gateway)
- [Consul CRD Reference](https://developer.hashicorp.com/consul/docs/k8s/crds)
- [Consul on Kubernetes](https://developer.hashicorp.com/consul/docs/k8s)

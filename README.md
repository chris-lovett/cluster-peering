# Consul Cluster Peering on OpenShift

**Environment:** Consul Enterprise 2.0.1-ent · OpenShift · Kubernetes CRD-based peering

Cluster peering lets two independent Consul clusters discover and call each other's services over mTLS — without sharing a root CA, merging datacenters, or centralizing administrative control. Each cluster retains full autonomy. Only the services you explicitly export become visible to the peer.

This repo contains the Helm configuration, Consul CRDs, and sample application manifests needed to establish and validate a peering connection, along with a runnable east-west failover demo.

---

## Getting started

**[setup-guide.md](setup-guide.md)** walks through every step from Helm install to verified cross-cluster communication. Follow it in order — each step has an inline verification checkpoint before you move on.

Once peering is established, **[east-west-failover/DEMO.md](east-west-failover/DEMO.md)** lets you validate the setup with a realistic two-service application. It simulates a primary outage and confirms that traffic automatically fails over to the peer cluster — a good confidence check before using peering in production.

If something goes wrong at any point, **[troubleshooting.md](troubleshooting.md)** covers every known failure mode with exact diagnosis steps and remediation commands.

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

## Additional resources

- [Consul Cluster Peering — HashiCorp Docs](https://developer.hashicorp.com/consul/docs/connect/cluster-peering)
- [Mesh Gateway Configuration](https://developer.hashicorp.com/consul/docs/connect/gateways/mesh-gateway)
- [Consul CRD Reference](https://developer.hashicorp.com/consul/docs/k8s/crds)
- [Consul on Kubernetes](https://developer.hashicorp.com/consul/docs/k8s)

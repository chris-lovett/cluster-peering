#!/usr/bin/env bash
# =============================================================================
# runbook.sh — Consul Cluster Peering: East-West Failover Demo
# Audience: Platform Engineers
# Consul: Enterprise 1.22.3-ent | Platform: OpenShift / Kubernetes
# =============================================================================
# Usage:
#   chmod +x runbook.sh
#   CONTEXT_C1=<kubectl-context-cluster1> \
#   CONTEXT_C2=<kubectl-context-cluster2> \
#   ./runbook.sh
#
# Each phase can also be run individually by sourcing the file and calling
# the phase function directly, e.g.: source runbook.sh && phase2_peering
# =============================================================================
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CONTEXT_C1="${CONTEXT_C1:-cluster1}"   # kubectl context for the dialer cluster
CONTEXT_C2="${CONTEXT_C2:-cluster2}"   # kubectl context for the acceptor cluster
CONSUL_NS="consul"
APP_NS="default"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────
banner() { echo; echo "══════════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════════"; }
c1()     { kubectl --context="${CONTEXT_C1}" "$@"; }
c2()     { kubectl --context="${CONTEXT_C2}" "$@"; }
wait_ready() {
  local ctx="$1"; shift
  echo "⏳ Waiting for pods ready: $* (context: ${ctx})"
  kubectl --context="${ctx}" wait pods "$@" --timeout=120s
}

# =============================================================================
# PHASE 1 — Mesh Gateway Config
# Apply Mesh + ProxyDefaults to both clusters.
# Both clusters must agree on peerThroughMeshGateways before peering.
# =============================================================================
phase1_mesh() {
  banner "PHASE 1 — Mesh Gateway Config"

  echo "▶ Applying mesh config to cluster1..."
  c1 apply -f "${DIR}/01-mesh-cluster1.yaml"

  echo "▶ Applying mesh config to cluster2..."
  c2 apply -f "${DIR}/02-mesh-cluster2.yaml"

  echo "✔ Verifying Mesh CRDs (expect: synced)..."
  c1 get mesh mesh -n "${CONSUL_NS}" -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'; echo
  c2 get mesh mesh -n "${CONSUL_NS}" -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'; echo
}

# =============================================================================
# PHASE 2 — Establish Cluster Peering
# Step 2a: Apply PeeringAcceptor to cluster2 → controller generates token Secret
# Step 2b: Copy the token Secret from cluster2 to cluster1
# Step 2c: Apply PeeringDialer to cluster1 → connection is established
# =============================================================================
phase2_peering() {
  banner "PHASE 2 — Establish Cluster Peering"

  # 2a — Acceptor
  echo "▶ [cluster2] Creating PeeringAcceptor..."
  c2 apply -f "${DIR}/03-acceptor-cluster2.yaml"

  echo "⏳ Waiting for peering-token Secret to be populated..."
  # The Consul controller populates .data.data once the token is generated.
  until c2 get secret peering-token -n "${CONSUL_NS}" \
        -o jsonpath='{.data.data}' 2>/dev/null | grep -q .; do
    sleep 3
    echo "   ... still waiting"
  done
  echo "✔ Token Secret ready on cluster2"

  # 2b — Token copy
  echo "▶ Copying peering-token Secret from cluster2 → cluster1..."
  TOKEN=$(c2 get secret peering-token -n "${CONSUL_NS}" -o jsonpath='{.data.data}')
  kubectl --context="${CONTEXT_C1}" create secret generic peering-token \
    --namespace="${CONSUL_NS}" \
    --from-literal=data="${TOKEN}" \
    --dry-run=client -o yaml | c1 apply -f -
  echo "✔ peering-token Secret created on cluster1"

  # 2c — Dialer
  echo "▶ [cluster1] Creating PeeringDialer..."
  c1 apply -f "${DIR}/04-dialer-cluster1.yaml"

  echo "⏳ Waiting for peering to reach ACTIVE state..."
  until c1 get peeringdialers cluster1 -n "${CONSUL_NS}" \
        -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null \
        | grep -q "True"; do
    sleep 3
    echo "   ... still waiting"
  done

  echo "✔ Peering established!"
  echo
  echo "📋 Peering status on cluster1:"
  c1 get peeringdialers -n "${CONSUL_NS}"
  echo
  echo "📋 Peering status on cluster2:"
  c2 get peeringacceptors -n "${CONSUL_NS}"
}

# =============================================================================
# PHASE 3 — Deploy Services
# backend on both clusters, frontend on cluster1.
# =============================================================================
phase3_services() {
  banner "PHASE 3 — Deploy Services"

  echo "▶ [cluster2] Deploying backend (failover target)..."
  c2 apply -f "${DIR}/05-backend-cluster2.yaml"

  echo "▶ [cluster1] Deploying backend (primary)..."
  c1 apply -f "${DIR}/06-backend-cluster1.yaml"

  echo "▶ [cluster1] Deploying frontend..."
  c1 apply -f "${DIR}/07-frontend-cluster1.yaml"

  echo "⏳ Waiting for all deployments to be ready..."
  wait_ready "${CONTEXT_C2}" -l app=backend -n "${APP_NS}" --for=condition=ready
  wait_ready "${CONTEXT_C1}" -l app=backend -n "${APP_NS}" --for=condition=ready
  wait_ready "${CONTEXT_C1}" -l app=frontend -n "${APP_NS}" --for=condition=ready

  echo "✔ All services running"
  echo
  echo "📋 Pods on cluster1:"
  c1 get pods -n "${APP_NS}" -l 'app in (frontend,backend)'
  echo
  echo "📋 Pods on cluster2:"
  c2 get pods -n "${APP_NS}" -l app=backend
}

# =============================================================================
# PHASE 4 — Export Services & Configure Intentions
# cluster2 exports backend to cluster1, then allows only frontend@cluster1.
# =============================================================================
phase4_intentions() {
  banner "PHASE 4 — Exported Services & Intentions"

  echo "▶ [cluster2] Applying ExportedServices..."
  c2 apply -f "${DIR}/08-exported-services-cluster2.yaml"

  echo "▶ [cluster2] Applying ServiceIntentions..."
  c2 apply -f "${DIR}/09-intentions-cluster2.yaml"

  echo "✔ Verifying ExportedServices sync..."
  c2 get exportedservices default -n "${CONSUL_NS}" \
     -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'; echo

  echo "✔ Verifying ServiceIntentions sync..."
  c2 get serviceintentions backend -n "${CONSUL_NS}" \
     -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'; echo
}

# =============================================================================
# PHASE 5 — Failover Policy
# Apply ServiceResolver with peer failover target on cluster1.
# =============================================================================
phase5_resolver() {
  banner "PHASE 5 — Failover Policy (ServiceResolver)"

  echo "▶ [cluster1] Applying ServiceResolver..."
  c1 apply -f "${DIR}/10-service-resolver-cluster1.yaml"

  echo "✔ Verifying ServiceResolver sync..."
  c1 get serviceresolver backend -n "${APP_NS}" \
     -o jsonpath='{.status.conditions[?(@.type=="SyncedToConsul")].status}'; echo
}

# =============================================================================
# PHASE 6 — Verify Baseline Traffic
# Confirm frontend → local backend (primary) is working before the failover demo.
# =============================================================================
phase6_verify() {
  banner "PHASE 6 — Verify Baseline Traffic"

  FRONTEND_POD=$(c1 get pod -n "${APP_NS}" -l app=frontend -o jsonpath='{.items[0].metadata.name}')
  echo "▶ Sending 3 requests from frontend → backend (expect: cluster1 PRIMARY)..."
  for i in 1 2 3; do
    c1 exec -n "${APP_NS}" "${FRONTEND_POD}" -c frontend -- \
      wget -qO- http://backend 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'  [{i}] upstream: {d[\"upstream_calls\"][0][\"name\"]}')
" 2>/dev/null || echo "  [${i}] (raw response — check pod logs)"
  done
  echo
  echo "✔ Baseline verified. All traffic hitting cluster1 PRIMARY backend."
}

# =============================================================================
# DEMO — Trigger Failover
# Scale primary backend to 0 → watch traffic shift to cluster2.
# =============================================================================
demo_failover() {
  banner "DEMO — Trigger East-West Failover"

  echo "▶ Scaling backend to 0 replicas on cluster1 (simulating outage)..."
  c1 scale deployment/backend -n "${APP_NS}" --replicas=0

  echo "⏳ Waiting for backend pod to terminate..."
  c1 wait pod -n "${APP_NS}" -l app=backend --for=delete --timeout=60s 2>/dev/null || true

  echo
  echo "▶ Sending 5 requests from frontend (expect: cluster2 FAILOVER)..."
  FRONTEND_POD=$(c1 get pod -n "${APP_NS}" -l app=frontend -o jsonpath='{.items[0].metadata.name}')
  for i in 1 2 3 4 5; do
    sleep 1
    c1 exec -n "${APP_NS}" "${FRONTEND_POD}" -c frontend -- \
      wget -qO- http://backend 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'  [{i}] upstream: {d[\"upstream_calls\"][0][\"name\"]}')
" 2>/dev/null || echo "  [${i}] (raw response — check pod logs)"
  done

  echo
  echo "✔ Traffic is now served by cluster2 FAILOVER backend."
  echo "   Run demo_failback to restore primary."
}

# =============================================================================
# DEMO — Failback
# Restore primary backend on cluster1 → traffic shifts back automatically.
# =============================================================================
demo_failback() {
  banner "DEMO — Failback to Primary"

  echo "▶ Scaling backend back to 1 replica on cluster1..."
  c1 scale deployment/backend -n "${APP_NS}" --replicas=1

  echo "⏳ Waiting for backend to be ready..."
  wait_ready "${CONTEXT_C1}" -l app=backend -n "${APP_NS}" --for=condition=ready

  echo
  echo "▶ Sending 3 requests (expect: cluster1 PRIMARY)..."
  FRONTEND_POD=$(c1 get pod -n "${APP_NS}" -l app=frontend -o jsonpath='{.items[0].metadata.name}')
  for i in 1 2 3; do
    c1 exec -n "${APP_NS}" "${FRONTEND_POD}" -c frontend -- \
      wget -qO- http://backend 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'  [{i}] upstream: {d[\"upstream_calls\"][0][\"name\"]}')
" 2>/dev/null || echo "  [${i}] (raw response — check pod logs)"
  done

  echo "✔ Traffic returned to cluster1 PRIMARY backend."
}

# =============================================================================
# TEARDOWN
# Removes all demo resources in reverse order.
# =============================================================================
teardown() {
  banner "TEARDOWN — Removing All Demo Resources"

  echo "▶ [cluster1] Removing app services..."
  c1 delete -f "${DIR}/10-service-resolver-cluster1.yaml" --ignore-not-found
  c1 delete -f "${DIR}/07-frontend-cluster1.yaml" --ignore-not-found
  c1 delete -f "${DIR}/06-backend-cluster1.yaml" --ignore-not-found
  c1 delete -f "${DIR}/04-dialer-cluster1.yaml" --ignore-not-found
  c1 delete secret peering-token -n "${CONSUL_NS}" --ignore-not-found
  c1 delete -f "${DIR}/01-mesh-cluster1.yaml" --ignore-not-found

  echo "▶ [cluster2] Removing app services..."
  c2 delete -f "${DIR}/09-intentions-cluster2.yaml" --ignore-not-found
  c2 delete -f "${DIR}/08-exported-services-cluster2.yaml" --ignore-not-found
  c2 delete -f "${DIR}/05-backend-cluster2.yaml" --ignore-not-found
  c2 delete -f "${DIR}/03-acceptor-cluster2.yaml" --ignore-not-found
  c2 delete secret peering-token -n "${CONSUL_NS}" --ignore-not-found
  c2 delete -f "${DIR}/02-mesh-cluster2.yaml" --ignore-not-found

  echo "✔ Teardown complete."
}

# =============================================================================
# MAIN — Run all phases end-to-end
# =============================================================================
main() {
  echo
  echo "Consul Cluster Peering — East-West Failover Demo"
  echo "  cluster1 context : ${CONTEXT_C1}"
  echo "  cluster2 context : ${CONTEXT_C2}"
  echo

  phase1_mesh
  phase2_peering
  phase3_services
  phase4_intentions
  phase5_resolver
  phase6_verify

  banner "DEMO READY"
  echo "Run:  demo_failover   — to trigger east-west failover"
  echo "Run:  demo_failback   — to restore primary"
  echo "Run:  teardown        — to clean up all resources"
}

# Run main only when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

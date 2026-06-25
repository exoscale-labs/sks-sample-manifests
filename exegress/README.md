# exegress

> ⚠️ **EXPERIMENTAL / PROOF-OF-CONCEPT.** This is a sample, not a supported
> product. It has had limited real-world testing, no security review, and its
> API (`EgressGateway` CRD) may change without notice. Use at your own risk and
> validate thoroughly before relying on it. Not covered by Exoscale support.

A Kubernetes controller that gives Exoscale SKS a **stable, highly-available
egress source IP** for traffic to specific external destinations — without a
standalone NAT VM.

It is the controller-managed evolution of the NAT-gateway pattern (see the
sibling `sks-gateway-example`): one cluster node acts as the active **egress
gateway** holding a pinned Elastic IP; traffic to configured destination CIDRs is
routed through it and SNAT'd to that EIP. If the gateway node fails, the
controller re-attaches the EIP to a healthy node and rewires routing
(**active/passive failover**).

## How it works

- **CRD `EgressGateway`** (cluster-scoped) — pinned EIP + destination CIDRs +
  node eligibility selector.
- **Controller** — selects the active gateway node, attaches the EIP via the
  Exoscale API (egoscale v3), resolves the node's private-network IP, and
  publishes resolved state into the `exegress-state` ConfigMap.
- **Node agent** (DaemonSet) — file-driven from that ConfigMap: redirect routes
  on every node, EIP alias + destination-scoped SNAT on the active gateway.

```
pod ─(CNI natOutgoing: SNAT pod→node private IP)→ node eth1
node ─(route: dest CIDR via gateway private IP, dev eth1)→ gateway node
gateway ─(SNAT dest→EIP, dev eth0)→ internet   (source = EIP)
```

## Prerequisites

- SKS nodepool attached to a **managed private network**.
- CNI does pod→node masquerade by default (Calico `natOutgoing` / Cilium
  masquerade — both true on managed SKS).
- A pre-created, `manual`-type Elastic IP (the controller never creates/deletes
  EIPs). Its address goes on the partner's allowlist.

## Quick start (in-cluster)

The controller image is built by CI to
`ghcr.io/exoscale-labs/exegress-controller`.

```bash
# 1. CRD + RBAC + node agent
kubectl apply -f deploy/exegress.io_egressgateways.yaml
kubectl apply -f deploy/rbac.yaml
kubectl -n kube-system create configmap exegress-agent-script \
  --from-file=agent.sh=hack/agent.sh
kubectl apply -f deploy/agent-daemonset.yaml

# 2. Controller: edit deploy/controller-deployment.yaml (Exoscale creds Secret,
#    EXOSCALE_ZONE, EXEGRESS_PN_ID), then:
kubectl apply -f deploy/controller-deployment.yaml

# 3. Mark eligible gateway nodes
kubectl label node <node> exegress.io/eligible=true

# 4. Create an EgressGateway (see deploy/example-egressgateway.yaml)
kubectl apply -f deploy/example-egressgateway.yaml
```

### Local run (development)

The controller also runs out-of-cluster against a kubeconfig — handy for
iterating without building an image:

```bash
EXOSCALE_API_KEY=… EXOSCALE_API_SECRET=… EXOSCALE_ZONE=de-fra-1 \
  EXEGRESS_PN_ID=<private-network-uuid> go run ./cmd/controller
```

## Validated end-to-end (SKS, de-fra-1, Calico)

| Test | Result |
|---|---|
| Pod on **non-gateway** node → `curl` pinned dest | returned the EIP (full cross-node path) |
| Gateway datapath | EIP aliased on `eth0`; `nat POSTROUTING -d <dest> -j SNAT --to-source <EIP>` present |
| Failover (`stop` active node) | controller moved the EIP to the other node in seconds; egress still returned the same EIP |
| Stickiness | recovered node did not trigger fail-back (no flapping) |

## Status / roadmap

v1 selects egress by **destination CIDR** on stock managed SKS. Per-pod /
per-namespace selection (true OpenShift-EgressIP parity) is a possible second
datapath backend, on self-managed-CNI clusters via Cilium Egress Gateway.

## Limitations

- Active/passive: in-flight TCP connections to the destination break on failover
  and reconnect (acceptable for SMTP-style traffic).
- The controller resolves node private IPs via the Exoscale API (SKS reports the
  node's *public* IP as the Kubernetes `InternalIP`).
- Experimental: see the banner at the top.

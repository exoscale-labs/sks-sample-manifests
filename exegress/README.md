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
                          Internet
                 (destination CIDR, e.g. mail relay)
                              ^
                              |   src = Elastic IP
                              |
          +-------------------+--------------------+
          |  GATEWAY NODE  (holds the Elastic IP)  |
          |    eth0 : <EIP>/32 aliased             |
          |    nat  : POSTROUTING -d <dest>        |
          |           -o eth0 -j SNAT --to <EIP>   |
          +-------------------+--------------------+
                              ^
                              |   private network (eth1)
                              |   src = worker node private IP
          +-------------------+--------------------+
          |  WORKER NODE                           |
          |    route: <dest> via <gw-priv-ip> eth1 |
          |    CNI natOutgoing:                    |
          |       SNAT pod IP -> node private IP    |
          +-------------------+--------------------+
                              ^
                              |
                          +---+----+
                          |  Pod   |   curl <dest>
                          +--------+

Reply traffic retraces the path: it arrives on the gateway's Elastic IP,
conntrack reverses both SNATs, and it lands back in the pod.
```

## Prerequisites

- SKS nodepool attached to a **managed private network**.
- CNI does pod→node masquerade by default. **Validated on both Calico
  (`natOutgoing`) and Cilium** on managed SKS — egress and failover work the
  same on each.
- A pre-created, `manual`-type Elastic IP (the controller never creates/deletes
  EIPs). Its address goes on the partner's allowlist.

## Quick start (in-cluster)

The controller image is built by CI to
`ghcr.io/exoscale-labs/exegress-controller`.

No manifest editing required — all config is supplied via a Secret and a
ConfigMap you create on the command line.

```bash
# 1. CRD + RBAC + node agent
kubectl apply -f deploy/exegress.io_egressgateways.yaml
kubectl apply -f deploy/rbac.yaml
kubectl -n kube-system create configmap exegress-agent-script \
  --from-file=agent.sh=hack/agent.sh
kubectl apply -f deploy/agent-daemonset.yaml

# 2. Controller config — paste your values, no YAML to edit:
kubectl -n kube-system create secret generic exegress-exoscale-creds \
  --from-literal=EXOSCALE_API_KEY=EXOxxxxxxxxxxxxxxxxxxxx \
  --from-literal=EXOSCALE_API_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

kubectl -n kube-system create configmap exegress-config \
  --from-literal=EXOSCALE_ZONE=de-fra-1 \
  --from-literal=EXEGRESS_PN_ID=<private-network-uuid> \
  --from-literal=EXEGRESS_LEADER_ELECT=true

kubectl apply -f deploy/controller-deployment.yaml

# 3. Mark eligible gateway nodes
kubectl label node <node> exegress.io/eligible=true

# 4. Create an EgressGateway — paste your EIP + destinations, no file to edit:
kubectl apply -f - <<'EOF'
apiVersion: exegress.io/v1alpha1
kind: EgressGateway
metadata:
  name: mail-relay
spec:
  elasticIP:
    id: "<elastic-ip-uuid>"
    address: "<elastic-ip-address>"
  destinations:
    - "192.0.2.25/32"          # e.g. the partner mail relay
  gatewayNodeSelector:
    matchLabels:
      exegress.io/eligible: "true"
EOF
```

To update config later, re-create the Secret/ConfigMap (e.g. with
`kubectl create ... --dry-run=client -o yaml | kubectl apply -f -`) and restart
the controller: `kubectl -n kube-system rollout restart deploy/exegress-controller`.

### Local run (development)

The controller also runs out-of-cluster against a kubeconfig — handy for
iterating without building an image:

```bash
EXOSCALE_API_KEY=… EXOSCALE_API_SECRET=… EXOSCALE_ZONE=de-fra-1 \
  EXEGRESS_PN_ID=<private-network-uuid> go run ./cmd/controller
```

## Dynamic destinations: FQDN & Exoscale DBaaS

A static CIDR breaks when the destination IP moves. For destinations reachable
by name (and especially **Exoscale DBaaS**, whose endpoint IP can change on
failover/maintenance with a short DNS TTL), use the dynamic sources — they're
additive; plain `destinations:` CIDRs keep the simple static path.

```yaml
spec:
  destinationDNS: ["partner-api.example.com"]   # resolved + refreshed (A records)
  dbaasServices: ["my-pg"]                       # Exoscale DBaaS service by name
  manageDBaaSIPFilter: true                      # ensure the EIP is in the service ip-filter (add-only)
  resolveIntervalSeconds: 10                     # poll cadence — match short DBaaS TTLs
  dnsGraceSeconds: 300                           # keep departed IPs routed while connections drain
```

How it handles short TTLs (see `deploy/example-egressgateway-dbaas.yaml`):
- The controller re-resolves every `resolveIntervalSeconds` and routes the
  **full A-record set**.
- A **rolling window** (`dnsGraceSeconds`) keeps recently-seen IPs routed after
  they leave DNS, so connections drain instead of breaking on every rotation.
- Supported DBaaS types: `pg`, `mysql`, `valkey`, `opensearch`, `kafka`,
  `grafana`. `manageDBaaSIPFilter` is **add-only** — it never removes existing
  entries (including `0.0.0.0/0`), so it can't lock anything out; restricting the
  filter to only the EIP stays a deliberate manual step.
- Residual race: a brand-new IP that a pod resolves in the seconds before the
  controller's next poll isn't yet routed. For zero-race needs, route a broad
  CIDR instead.

**IAM scope:** with DBaaS features the controller's API key additionally needs
DBaaS read + update (for the ip-filter). Without `dbaasServices`, only
compute-instance read + private-network read + elastic-IP attach/detach.

## High availability & node eviction

- Run **2 controller replicas** (default) with leader election; they spread
  across nodes (anti-affinity), so a node eviction lets the standby take over.
- Node selection is **cordon-aware**: when a node is cordoned/drained (e.g.
  during an SKS upgrade) the controller proactively moves the EIP to a healthy
  *schedulable* node **before** the old one is deleted, rather than waiting for
  it to disappear. If every eligible node is cordoned, it keeps serving on a
  Ready node.
- The node agent re-applies its datapath on a timer, so it self-heals after pod
  restarts, DHCP renewals, or netplan reloads.

## Validated end-to-end (SKS, de-fra-1, on both Calico and Cilium)

| Test | Result |
|---|---|
| Pod on **non-gateway** node → `curl` pinned dest | returned the EIP (full cross-node path) |
| Gateway datapath | EIP aliased on `eth0`; `nat POSTROUTING -d <dest> -j SNAT --to-source <EIP>` present |
| Failover (`stop` active node) | controller moved the EIP to the other node in seconds; egress still returned the same EIP |
| Stickiness | recovered node did not trigger fail-back (no flapping) |
| Controller **in-cluster** (GHCR image + leader election) | acquired the lease, reconciled, and performed the same node-stop failover while running as a Deployment |

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

# DBaaS IP Filter Automation for SKS

> **Sample, not a supported product.** Provided as-is and not covered by the
> Exoscale SLA, see [Service level and support](https://community.exoscale.com/documentation/sks/overview/#service-level-and-support).
> Issues and pull requests are welcome without any commitment to resolve them.
> Read the code, pin the image version rather than tracking `latest`, and
> validate with `DRY_RUN` before relying on it. See the [repository README](../README.md)
> for what to expect from this repository.

Automatically maintain DBaaS IP firewall rules by monitoring SKS cluster node IPs.

**Features:**
- Supports single or multiple SKS clusters
- Supports single or multiple DBaaS services (PostgreSQL, MySQL, Kafka, OpenSearch, Valkey, Grafana)
- Minimal IAM permissions required
- Can run on: VM, local machine, or Kubernetes

It fetches the node IPs from all configured Kubernetes clusters and updates the IP filter for every configured database.
To create separate cluster-to-database pairings, deploy multiple instances (e.g., in different Kubernetes namespaces).

## Quick Start

### Option 1: Run with Docker

```bash
docker run -d \
  -e EXOSCALE_API_KEY="EXOxxxxxxxxxxxxxxxxxxxxxxxx" \
  -e EXOSCALE_API_SECRET="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \
  -e SKS_CLUSTERS="my-cluster:ch-gva-2" \
  -e DBAAS_SERVICES="my-postgres:ch-gva-2:pg" \
  -e CHECK_INTERVAL="60" \
  --name dbaas-filter \
  ghcr.io/exoscale-labs/dbaas-ip-filter:latest
```

Monitor logs:
```bash
docker logs -f dbaas-filter
```

### Option 2: Run in Kubernetes (preferred)

```bash
# 1. Create namespace and secret
kubectl create namespace exoscale-automation
kubectl -n exoscale-automation create secret generic exoscale-api-credentials \
  --from-literal=api-key='EXOxxxxxxxxxxxxxxxxxxxxxxxx' \
  --from-literal=api-secret='xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'

# 2. Edit deployment.yaml ConfigMap
nano deployment.yaml
# Update: sks-clusters, dbaas-services, static-ips, check-interval

# 3. Deploy
kubectl apply -k .

# 4. Monitor
kubectl logs -n exoscale-automation -l app=exo-dbaas-filter -f
```

### Option 3: Run on VM/Local Machine

**Requirements:** Python 3.11+

```bash
# 1. Install dependencies
pip3 install requests requests-exoscale-auth

# 2. Configure and run
export EXOSCALE_API_KEY="EXOxxxxxxxxxxxxxxxxxxxxxxxx"
export EXOSCALE_API_SECRET="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export SKS_CLUSTERS="my-cluster:ch-gva-2"
export DBAAS_SERVICES="my-postgres:ch-gva-2:pg"
export CHECK_INTERVAL="60"

python3 exo-dbaas-filter.py
```

**Production deployment with systemd:**

```bash
sudo tee /etc/systemd/system/exo-dbaas-filter.service <<EOF
[Unit]
Description=Exoscale DBaaS IP Filter Automation
After=network.target

[Service]
Type=simple
Environment="EXOSCALE_API_KEY=EXOxxxxxxxxxxxxxxxxxxxxxxxx"
Environment="EXOSCALE_API_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
Environment="SKS_CLUSTERS=my-cluster:ch-gva-2"
Environment="DBAAS_SERVICES=my-postgres:ch-gva-2:pg"
Environment="CHECK_INTERVAL=60"
ExecStart=/usr/bin/python3 /usr/local/bin/exo-dbaas-filter.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now exo-dbaas-filter
sudo journalctl -u exo-dbaas-filter -f
```

## Configuration

All configuration is done via environment variables:

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `EXOSCALE_API_KEY` | Yes | Exoscale API key | `EXOxxxxxxxxxxxxxxxxxxxxxxxx` |
| `EXOSCALE_API_SECRET` | Yes | Exoscale API secret | `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` |
| `SKS_CLUSTERS` | Yes | SKS clusters to monitor (comma-separated) | `prod:ch-gva-2,staging:de-fra-1` |
| `DBAAS_SERVICES` | Yes | DBaaS services to update (comma-separated) | `prod-pg:ch-gva-2:pg,prod-mysql:de-fra-1:mysql` |
| `STATIC_IPS` | No | Additional static IPs to include (comma-separated) | `203.0.113.10/32,198.51.100.0/24` |
| `CHECK_INTERVAL` | No | Check interval in seconds (default: 10) | `60` |
| `LOG_LEVEL` | No | Logging level (default: INFO) | `DEBUG` |
| `DRY_RUN` | No | Log intended changes without writing them (default: false) | `true` |
| `MAX_RETRIES` | No | Retries per API request, after the initial attempt (default: 3) | `5` |
| `REQUEST_TIMEOUT` | No | Per-request timeout in seconds (default: 30) | `60` |

`SKS_CLUSTERS` and `DBAAS_SERVICES` have no defaults. Any malformed entry, unknown
database type or invalid `STATIC_IPS` CIDR aborts startup with an explicit message,
rather than being skipped silently.

### DBaaS Service Types

Supported service types:
- `pg` - PostgreSQL
- `mysql` - MySQL
- `kafka` - Kafka
- `opensearch` - OpenSearch
- `valkey` - Valkey
- `grafana` - Grafana

### Configuration Examples

**Single cluster + single database:**
```bash
export SKS_CLUSTERS="prod-cluster:ch-gva-2"
export DBAAS_SERVICES="prod-postgres:ch-gva-2:pg"
```

**Multiple clusters + multiple databases:**
```bash
export SKS_CLUSTERS="prod-cluster:ch-gva-2,staging-cluster:de-fra-1"
export DBAAS_SERVICES="prod-postgres:ch-gva-2:pg,prod-mysql:de-fra-1:mysql,staging-kafka:at-vie-1:kafka"
```

**With static IPs (e.g., office network):**
```bash
export SKS_CLUSTERS="prod-cluster:ch-gva-2"
export DBAAS_SERVICES="prod-postgres:ch-gva-2:pg"
export STATIC_IPS="203.0.113.10/32"
```

**Kubernetes ConfigMap:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dbaas-filter-config
data:
  sks-clusters: "prod-cluster:ch-gva-2,staging-cluster:de-fra-1"
  dbaas-services: "prod-postgres:ch-gva-2:pg,prod-mysql:de-fra-1:mysql"
  static-ips: "203.0.113.10/32"
  check-interval: "60"
```

## IAM Policy Setup

This script uses direct Exoscale APIv2 calls and requires minimal permissions compared to exo CLI-based solutions.

**Required permissions:**
- **Compute**: 3 operations (list-sks-clusters, get-instance-pool, get-instance)
- **DBaaS**: Get and update operations for your database types

Create an IAM role with this policy (`dbaas-filter-policy.json`):

```json
{
  "default-service-strategy": "deny",
  "services": {
    "dbaas": {
      "type": "rules",
      "rules": [
        {
          "expression": "operation in ['get-dbaas-service-pg', 'get-dbaas-service-mysql', 'get-dbaas-service-kafka', 'get-dbaas-service-opensearch', 'get-dbaas-service-valkey', 'get-dbaas-service-grafana']",
          "action": "allow"
        },
        {
          "expression": "operation in ['update-dbaas-service-pg', 'update-dbaas-service-mysql', 'update-dbaas-service-kafka', 'update-dbaas-service-opensearch', 'update-dbaas-service-valkey', 'update-dbaas-service-grafana'] && parameters.has('ip_filter') && int(parameters.size()) == 2",
          "action": "allow"
        }
      ]
    },
    "compute": {
      "type": "rules",
      "rules": [
        {
          "expression": "operation in ['list-sks-clusters', 'get-instance-pool', 'get-instance']",
          "action": "allow"
        }
      ]
    }
  }
}
```

Create IAM role and API key:

```bash
exo iam role create dbaas-filter-role \
  --description "DBaaS IP filter automation" \
  --policy - < dbaas-filter-policy.json

exo iam api-key create dbaas-filter-key --role dbaas-filter-role
```

**Security Note:** The policy restricts DBaaS updates to IP filters only (`parameters.has('ip_filter') && int(parameters.size()) == 2`). Any attempt to modify other database parameters will be denied.

## Container Images

Pre-built multi-architecture container images are automatically published to GitHub Container Registry:

- **Latest**: `ghcr.io/exoscale-labs/dbaas-ip-filter:latest`
- **Versioned**: `ghcr.io/exoscale-labs/dbaas-ip-filter:0.1.0`
- **Architectures**: `linux/amd64`, `linux/arm64`

Images are built automatically via GitHub Actions:
- On every push to main branch (when `exo-k8s-dbaas-filter/` changes) → `latest` tag
- On git tags matching `dbaas-filter-v*` → versioned tags (e.g., `dbaas-filter-v0.1.0` → `0.1.0`)
- Can be manually triggered

**Pin a version in production.** The `latest` tag moves, so a Deployment using it
gets a different build over time, and if `imagePullPolicy` is set to `IfNotPresent`,
a node that already cached a `latest` image never pulls a newer one, keeping the
Deployment on an old build indefinitely. Either pin an immutable tag:

```yaml
image: ghcr.io/exoscale-labs/dbaas-ip-filter:0.1.0
imagePullPolicy: IfNotPresent
```

or keep `latest` together with `imagePullPolicy: Always`, as `deployment.yaml` does.

To check which build a running pod actually uses:

```bash
kubectl get pods -n exoscale-automation \
  -l app=exo-dbaas-filter -o jsonpath='{.items[*].status.containerStatuses[*].imageID}'
```

**Creating a versioned release:**
```bash
git tag dbaas-filter-v0.1.0
git push origin dbaas-filter-v0.1.0
```

## How It Works

1. **Query SKS clusters** - Retrieves all node IPs from configured SKS clusters
2. **Verify the inventory is complete** - Reconciles the addresses collected against
   the node count each nodepool reports (see below)
3. **Add static IPs** - Includes any configured static IPs
4. **Detect changes** - Compares against the filter each service currently reports
5. **Update DBaaS** - Updates IP filters for all configured DBaaS services
6. **Wait and repeat** - Sleeps for CHECK_INTERVAL seconds and repeats

The script only updates DBaaS services when IP changes are detected, to minimise API calls.

## Failsafe Behaviour

Writing a truncated IP filter cuts running workloads off from their databases, so the
script is fail-closed: **it writes a filter only when it can prove the inventory it
gathered is complete.** Leaving a stale filter in place is always safe; writing an
incomplete one is not.

A cycle is skipped, leaving the existing filter untouched, when any of the following
happens:

- an API request fails, times out, or returns a body that cannot be parsed
- a configured cluster is missing from the cluster list
- a response omits a field the script needs (`nodepools`, `instances`, `size`,
  `public-ip`)
- a returned object is not the one that was requested
- the number of addresses collected does not match the number of nodes the nodepool
  reports, either per nodepool or across the cluster
- a configured cluster name matches more than one cluster
- no node IPs are found at all, **including when `STATIC_IPS` is configured**

With a single configured cluster and no `STATIC_IPS`, any of these leaves the filter
completely untouched. Otherwise the cycle becomes add-only: verified addresses are
still applied and nothing is removed. See *With more than one cluster* below.

The last two cover the case where the API answers successfully but incompletely. A
response of `HTTP 200` with an empty instance list, an empty nodepool list, or a
nodepool reporting `size: 0` while its instance pool still lists running instances, is
not treated as "this cluster has no nodes"; it is treated as an answer that cannot be
trusted.

The check for an empty result is made on the node IPs **before** `STATIC_IPS` are
added. Merging them first is what turns an empty inventory into a plausible-looking
result and replaces the filter with the static entries alone, the failure this tool
exists to avoid. As a consequence, a cluster that genuinely has no nodes leaves the
filter unchanged rather than reducing it to the static entries.

### With more than one cluster

The IP filter is a single list built from every configured cluster, so a cluster that
cannot be inventoried cannot simply be left out, because doing so would drop its
nodes.

Instead, a cycle in which **any** cluster fails to reconcile switches to adding only:
the addresses that were verified are merged into the filter as it currently stands, and
**nothing is removed**. A node added to a healthy cluster therefore still gets database
access straight away, while the unreachable cluster's nodes stay allowed until its
inventory can be established again.

Removals are applied only on a cycle where *every* configured cluster reconciled.

One consequence worth knowing: a cluster that is permanently unreconcilable (deleted
but still listed in `SKS_CLUSTERS`, or a nodepool stuck in `error` with a `size` that no
longer matches reality) keeps the whole configuration in add-only mode indefinitely.
The repeating `ERROR` line names the cluster.

That matters beyond convenience. While add-only mode lasts, every node replacement in a
healthy cluster leaves a dead `/32` in the allowlist, and Exoscale reassigns public IPs,
so those entries may come to belong to someone else. The list also grows without bound.
**Remove an unreconcilable cluster from `SKS_CLUSTERS` promptly** rather than leaving it
to fail; the first fully reconciled cycle afterwards replaces the whole list and clears
everything that accumulated in one go.

In add-only mode the current filter must be readable: if the read fails there is no way
to compute the union, and writing the verified addresses alone would remove everything
else, so that service is skipped and the cycle reports failure.

Every skipped cycle is logged at `ERROR` with the numbers that caused it, for example:

```
ERROR     Nodepool np-1: expected 3 instance(s), instance-pool listed 2
ERROR   Incomplete inventory for cluster 'prod'
ERROR   Inventory for cluster 'prod' is incomplete; no entry will be removed this cycle
ERROR Inventory incomplete for at least one cluster. Applying verified addresses only; no entry will be removed.
WARNING Verified additions applied. Removals stay suspended until every cluster can be inventoried again.
```

A cycle like this reports failure even though its additions were applied, so a
wrapper watching the exit path still sees that the filter is not in its intended
state.

Because a failed cycle changes nothing, the next cycle simply retries.

Each cycle compares the desired list against what every service actually reports, and
writes only where they differ. No "last applied" state is kept, which matters because
the update API accepts a change and applies it asynchronously, so an `HTTP 200` is not
proof that the filter took effect. Re-reading it every cycle means a write that silently
failed, or a filter changed by someone else, is corrected on the next pass instead of
being assumed good.

Transient API errors (`429`, `500`, `502`, `503`, `504`) and connection failures are
retried automatically with exponential backoff (`MAX_RETRIES` retries after the initial
attempt) before a cycle is considered failed.

Use `DRY_RUN=true` to watch the decisions a new version would make against a real
cluster without modifying any filter. Every cycle logs what it would write, so it is
safe to leave running while observing.

### The script owns the whole IP filter

Updates **replace** the entire `ip-filter` list of each configured service. Entries
added by hand through the portal, by Terraform, or by any other tool **are removed on
the next update**. Add permanent extra entries to `STATIC_IPS` instead, so they are
included in every write.

### Scope

Only nodes belonging to SKS nodepools are discovered. Clusters using the `karpenter`
addon provision instances outside of nodepools; those nodes are not seen by this
script and will not be added to the IP filter.

## Troubleshooting

**Enable debug logging:**
```bash
export LOG_LEVEL="DEBUG"
```

**Check logs:**
- **Docker**: `docker logs -f dbaas-filter`
- **Kubernetes**: `kubectl logs -n exoscale-automation -l app=exo-dbaas-filter -f`
- **Systemd**: `sudo journalctl -u exo-dbaas-filter -f`

**Common issues:**

1. **"Cluster not found in zone"**: Verify cluster name and zone are correct
2. **"Forbidden" errors**: Check IAM policy permissions
3. **"No IPs found"**: Verify cluster has running nodes
4. **"Failed to update database"**: Verify database name, type, and zone are correct

## Multi-Account Support

Deploy multiple instances for different Exoscale accounts (or different SKS + DBaaS pairs):

- **Kubernetes**: Separate namespaces with different secrets and ConfigMaps
- **Docker**: Multiple containers with different environment variables
- **Systemd**: Multiple service files with different environment variables

Example Kubernetes multi-account setup:
```bash
# Account 1
kubectl create namespace exo-account1
kubectl -n exo-account1 create secret generic exoscale-api-credentials \
  --from-literal=api-key='EXO...' \
  --from-literal=api-secret='...'

# Account 2
kubectl create namespace exo-account2
kubectl -n exo-account2 create secret generic exoscale-api-credentials \
  --from-literal=api-key='EXO...' \
  --from-literal=api-secret='...'
```

## Development

**Build container locally:**
```bash
docker build -t dbaas-ip-filter .
```

**Run the unit tests:**
```bash
python3 -m unittest test_exo_dbaas_filter -v
```

They need no dependencies and no credentials: `requests` and `exoscale_auth` are
stubbed. Most of the suite asserts that malformed or incomplete API responses leave the
IP filter untouched; extend it whenever a new failure mode is found.

**Run against a real account:**
```bash
# Install dependencies
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Start with DRY_RUN to see what would change, without changing it
export DRY_RUN="true"
export EXOSCALE_API_KEY="EXO..."
export EXOSCALE_API_SECRET="..."
export SKS_CLUSTERS="test-cluster:ch-gva-2"
export DBAAS_SERVICES="test-db:ch-gva-2:pg"
export CHECK_INTERVAL="60"
python exo-dbaas-filter.py
```

## Cleanup

**Docker:**
```bash
docker stop dbaas-filter
docker rm dbaas-filter
```

**Kubernetes:**
```bash
kubectl delete namespace exoscale-automation
```

**Systemd:**
```bash
sudo systemctl stop exo-dbaas-filter
sudo systemctl disable exo-dbaas-filter
sudo rm /etc/systemd/system/exo-dbaas-filter.service
```

**IAM:**
```bash
exo iam api-key revoke dbaas-filter-key
exo iam role delete dbaas-filter-role
```

## License

Apache 2.0

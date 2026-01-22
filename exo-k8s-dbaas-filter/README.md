# DBaaS IP Filter Automation for SKS

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
  name: exo-dbaas-filter-config
data:
  sks-clusters: "prod-cluster:ch-gva-2,staging-cluster:de-fra-1"
  dbaas-services: "prod-postgres:ch-gva-2:pg,prod-mysql:de-fra-1:mysql"
  static-ips: "203.0.113.10/32"
  check-interval: "60"
```

## IAM Policy Setup

This script uses direct Exoscale APIv2 calls and requires minimal permissions compared to exo CLI-based solutions.

**Required permissions:**
- **Compute**: 5 operations (list-zones, list-sks-clusters, get-sks-cluster, get-instance-pool, get-instance)
- **DBaaS**: Get, list, and update operations for your database types

Create an IAM role with this policy (`dbaas-filter-policy.json`):

```json
{
  "default-service-strategy": "deny",
  "services": {
    "dbaas": {
      "type": "rules",
      "rules": [
        {
          "expression": "operation in ['list-dbaas-services', 'get-dbaas-service-pg', 'get-dbaas-service-mysql', 'get-dbaas-service-kafka', 'get-dbaas-service-opensearch', 'get-dbaas-service-valkey', 'get-dbaas-service-grafana', 'get-dbaas-settings-pg', 'get-dbaas-settings-mysql', 'get-dbaas-settings-kafka', 'get-dbaas-settings-opensearch', 'get-dbaas-settings-valkey', 'get-dbaas-settings-grafana']",
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
          "expression": "operation in ['list-zones', 'list-sks-clusters', 'get-sks-cluster', 'get-instance-pool', 'get-instance']",
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
- **Versioned**: `ghcr.io/exoscale-labs/dbaas-ip-filter:1.0.0`
- **Architectures**: `linux/amd64`, `linux/arm64`

Images are built automatically via GitHub Actions:
- On every push to main branch (when `exo-k8s-dbaas-filter/` changes) → `latest` tag
- On git tags matching `dbaas-filter-v*` → versioned tags (e.g., `dbaas-filter-v1.0.0` → `1.0.0`)
- Can be manually triggered

**Creating a versioned release:**
```bash
git tag dbaas-filter-v1.0.0
git push origin dbaas-filter-v1.0.0
```

## How It Works

1. **Query SKS clusters** - Retrieves all node IPs from configured SKS clusters
2. **Add static IPs** - Includes any configured static IPs
3. **Detect changes** - Compares with previous IP list
4. **Update DBaaS** - Updates IP filters for all configured DBaaS services
5. **Wait and repeat** - Sleeps for CHECK_INTERVAL seconds and repeats

The script only updates DBaaS services when IP changes are detected to minimize API calls.

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

**Run tests:**
```bash
# Install dependencies
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Run with test configuration
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

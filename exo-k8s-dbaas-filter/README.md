# DBaaS IP Filter Automation for SKS

Automatically maintain DBaaS IP firewall rules by monitoring SKS cluster node IPs.

**Features:**
- Supports single or multiple SKS clusters
- Supports single or multiple DBaaS services
- Can run anywhere: VM, local machine, or Kubernetes
- Works across multiple Exoscale accounts/organizations

## Quick Start

### Option 1: Run on VM/Local Machine

```bash
# 1. Configure script
nano exo-dbaas-filter.sh
# Edit SKS_CLUSTERS, DBAAS_SERVICES, and STATIC_IPS arrays

# 2. Set credentials and run
export EXOSCALE_API_KEY="EXOxxxxxxxxxxxxxxxxxxxxxxxx"
export EXOSCALE_API_SECRET="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
./exo-dbaas-filter.sh
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
ExecStart=/usr/local/bin/exo-dbaas-filter.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now exo-dbaas-filter
sudo journalctl -u exo-dbaas-filter -f
```

### Option 2: Run in Kubernetes

```bash
# 1. Create secret
kubectl create namespace exoscale-automation
kubectl -n exoscale-automation create secret generic exoscale-api-credentials \
  --from-literal=api-key='EXOxxxxxxxxxxxxxxxxxxxxxxxx' \
  --from-literal=api-secret='xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'

# 2. Edit deployment.yaml ConfigMap
nano deployment.yaml
# Update: sks-clusters, dbaas-services, static-ips

# 3. Deploy
kubectl apply -k .

# 4. Monitor
kubectl logs -n exoscale-automation -l app=exo-dbaas-filter -f
```

## Configuration Examples

**Multiple clusters + databases (bash script):**
```bash
SKS_CLUSTERS=(
  "prod-cluster:ch-gva-2"
  "staging-cluster:de-fra-1"
)

DBAAS_SERVICES=(
  "prod-postgres:ch-gva-2:pg"
  "prod-mysql:de-fra-1:mysql"
  "staging-kafka:at-vie-1:kafka"
)

STATIC_IPS=(
  "203.0.113.10/32"  # Office IP
)
```

**Kubernetes ConfigMap:**
```yaml
data:
  sks-clusters: "prod-cluster:ch-gva-2,staging-cluster:de-fra-1"
  dbaas-services: "prod-postgres:ch-gva-2:pg,prod-mysql:de-fra-1:mysql"
  static-ips: "203.0.113.10/32"
```

## IAM Policy Setup

Create an IAM role with this policy (`dbaas-filter-policy.json`):

```json
{
  "default-service-strategy": "deny",
  "services": {
    "dbaas": {
      "type": "rules",
      "rules": [
        {
          "action": "allow",
          "expression": "operation in ['list-dbaas-services', 'get-dbaas-service-pg', 'get-dbaas-service-mysql', 'get-dbaas-service-kafka', 'get-dbaas-service-opensearch', 'get-dbaas-service-valkey', 'get-dbaas-service-grafana', 'get-dbaas-settings-pg', 'get-dbaas-settings-mysql', 'get-dbaas-settings-kafka', 'get-dbaas-settings-opensearch', 'get-dbaas-settings-valkey', 'get-dbaas-settings-grafana']"
        },
        {
          "action": "allow",
          "expression": "operation in ['update-dbaas-service-pg', 'update-dbaas-service-mysql', 'update-dbaas-service-kafka', 'update-dbaas-service-opensearch', 'update-dbaas-service-valkey', 'update-dbaas-service-grafana'] && parameters.has('ip_filter') && int(parameters.size()) == 2"
        }
      ]
    },
    "compute": {
      "type": "rules",
      "rules": [
        {
          "expression": "operation in ['list-zones', 'get-operation', 'list-sks-clusters', 'get-sks-cluster', 'list-sks-cluster-nodepools', 'get-sks-nodepool', 'list-instance-pools', 'get-instance-pool', 'list-instances', 'get-instance', 'get-security-group', 'list-security-groups', 'get-instance-type', 'get-template', 'get-reverse-dns-instance']",
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
  --policy file://dbaas-filter-policy.json

exo iam api-key create dbaas-filter-key --role dbaas-filter-role
```

**Security:** The policy restricts updates to IP filters only (`int(parameters.size()) == 2`). Any attempt to modify other parameters will be denied.

## Troubleshooting

**Check logs:**
- Kubernetes: `kubectl logs -n exoscale-automation -l app=exo-dbaas-filter -f`
- Systemd: `sudo journalctl -u exo-dbaas-filter -f`

## Multi-Account Support

Deploy multiple instances for different Exoscale accounts:
- **Kubernetes**: Separate namespaces with different secrets
- **Systemd**: Multiple service files with different environment variables
- **Docker**: Multiple containers with different env files

## Cleanup

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
```

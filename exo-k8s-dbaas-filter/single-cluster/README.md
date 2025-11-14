# Single-Cluster DBaaS IP Filter (kubectl-based)

This is a simple kubectl-based deployment that runs **inside your SKS cluster** and monitors node IPs using the Kubernetes API. It checks every 10 seconds whether the IPs of the nodes in the cluster have changed and updates the DBaaS IP filter accordingly.

## ⚠️ Important Limitation

**This script only works when connecting ONE Kubernetes cluster to your DBaaS.**

If you have **multiple SKS clusters** that need access to the same databases, use the **recommended version** instead:
- See [README.md](./README.md) for the recommended exo CLI-based version
- Manages multiple clusters from a single deployment
- Uses `exo` CLI instead of `kubectl` to query any cluster
- Can run anywhere (not just inside a cluster)
- More flexible and scalable

**Managing multiple Exoscale accounts?** Both versions support deployment across multiple organizations - see [README-multi-account.md](./README-multi-account.md).

## Usage

Create an IAM API Key with minimal permissions. The policy restricts updates to only the IP filter parameter:

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
    }
  }
}
```

This policy restricts the API key to:
1. First rule: allows read operations (get/list)
2. Second rule: allows updates **only when modifying the IP filter and nothing else** (enforced by `int(parameters.size()) == 2`)

Note: `parameters.size()` equals 2 when only the IP filter is being modified (the API includes an implicit parameter). Adding any other parameter like `--plan` increases the size to 3, which gets denied. This ensures that even if someone tries to combine IP filter updates with other changes (like `--pg-ip-filter "1.2.3.4" --plan "startup-8"`), the request will be denied.


Make sure that you can access your SKS cluster with *kubectl* from your computer.

Then run the following command to create a secret with your API keys.
```bash
kubectl -n kube-system create secret generic exoscale-api-credentials \
   --from-literal=api-key='HEREYOURKEY' \
   --from-literal=api-secret='HEREYOURSECRET'
```

Then open the manifest exo-k8s-dbaas-filter.yaml. Near the bottom of the script, you can find the command beginning with `exo dbaas`. Replace the zone and the name of the database (or even add more databases) of which the ip_filter property should be automatically updated. A few lines above that you also have the option to add more static IPs.

Then apply it with:
`kubectl apply -f exo-k8s-dbaas-filter.yaml`

You can use this command, to see the output of the script:
`kubectl logs -n kube-system -l app=exo-k8s-dbaas-filter --tail 100`

## Disclaimer

This script example is provided as-is and can be modified freely. Refer to [Exoscale SKS SLA](https://community.exoscale.com/documentation/sks/overview/#service-level-and-support) to understand the limits of Exoscale Support. If you find a bug or have a suggestion/improvement to make
we welcome issues or PR in this repository but take no commitment in integrating/resolving these.

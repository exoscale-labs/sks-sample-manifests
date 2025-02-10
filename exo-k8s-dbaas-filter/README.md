# Update DBaaS ip_filter automatically when using SKS

This folder contains a deployment which checks every 10 secounds wether the IPs of the nodes in the SKS cluster differs from the previous check.
If yes, it will send a command with the current (updated) IPs list in use by the cluster to a DbaaS service.

## Usage

Create an IAM API Key. Here is an example role for Postgres:
```json
{
  "default-service-strategy": "deny",
  "services": {
    "dbaas": {
      "type": "rules",
      "rules": [
        {
          "expression": "operation in ['get-dbaas-service-pg', 'list-dbaas-services', 'get-dbaas-settings-pg', 'update-dbaas-service-pg']",
          "action": "allow"
        }
      ]
    }
  }
}
```


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

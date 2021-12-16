# Update DBaaS ip_filter automatically when using SKS

This folder contains a deployment which checks every 10 secounds wether the IPs of the nodes in the SKS cluster differs.
If yes, it will send an command with the current (updated) IPs to a DbaaS service.

## Usage

Create an IAM API Key with permissions to update a DbaaS service.
Make sure that you can access your SKS cluster with *kubectl*
Then run the following commands, which will in turn call generate-secret.sh, which uses `kubectl apply` to create a secret with your API keys.
```bash
export EXOSCALE_API_KEY=HEREYOURKEY
export EXOSCALE_API_SECRET=HEREYOURSECRET

chmod +x generate-secret.sh
./generate-secret.sh
```

Then open the manifest exo-k8s-dbaas-filter.yaml. Near the bottom of the script, you can find the command beginning with `exo dbaas`. Replace the zone and the name of the database (or even add more databases) of which the ip_filter property should be automatically updated.

Then apply it with:
`kubectl apply -f exo-k8s-dbaas-filter.yaml`

You can use this command, to see the output of the script:
`kubectl logs -n kube-system -l app=exo-k8s-dbaas-filter --tail 100`

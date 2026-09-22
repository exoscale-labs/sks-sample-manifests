# Exoscale SKS sample manifests

Example manifests and small companion tools for [Exoscale SKS](https://community.exoscale.com/documentation/sks/).
Each one addresses a specific gap you can run into when running Kubernetes on
Exoscale. They are written to be read, copied and adapted to your own setup,
not deployed unchanged.

## What to expect from this repository

**Everything here is an example, not a product.** None of it is part of the
Exoscale product offering and none of it is covered by the Exoscale SLA. See
[Service level and support](https://community.exoscale.com/documentation/sks/overview/#service-level-and-support)
for what Exoscale support does cover.

Concretely:

* The code is provided as-is and you are free to modify it. Once you deploy it,
  you own it.
* Issues and pull requests are welcome and we do read them, but we take no
  commitment to resolve or integrate them, and there is no response time
  attached.
* Interfaces, configuration and container tags can change between commits. Pin
  what you deploy (see below).
* A problem with the Exoscale platform itself is a support matter and should go
  through the [Exoscale portal](https://portal.exoscale.com/), not through this
  repository.

This is deliberately a lower bar than the platform itself. Please read the code
before you run it, and test it against your own cluster before it matters.

## Contents

| Directory | What it does | Maturity |
|---|---|---|
| [`exo-k8s-dbaas-filter`](exo-k8s-dbaas-filter/) | Keeps a DBaaS `ip-filter` in sync with the public IPs of your SKS nodes | Unit tested, validated against a live cluster and database |
| [`exegress`](exegress/) | Kubernetes controller giving SKS a stable, highly available egress source IP via a pinned Elastic IP | Proof of concept, limited real world testing, no security review |
| [`exo-kubectl`](exo-kubectl/) | Small container image bundling Helm, kubectl and the Exoscale CLI | Utility image, stable in scope |

The maturity column says how much the code has been exercised. It does not
change the support position above, which is the same for all of them.

## A note on exo-k8s-dbaas-filter

DBaaS access control is an IP allow list, and it has no awareness of Kubernetes.
SKS node addresses change whenever a nodepool scales, upgrades or replaces a
node, so there is currently no native way to express "allow my cluster" on a
managed database. Until that gap is closed in the product, keeping the allow
list in sync from outside is the approach we suggest, and this is a working
implementation of it.

That makes the tool useful, not supported. If you depend on it, treat it as part
of your own infrastructure: pin the version, watch its logs, and alert on
repeated errors.

## If you run any of this in production

* **Pin a version.** Use an immutable tag or a digest. The `latest` tag moves
  with every push to `main`, and combining it with `imagePullPolicy:
  IfNotPresent` is worse than either alone, because a node keeps whatever image
  it cached first and the deployment silently stays on an old build.
* **Read the code first.** These are short, single purpose programs, meant to be
  read in one sitting.
* **Validate before you trust it.** Where a tool offers a dry run mode, use it
  against your real environment first.
* **Watch the logs.** These tools log the decision they make on every cycle,
  including the reason when they decline to act. A repeating error is the signal
  that something needs attention.

## Contributing

Issues and pull requests are welcome, under the terms above. When reporting a
problem, include the tool, the image tag or commit you are running, your
configuration with credentials removed, and the relevant log lines.

## License

[MIT](LICENSE).

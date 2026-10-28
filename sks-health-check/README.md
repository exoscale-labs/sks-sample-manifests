# sks-health-check

A read-only script that checks a Kubernetes (Exoscale SKS) cluster for memory pressure, node outages,
noisy warnings, and common pitfalls, and writes a short summary in plain language.

> This is a sample, not a supported product. See the
> [repository README](../README.md) for what that means. The findings are hints from a snapshot of the
> cluster, not a diagnosis.

Apart from `--setup-kubeconfig`, which asks the API server for one token (see
[Read-only kubeconfig](#read-only-kubeconfig)), the script changes nothing. Every other `kubectl` call
goes through one wrapper that allows only `get`, `describe`, `top`, `logs`, `version`, `auth can-i`, and
`config current-context`. The wrapper refuses any resource name that mentions Secrets or ConfigMaps, and it
allows `--raw` only for `/metrics`. The script does not `describe` pods, so it does not read their
environment variables.

## Quick start

It needs only `bash`, `kubectl`, `awk`, `sed`, `sort`, `tar`, and common Unix tools (Linux or macOS), not
`jq`. It takes about a minute on a small cluster. It makes about 60 read calls (about 70 with Longhorn,
up to 20 more with `--with-logs`), each with a 60-second timeout.

1. Download the script, pinned to a release:

   ```bash
   curl -fsSLO https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/sks-health-check-v2.0/sks-health-check/sks-health-check.sh
   chmod +x sks-health-check.sh
   ```

2. Get read-only access. Either create a read-only kubeconfig ([Read-only kubeconfig](#read-only-kubeconfig),
   needs cluster-admin once, two commands), or, if you have the Exoscale CLI, let the script
   issue a short-lived certificate ([Using the Exoscale CLI](#using-the-exoscale-cli)).
3. Run the script:

   ```bash
   ./sks-health-check.sh -k health-check.kubeconfig
   ```

4. Read `sks-health-check-*/summary.txt`. If someone else needs to review the result, read
   [Sharing the result](#sharing-the-result) first, then send them the `.tar.gz` file.

Options:

| Option | Meaning |
| ------ | ------- |
| `-k`, `--kubeconfig FILE` | Kubeconfig to use. Default: `$KUBECONFIG` or `~/.kube/config`. |
| `-c`, `--context NAME` | Kubeconfig context. Default: the current context. |
| `-o`, `--output-dir DIR` | Where to create the result folder. Default: the current directory. |
| `--env prod\|test\|mixed` | What kind of cluster this is. See [Describe your cluster](#describe-your-cluster-to-the-script). |
| `--prod-ns REGEX`, `--test-ns REGEX` | Which namespaces are production or test. |
| `--no-prompt` | Never ask questions. |
| `--exo-cluster`, `--exo-zone`, `--exo-account`, `--exo-group`, `--exo-ttl` | Use the Exoscale CLI instead of a kubeconfig file. |
| `--print-setup`, `--print-setup-group`, `--setup-kubeconfig [FILE]`, `--token-duration D` | Create the read-only access. See [Read-only kubeconfig](#read-only-kubeconfig). |
| `--with-logs`, `--archive-logs` | Save logs of restarted containers, and put them in the archive. |
| `--no-archive` | Do not create the `.tar.gz`. |
| `-h`, `--help` | Show the help text. |

If the cluster is unreachable, the script prints the error, deletes the result folder, and exits with 1.
A missing tool or a bad option exits with 2. Ctrl+C exits with 130 and leaves an incomplete folder. A call
that fails (for example, no permission) is recorded in `meta/skipped.tsv`, and the run continues. The
result folder is readable only by you (`umask 077`).

## Using the Exoscale CLI

With the [Exoscale CLI](https://github.com/exoscale/cli) (`exo`), the script can make a short-lived client
certificate itself, use it, and delete it when it ends. Nothing is created inside the cluster per run.

```bash
./sks-health-check.sh --exo-cluster my-cluster --exo-zone ch-gva-2 --exo-account my-account
```

- The certificate carries the RBAC group `sks-health-check` (change it with `--exo-group`) and lives for
  one hour (`--exo-ttl SECONDS`, 60 to 14400). The certificate stays valid until it expires even after
  the script deletes its local copy, because it cannot be revoked. Other `system:` groups are refused.
- With `--exo-cluster` the script also reads the cluster from the Exoscale API (read-only: `compute sks
  show`, `versions`, `nodepool show`, `nodepool list`). It adds the plan, CNI, add-ons, automatic-upgrade
  setting, available versions, and nodepool sizes to the summary. Plain `kubectl` cannot see these.
- The group must be bound to the read-only roles once. See option B in
  [Read-only kubeconfig](#read-only-kubeconfig).
- `--exo-group system:masters` works too, but it is a full-admin credential. The script prints a warning.
  The script itself still only reads.

## Describe your cluster to the script

Namespace names give only a rough guess of which namespaces are production and which are test. A missing
PodDisruptionBudget (PDB) matters on production but is noise on a test cluster. You can tell the script:

```bash
./sks-health-check.sh -k health-check.kubeconfig --env mixed \
  --prod-ns '^(shop|billing)$' --test-ns '(test|dev|staging)'
```

- `--env prod` raises findings that are normally "for information" to "worth a look". `--env test` lowers
  "worth a look" findings to "for information". This applies to missing probes, single-replica workloads,
  missing PDBs, replicas that all run on one node, and namespaces without a LimitRange or ResourceQuota.
  `mixed` or no answer changes nothing.
- `--prod-ns` and `--test-ns` take extended regular expressions. A namespace label (`env` or
  `environment`) beats the name guess, the flags beat both, and answers typed at the prompt beat the
  flags. A namespace that matches both regexes becomes production.
- In a terminal without `--no-prompt`, the script asks for the cluster type whenever you did not pass
  `--env`. It asks which namespaces are production and which are test only if you passed neither
  `--prod-ns` nor `--test-ns`, the names did not reveal both kinds, and at least three namespaces
  (excluding `kube-system`, `kube-public`, and `kube-node-lease`) use 50 MiB or more live memory or
  request 128 MiB or more. It lists up to 12 namespaces by live memory. Press Enter to skip any question.
  The script never asks when it does not run in a terminal.
- The answers are saved in `meta/answers.txt`, and the summary marks them (a header line, and `*` after
  a namespace class), so readers know the rating rests on your answers.

## Reading the summary

`summary.txt` starts with an OOM risk block, followed by findings in plain language, tables of memory per
node and per namespace, the biggest memory users, and what could not be read. OOM means out of memory.

### OOM risk at a glance

Two risks are rated separately as LOW, MODERATE, HIGH, or VERY HIGH (or UNKNOWN when the data could not
be read), each with a one-sentence reason. A question mark (`LOW?`) means "nothing found, but live memory
was not measured". This is a qualitative estimate from the evidence, not a prediction.

- **Pod-level OOM:** a container hits its own memory limit and restarts.
  VERY HIGH if any container was OOM-killed in the last 24 hours. HIGH if a pod uses 95% or more of its
  limit. MODERATE if there were OOM kills earlier.
- **Node-level OOM:** a whole node runs out of memory, and kubelet or containerd can crash.
  VERY HIGH if there is memory pressure, a node OOM or insufficient-memory event, pods evicted within the last
  hour, or no worker nodes. HIGH if any node has live memory of 85% or more, requests of 90% or more,
  or limits of 200% or more together with requests of 80% or more (or live memory of 70% or more).
  MODERATE if a node has limits above 150%, requests of 80% or more, live memory of 70% or more, or
  non-system pods without memory limits that use 10% or more of the node.

`nodes/node-risk.txt` lists the figures and the reason for each node.

### What the summary flags

Memory and OOM findings come first, in their own sections. Everything else follows. Components in
`kube-system` are managed by SKS, so missing requests or limits there are only a note, not a finding.
Over-commit alone (limits above 150% on a node that is mostly empty) is a note too; it counts as a risk
once requests or live use reach 40%.

| Area | Findings |
| ---- | -------- |
| Nodes | Not Ready, Memory, Disk, or PID pressure, cordoned, problem taints, restarted (Ready again long after creation), CPU requests of 90% or more, no live metrics, little memory reserved for the system, kubelet version skew, no worker nodes |
| Memory and OOM | OOM-killed containers per namespace (and how many in the last 24 hours), pods using much more than they requested, pods at 95% of their limit, containers without a memory request or limit, BestEffort pods, DaemonSet pods without requests, memory-backed `emptyDir` volumes, CPU limits |
| Prod versus test | Share of requested and live memory per environment, and how many prod pods are not Guaranteed QoS (request equals limit) |
| Eviction order | No PriorityClass in use, evicted pods |
| Events | SystemOOM, OOMKilling, eviction, NodeNotReady, NodeHasInsufficientMemory, Rebooted, kubelet restarts, failed scheduling, BackOff, image-pull failures, volume failures, disk-cleanup failures, failed probes, the noisiest workload |
| Pitfalls | `:latest` images, missing probes, privileged or host-network pods, `hostPath` volumes, bare pods, single-replica workloads, replicas on one node, PDBs that allow zero disruptions, HPAs (HorizontalPodAutoscalers) that cannot compute their metric, Services without endpoints, finished Jobs without TTL, failed Jobs, old ReplicaSets, deprecated APIs in use, namespaces without LimitRange or ResourceQuota, unbound PVCs (PersistentVolumeClaims), Released or Failed PVs |
| SKS platform | Metrics API missing (note: SKS normally has metrics-server), no CSI driver (note: normally enabled), only one worker node, nodes the cloud controller has not initialised, certificate requests pending for over 10 minutes, managed components not healthy (CoreDNS, konnectivity-agent, metrics-server, CNI, kube-proxy), CoreDNS or konnectivity replicas on one node, Cluster Autoscaler version not matching the cluster, Karpenter (NodeClaims, NodePools, NodeClasses), LoadBalancer Services without an address or with several nodepools, ReadWriteMany on block storage, pods stuck Terminating, kubelet admission failures, registry rate limiting, blocked-egress fingerprint, pods near the node's pod limit, GPU and user-namespace version limits |
| Exoscale API (`--exo-cluster`) | Plan, CNI, add-ons, automatic upgrade off, cluster state, Kubernetes version no longer offered or behind the newest, nodepool size versus existing nodes, small disks |
| Longhorn | Degraded, faulted, or unknown-health volumes, nodes that are not Ready or schedulable, replicas not running, memory used by Longhorn pods, number of share managers (one per RWX, ReadWriteMany, volume) |

The probe, privileged, host-namespace, and `hostPath` checks ignore `kube-system`. The single-replica check
also ignores DaemonSets and Jobs. The replicas-on-one-node check runs only with two or more nodes. The
deprecated-API check reads the API server's `/metrics` endpoint, which needs the extra role below.

You can change these thresholds with environment variables, for example `HC_MEM_REQ_HIGH=85`:

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `HC_MEM_REQ_HIGH`, `HC_MEM_REQ_MED` | 90, 80 | Node memory requests, percent of allocatable |
| `HC_MEM_LIMIT_MED`, `HC_MEM_LIMIT_HIGH` | 150, 200 | Node memory limits (over-commit), percent |
| `HC_MEM_LIVE_HIGH`, `HC_MEM_LIVE_MED` | 85, 70 | Live node memory use, percent |
| `HC_RESTARTS_MED` | 5 | Container restarts worth mentioning |
| `HC_OOM_HIGH` | 10 | OOM-killed containers in one namespace that make the finding "needs attention" |

Other limits (for example 95% of a pod's limit, or a limit more than 4 times the request) are fixed in
the script.

### Limits to keep in mind

- Kubernetes keeps events for only about 1 hour and remembers only the last termination of each container.
  OOMKilled counts are a minimum, and event counts are a snapshot. Run the script right after an incident,
  or run it several times.
- `kubectl top` shows only the usage at the time of the run.
- CPU throttling and kubelet or containerd logs are not visible through `kubectl`. If a node disappeared,
  collect `journalctl -u kubelet -u containerd` and `dmesg | grep -i oom` from that node.
- The prod and test split is a guess unless you stated it. Check `pods/namespace-memory.txt`.

## What it collects

All files go into one folder, `sks-health-check-<context>-<date>-<time>-<pid>/`, plus a `.tar.gz` of it.
Empty folders are removed.

| Path | Content |
| ---- | ------- |
| `summary.txt` | The summary described above |
| `nodes/` | `nodes-conditions.txt`, `node-resources.txt`, `node-risk.txt`, `describe-nodes.txt`, `node-conditions-detail.txt`, `top-nodes.txt` |
| `pods/` | Restarts and termination reasons, OOMKilled per namespace, containers without requests or limits, QoS and PriorityClass, `pod-memory.txt` and `pod-memory-flags.txt` (usage compared to request and limit), `namespace-memory.txt`, `workload-placement.txt`, `not-running.txt`, `bare-pods.txt`, special volumes |
| `events/` | Events counted by type, reason, and kind; top Warning messages; warnings per namespace and per workload; `time-range.txt` |
| `storage/` | PVs and PVCs by storage class and status, StorageClasses, VolumeAttachments |
| `longhorn/` | Only if namespace `longhorn-system` exists: pods, memory use, volumes, nodes, replicas, share managers, settings |
| `cluster/` | Kubernetes version, namespaces, ResourceQuotas, LimitRanges, PDBs, PriorityClasses, workloads, HPAs, Jobs, Services and endpoints, `deprecated-apis.txt` |
| `meta/` | `permissions.txt` (what the kubeconfig may read), `skipped.tsv` (what failed and why), `findings.tsv`, `oom-risk.txt`, `answers.txt`, `ns-class.tsv`, `run-info.txt`, `kubectl-version.txt` |

## Read-only kubeconfig

The built-in `view` ClusterRole is read-only and has no access to Secrets. It does not include nodes, node
metrics (`kubectl top`), PersistentVolumes, StorageClasses, PriorityClasses, the API server's `/metrics`,
or the Longhorn resources. Without these permissions the script still runs, but those parts of the summary
are empty and say so. The script can print everything needed: the `view` binding plus a small extra role
that allows only `get` and `list` (nodes, PersistentVolumes, StorageClasses, CSI drivers, VolumeAttachments,
PriorityClasses, certificate signing requests, the metrics API, Longhorn and Karpenter resources, and the
API server's `/metrics`).

Note that `view` still lets you read all pod logs and ConfigMaps in every namespace, and all object
metadata. Treat the credential like a password.

**Option A: ServiceAccount with a short-lived token (works for any customer).** Run these three commands
once, as cluster-admin:

```bash
./sks-health-check.sh --print-setup | kubectl apply -f -       # role, ServiceAccount, bindings
./sks-health-check.sh --setup-kubeconfig                       # writes health-check.kubeconfig (token valid 24 h)
./sks-health-check.sh -k health-check.kubeconfig               # the health check itself
```

- Read the YAML first with `./sks-health-check.sh --print-setup`. It creates the ClusterRole
  `sks-health-check-extra`, the ServiceAccount `health-check` in `kube-system`, and two
  ClusterRoleBindings (`view` and the extra role). All objects carry the label
  `app.kubernetes.io/managed-by: sks-health-check`.
- `--setup-kubeconfig [FILE]` uses your current admin kubeconfig (or the one you pass with `-k` or `-c`).
  It is the only part of the script that is not read-only: it asks the API server for a short-lived token for
  the `health-check` ServiceAccount. Use `--token-duration 2h` for a different lifetime. It refuses to
  overwrite an existing file, refuses to mint a token if the ServiceAccount lacks that label or is allowed
  to create pods, read Secrets, or delete nodes, and checks that the new kubeconfig works. The token never
  appears on a command line. The API server may shorten the requested lifetime.
- To check that the credential cannot write, run `kubectl auth can-i create pods`,
  `kubectl auth can-i get secrets`, and `kubectl auth can-i delete nodes` with
  `KUBECONFIG=health-check.kubeconfig`. Each answer must be `no`.

**Option B: group for the Exoscale CLI (for engineers who use `exo`).** Bind the group that `--exo-group`
puts into the certificate (default `sks-health-check`) once:

```bash
./sks-health-check.sh --print-setup-group | kubectl apply -f -
```

Then run the health check with `--exo-cluster` (see [Using the Exoscale CLI](#using-the-exoscale-cli)).
To check the group, add `--as=x --as-group=sks-health-check` to the `kubectl auth can-i` commands.

**Clean up afterward** (the same YAML, deleted):

```bash
./sks-health-check.sh --print-setup | kubectl delete -f -        # or --print-setup-group for option B
rm -f health-check.kubeconfig
```

## Sharing the result

The `.tar.gz` contains node and pod IPs, node, namespace, and workload names, container image names,
labels, and event text. It contains no Secrets and no environment variables. Look through `summary.txt`
before you send it.

`--with-logs` saves the last 50 log lines (from the previous container instance if there is one, otherwise from the current one) of the 10
containers with the most restarts, for containers with 3 or more restarts, in
`pods/logs/<namespace>__<pod>__<container>.log`. Logs can contain tokens, connection strings, and personal
data, so `--with-logs` is off by default. Even with `--with-logs`, the logs stay out of the `.tar.gz`
unless you also pass `--archive-logs`.

## Tested

Tested on disposable SKS clusters (starter plan, 2 × standard.medium, Kubernetes 1.37.1, Exoscale CSI):
with a ServiceAccount token created by `--setup-kubeconfig` and bound to `view` alone (the script runs and lists the missing data under "Not
checked"), with `view` plus the extra role, and with an `exo`-issued certificate for the read-only group.
Also run, with read-only calls, against five real SKS clusters, including one with no nodes and one with
five nodes and about 190 containers.

Not tested: a real Longhorn install, a node that is really NotReady or under memory pressure, and macOS
with bash 3.2 beyond running the script (it avoids bash 4 features).

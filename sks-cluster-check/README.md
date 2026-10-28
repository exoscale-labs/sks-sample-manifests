# sks-cluster-check

A read-only script that checks an Exoscale SKS (Kubernetes) cluster for memory pressure, node outages,
noisy warnings and common pitfalls, and writes a short summary in plain language.

> This is a sample, not a supported product. See the
> [repository README](../README.md) for what that means. The findings are hints from a snapshot of the
> cluster, not a diagnosis.

The script only reads. Every `kubectl` call goes through one wrapper that allows only `get`, `describe`,
`top`, `logs`, `version`, `auth can-i` and `config current-context`, and refuses anything that mentions
Secrets or ConfigMaps. The one exception is `--setup-kubeconfig`, which asks the API server for a token
(see [Read-only access](#read-only-access)).

## Quick start

It needs `bash`, `kubectl` and common Unix tools (Linux or macOS), and takes about a minute on a small
cluster.

1. Download the script:

   ```bash
   curl -fsSLO https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/main/sks-cluster-check/sks-health-check.sh
   chmod +x sks-health-check.sh
   ```

2. Set up [read-only access](#read-only-access) once.
3. Run it:

   ```bash
   ./sks-health-check.sh -k health-check.kubeconfig
   ```

4. Read `sks-health-check-*/summary.txt`. Before you send the `.tar.gz` to someone, read
   [Sharing the result](#sharing-the-result).

Main options (`--help` lists all):

| Option | Meaning |
| ------ | ------- |
| `-k FILE`, `-c NAME` | Kubeconfig and context. Default: the current one. |
| `--env prod\|test\|mixed` | What kind of cluster this is. `prod` raises resilience findings, `test` lowers them. |
| `--prod-ns REGEX`, `--test-ns REGEX` | Which namespaces are production or test. Otherwise the script guesses from names and labels, and asks in a terminal. |
| `--exo-cluster NAME --exo-zone ZONE` | Use the [Exoscale CLI](#with-the-exoscale-cli) instead of a kubeconfig. |
| `--with-logs` | Also save the last log lines of often restarted containers (kept out of the archive unless `--archive-logs`). |
| `--no-prompt`, `--no-archive` | Never ask questions; do not create the `.tar.gz`. |

## Read-only access

The built-in `view` role cannot read nodes, node metrics, PersistentVolumes or PriorityClasses, so the
script brings a small extra role that only allows `get` and `list` on those. Without it the script still
runs, but those parts of the summary stay empty. Run these once as cluster-admin:

```bash
./sks-health-check.sh --print-setup | kubectl apply -f -   # extra role, ServiceAccount, bindings
./sks-health-check.sh --setup-kubeconfig                   # writes health-check.kubeconfig, token valid 24 h
```

Read the YAML first with `--print-setup`. `--setup-kubeconfig` refuses to create a token if the
ServiceAccount could create pods, read Secrets or delete nodes. `view` can still read pod logs and object
metadata, so treat the kubeconfig like a password.

Clean up afterwards:

```bash
./sks-health-check.sh --print-setup | kubectl delete -f -
rm -f health-check.kubeconfig
```

### With the Exoscale CLI

If you use `exo`, bind the read-only roles to a group once, then let the script create a one-hour client
certificate per run:

```bash
./sks-health-check.sh --print-setup-group | kubectl apply -f -
./sks-health-check.sh --exo-cluster my-cluster --exo-zone ch-gva-2
```

The certificate cannot be revoked, so it stays valid until it expires (`--exo-ttl`, default 3600 seconds).
With `--exo-cluster` the summary also covers the plan, add-ons, Kubernetes version and nodepool sizes from
the Exoscale API.

## Reading the summary

`summary.txt` starts with two ratings, from LOW to VERY HIGH, each with its reason:

- **Pod-level OOM:** a container hits its memory limit and restarts. Recent OOM kills or pods close to
  their limit raise it.
- **Node-level OOM:** a whole node runs out of memory, which can take down kubelet or containerd and make
  the node go `NotReady`. Memory pressure, evictions, nodes with high requests or live use, and pods
  without memory limits raise it.

`LOW?` means nothing was found but live memory could not be measured. The findings that follow cover
memory per node and namespace, prod versus test, eviction order, events, SKS components, and common
pitfalls such as `:latest` images, missing probes, single-replica workloads and deprecated APIs.
Components that SKS manages in `kube-system` only get notes. Thresholds can be changed with `HC_*`
environment variables (see `--help`).

Keep in mind:

- Kubernetes keeps events for about an hour and only the last termination per container, so run the
  script soon after an incident, or several times.
- `kubectl top` is a snapshot of the moment.
- Kubelet and kernel logs are not visible through `kubectl`. If a node disappeared, collect
  `journalctl -u kubelet -u containerd` and `dmesg | grep -i oom` from that node.

## Sharing the result

The result folder and its `.tar.gz` contain node and pod IPs, names of nodes, namespaces and workloads,
image names, labels and event texts, but no Secrets and no environment variables. Look through
`summary.txt` before you send it. Logs, which can contain tokens or personal data, are only collected with
`--with-logs` and only archived with `--archive-logs`.

## Tested

Tested on disposable SKS clusters with `view` alone, with `view` plus the extra role, and with an
`exo`-issued certificate, and run read-only against several real SKS clusters, up to five nodes and about
190 containers. Not tested on a node that is really `NotReady` or under memory pressure.

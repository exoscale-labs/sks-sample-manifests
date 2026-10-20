# nfs-rwx

ReadWriteMany (RWX) volumes on SKS with one command. A single NFS server pod
stores its data on an Exoscale block storage volume and hands out shared
volumes through a `StorageClass` named `nfs`.

Everything runs inside your cluster as ordinary pods. There is no extra VM to
manage and nothing to install on the nodes.

> This is a sample, not a supported product. See the
> [repository README](../README.md) for what that means. It was validated on a
> live SKS cluster (results below), but you own it once you deploy it.

## Install

You need an SKS cluster with the Exoscale CSI add-on (the `exoscale-sbs`
storage class exists; for a new cluster pass `--exoscale-csi` to
`exo compute sks create`) and `kubectl`.

```bash
kubectl apply -f https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.0/nfs-rwx/install.yaml
```

That creates the `nfs` namespace, the NFS server with a 100 GiB block volume,
the `nfs` storage class, and the [node fencer](#node-crash). All RWX volumes
share that one block volume, so to start bigger, change the size on the way in:

```bash
curl -sL https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.0/nfs-rwx/install.yaml \
  | sed 's/storage: 100Gi/storage: 500Gi/' | kubectl apply -f -
```

Check that it is running:

```bash
kubectl -n nfs get pods
```

Then request a volume like any other:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs
  resources:
    requests:
      storage: 10Gi
```

<details>
<summary>Installing with Helm instead</summary>

[`install.yaml`](install.yaml) is the upstream
[nfs-ganesha-server-and-external-provisioner](https://github.com/kubernetes-sigs/nfs-ganesha-server-and-external-provisioner)
Helm chart rendered with [`values.yaml`](values.yaml), plus
[`node-fencer.yaml`](node-fencer.yaml). To manage it with Helm:

```bash
helm install nfs nfs-server-provisioner \
  --repo https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/ \
  --version 1.8.0 --namespace nfs --create-namespace \
  -f https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.0/nfs-rwx/values.yaml \
  --set persistence.size=100Gi
kubectl apply -f https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.0/nfs-rwx/node-fencer.yaml
```

</details>

## Try it

[`examples/rwx-smoke-test.yaml`](examples/rwx-smoke-test.yaml) creates one RWX
claim and three pods, one per node, that each append to their own file and list
the others:

```bash
kubectl apply -f https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.0/nfs-rwx/examples/rwx-smoke-test.yaml
kubectl rollout status deploy/rwx-smoke-test
kubectl logs deploy/rwx-smoke-test --tail=5
```

Within a minute every pod lists all three files (NFS clients cache directory
listings for up to a minute; a file opened by name is always current). Remove
it with `kubectl delete deploy/rwx-smoke-test pvc/shared`.

## How it works

Exoscale block storage volumes attach to one node at a time, so the
`exoscale-sbs` storage class only offers `ReadWriteOnce`. This sample puts one
NFS server in front of such a volume:

```
  pod A (node 1)    pod B (node 2)    pod C (node 3)
        \                |                 /
         \               |                /     NFSv4.1 mounts,
          \              |               /      done by each node's kubelet
           v             v              v
        +----------------------------------+
        |  Service  nfs-nfs-server-provisioner (ClusterIP)
        +----------------+-----------------+
                         |
        +----------------v-----------------+
        |  StatefulSet, 1 replica          |
        |    NFS-Ganesha 14.1              |
        |    + provisioner: one directory  |
        |      per RWX PersistentVolume    |
        +----------------+-----------------+
                         |  ReadWriteOnce
        +----------------v-----------------+
        |  Exoscale block storage volume   |
        |  (exoscale-sbs)                  |
        +----------------------------------+
```

Longhorn's RWX volumes are served the same way, by one NFS-Ganesha pod per
volume. Longhorn additionally runs a whole distributed block storage system on
your nodes' disks underneath. On SKS the block storage is already replicated
by Exoscale, so this sample leaves that layer out.

## What to expect

These numbers come from a 3 node SKS cluster (Kubernetes 1.37, Ubuntu 26.04
nodes, kernel 7.0, `standard.medium`) in `ch-gva-2`, October 2026.

| Event | What clients see | Measured |
|---|---|---|
| Normal operation | Shared reads and writes from every node, POSIX locks honoured across nodes | ~150 MB/s sequential write from one pod |
| NFS server pod restarts | I/O pauses, then continues. No errors, locks kept | ~100 s pause |
| Node drain (upgrade, nodepool cycle) | Same, plus the volume moves to another node | ~20 s move + ~100 s pause |
| Node with the NFS server crashes | Same, after the node fencer has moved the server | ~4 min pause, no action needed |
| Growing the volume | Server stops while the disk is resized | ~30 s down + ~100 s pause |

The pause after every server start is the NFSv4 **grace period** (90 s). During
it the server lets clients reclaim the locks they held, so another client
cannot grab them in between. Applications are not told about it: their reads
and writes just wait, because volumes are mounted `hard`.

This is a **single server, not a highly available one**. It fits workloads
that can tolerate a few minutes of paused I/O when something happens to the
server's node.

## Using it with DuckDB

DuckDB allows **one** process to open a database file read-write, **or** any
number of processes to open it read-only, never both at once. It enforces that
with file locks, and those locks work across nodes on this storage. We tested:

| Pattern | Result |
|---|---|
| One writer pod holds `db.duckdb`. A second pod on any node opens it, read-write or read-only | Refused: `Could not set lock on file ... Conflicting lock is held` |
| NFS server restarted, or its node crashed, while the writer holds the file | Writer pauses, keeps its lock, continues. Others still refused |
| No writer. Several read-only pods on different nodes open `db.duckdb` | All succeed |
| Several writer pods each write their own Parquet files into one directory, readers query `read_parquet('/data/lake/*.parquet')` | Works, every pod sees every file |

RWX does not turn DuckDB into a multi-writer database. If several pods need to
write, give each its own file (Parquet, or one `.duckdb` per writer) and read
them together with a glob. For a single writer, run it as one replica with
`strategy: Recreate`, so an update never starts a second writer while the
first still holds the lock.

If the data does not need to be a filesystem at all, DuckDB can read and write
Parquet on Exoscale SOS directly through its `httpfs` extension, with no RWX
volume involved.

## Operations

### Server restart and node drain

Nothing to do. Clients pause and resume by themselves. Draining the server's
node moves the pod and its volume to another node.

### Node crash

Nothing to do either, as long as the node fencer runs (it is part of
`install.yaml`).

Kubernetes on its own never restarts the NFS server elsewhere while its node is
unreachable, because the old server might still be running and writing. The
way to tell Kubernetes it is not is the
[`node.kubernetes.io/out-of-service`](https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/#non-graceful-node-shutdown)
taint. The node fencer ([`image/node-fencer.sh`](image/node-fencer.sh), two
pods in the `nfs` namespace) applies it when all of this holds:

* the Exoscale cloud controller manager has marked the node
  `node.cloudprovider.kubernetes.io/shutdown`, which it only does when the
  Exoscale API reports the VM as stopping or stopped,
* the node is `NotReady`,
* both have been true for 60 seconds.

Kubernetes then deletes the pods on that node, detaches their volumes and
starts them elsewhere. When the node is `Ready` again, the fencer removes the
taint. It only ever removes taints it applied itself.

What we measured when the server's node was powered off:

| After | |
|---|---|
| 50 s | Node `NotReady`, Exoscale reports the VM stopped |
| 115 s | Fencer applies the taint |
| 150 s | NFS server running on another node |
| 250 s | Clients resume after the grace period; the DuckDB writer kept its lock |

A node whose VM is still running, for example with a stopped kubelet or a
network problem, is **not** fenced: the VM is not reported as stopped, so the
fencer leaves it alone. We tested that too. If such a node hosts the NFS
server and it really is broken, stop its VM (`exo compute instance stop`) and
the fencer takes over.

The taint applies to the whole node, so every stateful pod on it benefits, not
only the NFS server. If you do not want that, delete the
`nfs/node-fencer` deployment and apply the taint by hand when needed:

```bash
kubectl taint node <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
# once the node is back or deleted:
kubectl taint node <node> node.kubernetes.io/out-of-service-
```

### Growing the volume

The Exoscale CSI driver can only resize a volume while it is detached, so the
NFS server has to stop briefly. Clients pause and continue afterwards; they get
no errors. In our test the server was down for about 30 seconds, followed by
the usual ~100 s grace period.

The order matters: stop the server first, then request the new size. Asking
for the size while the server still runs works too, but in our tests it took
5 to 10 minutes to settle because of retries.

1. Check the current size and usage:

   ```bash
   kubectl -n nfs exec nfs-nfs-server-provisioner-0 -- df -h /export
   ```

2. Stop the NFS server and wait until its volume is detached (about 15 s).
   The outage starts here:

   ```bash
   kubectl -n nfs scale statefulset nfs-nfs-server-provisioner --replicas=0
   PV=$(kubectl -n nfs get pvc data-nfs-nfs-server-provisioner-0 -o jsonpath='{.spec.volumeName}')
   while kubectl get volumeattachments -o jsonpath='{.items[*].spec.source.persistentVolumeName}' | grep -q "$PV"; do sleep 5; done
   ```

3. Request the new size (volumes can only grow) and wait until the volume
   itself reports it, usually within seconds:

   ```bash
   SIZE=200Gi
   kubectl -n nfs patch pvc data-nfs-nfs-server-provisioner-0 \
     -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$SIZE\"}}}}"
   until [ "$(kubectl get pv "$PV" -o jsonpath='{.spec.capacity.storage}')" = "$SIZE" ]; do sleep 5; done
   ```

   Wait on the **PersistentVolume**, as above, and do not start the server
   before it shows the new size: once the volume is attached again, the resize
   cannot happen. The claim keeps showing the old size and a `Resizing`
   condition until the server mounts the volume again.

4. Start the server. The filesystem grows when the volume is mounted:

   ```bash
   kubectl -n nfs scale statefulset nfs-nfs-server-provisioner --replicas=1
   kubectl -n nfs rollout status statefulset nfs-nfs-server-provisioner
   kubectl -n nfs exec nfs-nfs-server-provisioner-0 -- df -h /export
   ```

Do not change the size in `install.yaml` or in your Helm values instead.
Kubernetes does not allow that part of a StatefulSet to change, so a later
`kubectl apply` or `helm upgrade` with a different size fails with
`spec.volumeClaimTemplates: Invalid value`. Keep the size you installed with
there; the claim is what counts.

### Capacity

Each RWX volume is a directory on the shared block volume. The size in a claim
is **not enforced**: any volume can fill the whole disk, and `df` inside a pod
shows the size of the shared disk. Watch the free space of the server's volume
and [grow it](#growing-the-volume) in time:

```bash
kubectl -n nfs exec nfs-nfs-server-provisioner-0 -- df -h /export
```

### Logs

```bash
kubectl -n nfs exec nfs-nfs-server-provisioner-0 -- tail -50 /export/ganesha.log
kubectl -n nfs logs deploy/node-fencer
```

## Why a custom image

The chart's default image (`registry.k8s.io/sig-storage/nfs-provisioner:v4.0.8`)
was last published in 2023. It runs NFS-Ganesha 4.0.8 on Fedora 36, which has
been end of life since 2023. We found four problems running it on SKS; the
first two show up immediately, the last two only when the server restarts or
moves while applications hold file locks:

* **"Remote I/O error" on directory listings.** Linux 6.19 and later, which
  includes SKS nodes, asks for NFSv4 directory delegations. Ganesha before 9.13
  rejects the whole request instead of declining the delegation
  ([nfs-ganesha#1385](https://github.com/nfs-ganesha/nfs-ganesha/issues/1385)),
  and the client reports `EREMOTEIO`. In our tests, every new pod's first `ls`
  after creating a file failed this way.
* **Files owned by `nobody`.** NFSv4 sends owners as `user@domain` names by
  default. SKS nodes do not run the ID mapping service, so every file shows up
  as uid 65534. The image sets `Only_Numeric_Owners` so clients see real uids
  and gids.
* **Locks lost when the server moves.** For lock recovery, Ganesha records
  each client by its ID *and the IP address it connects from*. On Kubernetes
  that address changes with the server's placement: a node is seen by its
  tunnel address while the server runs elsewhere, and by its own address while
  the server runs on it. Each time the server moved, clients on the node it
  left and on the node it landed on could not reclaim their locks and got I/O
  errors on locked files; our DuckDB writer crashed with `fsync failed!`.
  Ganesha 11 added `RecoverySkipIp` to identify clients by ID alone, which the
  image sets.
* **Locks lost on a second restart during the grace period**, as happens when
  a node upgrade moves the server twice in a row. The default recovery backend
  replaces its client list at every start and forgets clients that had not
  reclaimed yet. The image sets `RecoveryBackend = fs_ng`, which replaces the
  list only once grace has ended.

[`image/Dockerfile`](image/Dockerfile) builds the upstream provisioner from a
pinned commit and installs Ganesha 14.1 from Fedora 45, the first Fedora
release with Ganesha 11 or later (Debian and Ubuntu ship 6.5).
[`image/entrypoint.sh`](image/entrypoint.sh) adds the three settings to the
Ganesha config, and the recovery records are kept on the data volume so they
survive a restart. The same image runs the node fencer. CI publishes it as
`ghcr.io/exoscale-labs/nfs-rwx`.

If you already run the upstream chart with its default image, switching to
this one keeps your data: change the image in your values and `helm upgrade`.
The entrypoint adds the settings to the existing Ganesha config on first
start. Because that changes how clients are recorded, applications holding
file locks during that one restart lose them once.

## Uninstall

Delete the workloads and RWX claims first, so the provisioner removes their
directories. Then remove everything. This deletes the `nfs` namespace and with
it the block volume, **including all data on it**:

```bash
kubectl delete -f https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.0/nfs-rwx/install.yaml
```

With Helm: `helm -n nfs uninstall nfs`, `kubectl delete -f` the
`node-fencer.yaml` URL, then
`kubectl -n nfs delete pvc data-nfs-nfs-server-provisioner-0` (Helm leaves the
volume in place).

## Files

| File | |
|---|---|
| [`install.yaml`](install.yaml) | Everything, ready for `kubectl apply`. Generated, do not edit |
| [`values.yaml`](values.yaml) | Helm values the install is rendered from |
| [`node-fencer.yaml`](node-fencer.yaml) | Node fencer deployment and its RBAC |
| [`image/`](image/) | Server and node fencer image |
| [`hack/render.sh`](hack/render.sh) | Regenerates `install.yaml` after changing the two files above |
| [`examples/rwx-smoke-test.yaml`](examples/rwx-smoke-test.yaml) | Three pods sharing one volume |

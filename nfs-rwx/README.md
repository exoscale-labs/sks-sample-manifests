# nfs-rwx

ReadWriteMany (RWX) volumes on SKS with one command. A single NFS server pod
stores its data on an Exoscale block storage volume and hands out shared
volumes through a `StorageClass` named `nfs`.

Everything runs inside your cluster as ordinary pods. There is no extra VM to
manage and nothing to install on the nodes.

It is a **single NFS server, not a highly available one**: when its node is
drained, restarted or fails, I/O on the volumes pauses for about 2 to 5
minutes and then continues by itself. Every pod in the cluster can reach the
server, so use it only on clusters where you trust all workloads (see
[Security](#security)).

> This is a sample, not a supported product. See the
> [repository README](../README.md) for what that means. It was validated on a
> live SKS cluster (results below), but you own it once you deploy it.

## Install

You need `kubectl` and an SKS cluster with the Exoscale CSI add-on, that is,
the `exoscale-sbs` storage class exists. To create a new cluster with the
add-on, pass `--exoscale-csi` to `exo compute sks create`.

```bash
kubectl apply -f https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.2/nfs-rwx/install.yaml
```

That creates the `nfs` namespace, the NFS server with a 100 GiB block volume,
the `nfs` storage class, and the [node fencer](#node-crash). All RWX volumes
share that one block volume. To start with a larger one, change the size at
install time:

```bash
curl -sL https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.2/nfs-rwx/install.yaml \
  | sed 's/storage: 100Gi/storage: 500Gi/' | kubectl apply -f -
```

After about a minute, three pods are running:

```bash
kubectl -n nfs get pods
```

```
NAME                           READY   STATUS    RESTARTS   AGE
nfs-nfs-server-provisioner-0   1/1     Running   0          41s
node-fencer-6b56c69b79-8xrnd   1/1     Running   0          41s
node-fencer-6b56c69b79-kk6qt   1/1     Running   0          41s
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
  -f https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.2/nfs-rwx/values.yaml \
  --set persistence.size=100Gi
kubectl apply -f https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.2/nfs-rwx/node-fencer.yaml
```

</details>

## Try it

[`examples/rwx-smoke-test.yaml`](examples/rwx-smoke-test.yaml) creates an RWX
claim and three pods, spread over the nodes, that each append to their own
file and list the others:

```bash
kubectl apply -f https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.2/nfs-rwx/examples/rwx-smoke-test.yaml
kubectl rollout status deploy/rwx-smoke-test
kubectl logs deploy/rwx-smoke-test --tail=5
```

Within a minute every pod lists all three files (NFS clients cache directory
listings for up to a minute; a file opened by name is always current). Remove
the test with the same URL and `kubectl delete -f`.

## What to expect

These numbers come from a 3-node SKS cluster (Kubernetes 1.37, Ubuntu 26.04
nodes, kernel 7.0, `standard.medium`) in `ch-gva-2`, October 2026.

| Event | What clients see | Measured |
|---|---|---|
| Normal operation | Shared reads and writes from every node, POSIX locks honored across nodes | ~150 MB/s sequential write from one pod |
| NFS server pod restarts | I/O pauses, then continues. No errors, locks kept | ~100 s pause |
| Node drain (upgrade, nodepool cycle) | As above, after the volume moves to another node | ~20 s move + ~100 s pause |
| The node running the NFS server crashes | As above, after the [node fencer](#node-crash) moves the server | ~4 to 5 min pause, no action needed |
| Growing the volume | The server stops while the disk is resized | ~30 s down + ~100 s pause |

Most of the pause after every server start is the NFSv4 **grace period**
(90 s). During it the server lets clients reclaim the locks they held, so
another client cannot take them in the meantime. Applications are not told
about it: their reads and writes just wait, because volumes are mounted
`hard`.

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

The server runs our own image, built on the upstream provisioner with a
current NFS-Ganesha and settings that keep file locks working when the server
restarts or moves. [`image/README.md`](image/README.md) explains why the
upstream image does not work on current SKS nodes.

Longhorn's RWX volumes are served the same way, by one NFS-Ganesha pod per
volume. Longhorn additionally runs a whole distributed block storage system on
your nodes' disks underneath. On SKS the block storage is already replicated
by Exoscale, so this sample leaves that layer out.

## Operations

### Server restart and node drain

Nothing to do. Clients pause and resume by themselves. Draining the server's
node moves the pod and its volume to another node.

### Node crash

Nothing to do either, as long as the node fencer runs (it is part of
`install.yaml`).

Kubernetes on its own never restarts the NFS server elsewhere while its node is
unreachable, because the old server might still be running and writing. The
[`node.kubernetes.io/out-of-service`](https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/#non-graceful-node-shutdown)
taint tells Kubernetes that the old server is gone. The node fencer
([`image/node-fencer.sh`](image/node-fencer.sh), two pods on different nodes
in the `nfs` namespace) applies the taint when all of the following hold:

* The Exoscale cloud controller manager has marked the node
  `node.cloudprovider.kubernetes.io/shutdown`, which it does when the Exoscale
  API reports the VM as stopping or stopped.
* The node is `NotReady`.
* Both conditions have held for 60 seconds (`SHUTDOWN_FOR` in
  `node-fencer.yaml`).
* The node's kubelet has not renewed its lease in that time. This catches a VM
  that was started again but is not `Ready` yet: the cloud controller removes
  its shutdown mark only once the node is `Ready`.

Kubernetes then deletes the pods on that node, detaches their volumes and
starts them elsewhere. When the node is `Ready` again, the fencer removes the
taint. It only ever removes taints it applied itself.

What we measured when the server's node was powered off:

| After | Event |
|---|---|
| 50 s | Node `NotReady`, Exoscale reports the VM stopped |
| 125 s | Fencer applies the taint |
| 190 s | NFS server running on another node |
| 285 s | Clients resume after the grace period; the DuckDB writer kept its lock |

A node whose VM is still running, for example with a stopped kubelet or a
network problem, is **not** fenced: the VM is not reported as stopped, so the
fencer leaves it alone. We tested that too. A node whose kubelet is alive is
not fenced either, whatever the cloud controller says. If such a node hosts the NFS
server and it really is broken, stop its VM (`exo compute instance stop`) and
the fencer takes over.

The 60 second wait also covers VMs that are still `stopping`. If your VMs can
take longer than that to power off, raise `SHUTDOWN_FOR`: fencing a VM that
still writes to the volume would risk the data.

The taint applies to the whole node, so every stateful pod on it is
rescheduled, not only the NFS server. If you do not want that, delete the
`nfs/node-fencer` deployment and apply the taint by hand when needed:

```bash
kubectl taint node <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
# once the node is back or deleted:
kubectl taint node <node> node.kubernetes.io/out-of-service-
```

### Growing the volume

Do not change the size in `install.yaml` or in your Helm values to resize.
Kubernetes does not allow that part of a StatefulSet to change, so a later
`kubectl apply` or `helm upgrade` with a different size fails with
`spec.volumeClaimTemplates: Invalid value`. Leave the original size in those
files; the claim holds the actual size.

The Exoscale CSI driver can only resize a volume while it is detached, so the
NFS server has to stop briefly. Clients pause and continue afterwards; they get
no errors. In our test the server was down for about 30 seconds, followed by
the usual ~100 s pause.

1. Check the current size and usage:

   ```bash
   kubectl -n nfs exec nfs-nfs-server-provisioner-0 -- df -h /export
   ```

2. Stop the NFS server and wait until its volume is detached (about 15 s).
   The outage starts here. Stop the server **before** requesting the new
   size: the other order also works, but took 5 to 10 minutes in our tests
   because of retries.

   ```bash
   kubectl -n nfs scale statefulset nfs-nfs-server-provisioner --replicas=0
   PV=$(kubectl -n nfs get pvc data-nfs-nfs-server-provisioner-0 -o jsonpath='{.spec.volumeName}')
   [ -n "$PV" ] || echo "volume not found, check the claim name before going on"
   while [ -n "$PV" ] && kubectl get volumeattachments -o jsonpath='{.items[*].spec.source.persistentVolumeName}' | grep -q "$PV"; do sleep 5; done
   ```

3. Request the new size (volumes can only grow) and wait until the
   PersistentVolume reports it, usually within seconds:

   ```bash
   kubectl -n nfs patch pvc data-nfs-nfs-server-provisioner-0 \
     -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}' &&
   until [ "$(kubectl get pv "$PV" -o jsonpath='{.spec.capacity.storage}')" = \
           "$(kubectl -n nfs get pvc data-nfs-nfs-server-provisioner-0 -o jsonpath='{.spec.resources.requests.storage}')" ]; do
     sleep 5
   done
   ```

   Do not start the server until the PersistentVolume shows the new size: once
   the volume is attached again, the resize cannot happen. The claim keeps
   showing the old size until the server mounts the volume again. If the
   patch is refused, or the loop has not finished after a few minutes, check
   `kubectl -n nfs describe pvc data-nfs-nfs-server-provisioner-0` and start
   the server again (step 4) to end the outage.

4. Start the server. The filesystem grows when the volume is mounted:

   ```bash
   kubectl -n nfs scale statefulset nfs-nfs-server-provisioner --replicas=1
   kubectl -n nfs rollout status statefulset nfs-nfs-server-provisioner
   kubectl -n nfs exec nfs-nfs-server-provisioner-0 -- df -h /export
   ```

### Capacity

Each RWX volume is a directory on the shared block volume. The size in a claim
is **not enforced**: any volume can fill the whole disk, and `df` inside a pod
shows the size of the shared disk. Monitor the free space on the server's
volume and [grow it](#growing-the-volume) before it fills up. With Prometheus,
alert on `kubelet_volume_stats_available_bytes` for the claim
`data-nfs-nfs-server-provisioner-0`. Without it:

```bash
kubectl -n nfs exec nfs-nfs-server-provisioner-0 -- df -h /export
```

### Logs

```bash
kubectl -n nfs logs nfs-nfs-server-provisioner-0
kubectl -n nfs logs -l app=node-fencer --prefix   # both copies
```

## Security

The NFS server is shared by the whole cluster, and NFS trusts its clients:

* **Any pod can reach it.** Volumes are mounted by the nodes, but nothing stops
  a pod from talking NFS to the server's Service directly, for example with a
  user-space NFS client, and reading or writing every volume on it. A
  NetworkPolicy cannot narrow this down, because the legitimate traffic comes
  from the nodes themselves.
* **Root is not squashed.** A client that claims to be root has root access to
  the files. If your workloads do not need root on the volumes, set
  `rootSquash: "true"` under `storageClass.parameters` in `values.yaml` and
  install with Helm or a re-rendered `install.yaml` (`hack/render.sh`). On an
  existing installation, delete the `nfs` storage class first: its parameters
  cannot be changed in place. The setting applies to volumes created
  afterwards.
* **Traffic is not encrypted** between the nodes and the server.

Use it on clusters whose workloads you trust. Keep data that other teams must
not see on separate volumes (`exoscale-sbs`) or a separate cluster.

## Backups

All RWX volumes are directories on the one block volume
`nfs/data-nfs-nfs-server-provisioner-0`, so it can be backed up at two levels.

**The whole server, with a volume snapshot.** We tested this: a CSI snapshot of
the running server's volume took 5 s without stopping anything, and a volume
restored from it contained every RWX volume, including a DuckDB database that
was being written to and opened cleanly afterwards. The copy is
crash-consistent, as if the power had been cut, which databases are built to
recover from.

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: nfs-data
  namespace: nfs
spec:
  volumeSnapshotClassName: exoscale-snapshot
  source:
    persistentVolumeClaimName: data-nfs-nfs-server-provisioner-0
```

A snapshot lives next to its volume. For a copy that survives losing the
volume or the cluster, use Velero with its CSI support and data movement
(`--snapshot-move-data`), which copies the snapshot's contents to an Exoscale
SOS bucket. Restoring brings **all** RWX volumes back to the same point in
time, so this is for disaster recovery rather than for restoring one
application.

**Single applications, with Velero file-system backup.** Velero's node agent
copies the files of an application's RWX volumes through its pods to object
storage, so you can restore one application. The copy is not taken at a single
point in time: a file that is written during the backup, such as a DuckDB
database, can come out inconsistent. Stop or checkpoint such writers with a
Velero backup hook, or exclude them and rely on the volume snapshot.

Things to know when restoring:

* The RWX PersistentVolumes point at the **ClusterIP** of the
  `nfs-nfs-server-provisioner` Service, and a restore into a new cluster
  creates that Service with a new address (Velero always clears it). Restored
  RWX PersistentVolumes then point at an address that no longer exists. Either
  restore the applications' claims and let the provisioner create new volumes
  (file-system backup does this), or recreate the PersistentVolumes with the
  new address.
* The provisioner does not support snapshots of the RWX volumes themselves;
  only the server's volume can be snapshotted.

We have not tested a full Velero backup and restore with this sample.

## Using it with DuckDB

DuckDB allows **one** process to open a database file read-write, **or** any
number of processes to open it read-only, never both at once. It enforces that
with file locks, and those locks work across nodes on this storage. We tested:

| Pattern | Result |
|---|---|
| One writer pod holds `db.duckdb`. A second pod on any node opens it, read-write or read-only | Refused: `Could not set lock on file ... Conflicting lock is held` |
| NFS server restarted, moved, or its node crashed, while the writer holds the file | Writer pauses, keeps its lock, continues. Others still refused |
| No writer. Several read-only pods on different nodes open `db.duckdb` | All succeed |
| Several writer pods each write their own Parquet files into one directory, readers query `read_parquet('/data/lake/*.parquet')` | Works, every pod sees every file |

RWX does not turn DuckDB into a multi-writer database. If several pods need to
write, give each its own file (Parquet, or one `.duckdb` per writer) and read
them together with a glob. For a single writer, run it as one replica with
`strategy: Recreate`, so an update never starts a second writer while the
first still holds the lock. If the data does not need to be a filesystem,
DuckDB can also read and write Parquet on Exoscale SOS directly.

## Uninstall

1. Delete the workloads that use RWX volumes, then their claims, so the
   provisioner removes their directories. Pods still using a volume when the
   server goes away hang, because volumes are mounted `hard`.
2. Remove the sample. This deletes the `nfs` namespace and, with it, the block
   volume, **including all data on it**:

   ```bash
   kubectl delete -f https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.2/nfs-rwx/install.yaml
   ```

With Helm, step 2 is:

```bash
helm -n nfs uninstall nfs
kubectl delete -f https://raw.githubusercontent.com/exoscale-labs/sks-sample-manifests/nfs-rwx-v0.1.2/nfs-rwx/node-fencer.yaml
kubectl -n nfs delete pvc data-nfs-nfs-server-provisioner-0   # Helm leaves the claim and its volume in place
```

## Files

| File | Purpose |
|---|---|
| [`install.yaml`](install.yaml) | The complete install, ready for `kubectl apply`. Generated, do not edit |
| [`values.yaml`](values.yaml) | Helm values the install is rendered from |
| [`node-fencer.yaml`](node-fencer.yaml) | Node fencer deployment and its RBAC |
| [`image/`](image/) | Server and node fencer image, with tests ([details](image/README.md)) |
| [`hack/render.sh`](hack/render.sh) | Regenerates `install.yaml` after changing the two files above |
| [`examples/rwx-smoke-test.yaml`](examples/rwx-smoke-test.yaml) | Three pods sharing one volume |

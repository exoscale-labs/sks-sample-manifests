# nfs-rwx image

The container image behind [nfs-rwx](../README.md), published as
`ghcr.io/exoscale-labs/nfs-rwx`. It runs the NFS server and, with a different
command, the node fencer.

## Why not the upstream image

The nfs-server-provisioner chart's default image
(`registry.k8s.io/sig-storage/nfs-provisioner:v4.0.8`) was last published in
2023. It runs NFS-Ganesha 4.0.8 on Fedora 36, which reached end of life in
2023. We found four problems running it on SKS. The first two show up
immediately; the last two only when the server restarts or moves while
applications hold file locks:

* **"Remote I/O error" on directory listings.** Linux 6.19 and later, which
  SKS nodes run, asks for NFSv4 directory delegations. Ganesha before 9.13
  rejects the whole request instead of declining the delegation
  ([nfs-ganesha#1385](https://github.com/nfs-ganesha/nfs-ganesha/issues/1385)),
  and the client reports `EREMOTEIO`. In our tests, every new pod's first `ls`
  after creating a file failed this way.
* **Files owned by `nobody`.** NFSv4 sends owners as `user@domain` names by
  default. SKS nodes do not run the ID mapping service, so every file shows up
  as uid 65534. Fixed by `Only_Numeric_Owners = true`.
* **Locks lost when the server moves.** For lock recovery, Ganesha records each
  client by its ID *and the IP address it connects from*. On Kubernetes that
  address changes with the server's placement: a node is seen by its tunnel
  address while the server runs elsewhere, and by its own address while the
  server runs on it. Each time the server moved, clients on the node it left
  and on the node it landed on could not reclaim their locks and got I/O errors
  on locked files; our DuckDB writer crashed with `fsync failed!`. Ganesha 11
  added `RecoverySkipIp = true` to identify clients by ID alone.
* **Locks lost on a second restart during the grace period**, as happens when
  a node upgrade moves the server twice in a row. The default recovery backend
  replaces its client list at every start and forgets clients that had not
  reclaimed yet. Fixed by `RecoveryBackend = fs_ng`, which replaces the list
  only once grace has ended.

## What is in it

* [`Dockerfile`](Dockerfile): the upstream provisioner built from a pinned
  commit, and Ganesha 14.1 from Fedora 45, the first Fedora release with
  Ganesha 11 or later (Debian and Ubuntu ship 6.5).
* [`entrypoint.sh`](entrypoint.sh): sets the three Ganesha options above in
  `/export/vfs.conf` on every start, overwriting other values, and refuses to
  start if it cannot. It also sends Ganesha's log to the container log.
  Ganesha's lock recovery records stay on the data volume, so they survive a
  restart.
* [`node-fencer.sh`](node-fencer.sh): the node fencer, see
  [Node crash](../README.md#node-crash).
* [`tests/`](tests/): tests for both scripts. CI runs them inside the built
  image before publishing it:

  ```bash
  docker build -t nfs-rwx:test .
  docker run --rm -v "$PWD/tests:/tests:ro" --entrypoint sh nfs-rwx:test /tests/test-entrypoint.sh
  docker run --rm -v "$PWD/tests:/tests:ro" --entrypoint sh nfs-rwx:test /tests/test-node-fencer.sh
  ```

## Upgrading from the upstream image

Switching an existing installation of the upstream chart to this image keeps
your data: change the image in your Helm values and `helm upgrade`. The
entrypoint adds the settings to the existing Ganesha config on first start.
Because that changes how clients are recorded, applications holding file locks
during that one restart lose those locks.

## Releasing

1. Set the new version in `values.yaml` and `node-fencer.yaml` and in the URLs
   in the README, then run `hack/render.sh`. It refuses to run when the two
   image tags differ.
2. Commit and push to `main`.
3. Push a tag `nfs-rwx-v<version>`. CI tests the image, then publishes it as
   `ghcr.io/exoscale-labs/nfs-rwx:<version>`, which the tagged `install.yaml`
   points at.

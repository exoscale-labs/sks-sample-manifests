# NFS-Ganesha server with the Kubernetes nfs-provisioner.
#
# The provisioner (kubernetes-sigs/nfs-ganesha-server-and-external-provisioner)
# has not published an image since v4.0.8 (2023), which ships Ganesha 4.0.8 on
# Fedora 36. That Ganesha answers GET_DIR_DELEGATION with NFS4ERR_OP_ILLEGAL,
# and Linux 6.19+ clients, including current SKS nodes, then fail directory
# listings with "Remote I/O error" (nfs-ganesha/nfs-ganesha#1385, fixed in 9.13).
#
# This image keeps the upstream provisioner binary and swaps the server for the
# Ganesha packaged by Fedora. Fedora 45 is the first release with Ganesha 11+
# (it ships 14.1), which adds RecoverySkipIp; see entrypoint.sh for why that
# matters on Kubernetes. entrypoint.sh adds three settings to the Ganesha
# config before the provisioner starts.
#
# The same image also runs node-fencer.sh (kubectl + jq), which lets the server
# move off a node whose VM has stopped.

ARG FEDORA_VERSION=45
# Upstream main as of 2026-03-31.
ARG PROVISIONER_COMMIT=84d9acf3aea6901647038d9f175c80927ab0e6ba

FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.25 AS build
ARG PROVISIONER_COMMIT
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
RUN git init -q . \
    && git remote add origin https://github.com/kubernetes-sigs/nfs-ganesha-server-and-external-provisioner \
    && git fetch -q --depth 1 origin ${PROVISIONER_COMMIT} \
    && git checkout -q FETCH_HEAD
# The vendor directory upstream is out of sync with go.mod.
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} GOFLAGS=-mod=mod \
    go build -trimpath -ldflags="-s -w" -o /nfs-provisioner ./cmd/nfs-provisioner

FROM registry.fedoraproject.org/fedora-minimal:${FEDORA_VERSION}
RUN microdnf install -y --setopt=install_weak_deps=0 \
        dbus-daemon \
        hostname \
        jq \
        kubernetes1.36-client \
        nfs-ganesha \
        nfs-ganesha-vfs \
        nfs-utils \
        rpcbind \
    && microdnf clean all \
    && mkdir -p /export /var/run/dbus \
    # Keep Ganesha's NFSv4 client recovery records on the data volume, so
    # clients can reclaim their locks after the server pod restarts.
    && rm -rf /var/lib/nfs/ganesha \
    && ln -s /export /var/lib/nfs/ganesha \
    # No systemd in the container: resolve users from files only.
    && sed -i 's/ systemd//' /etc/nsswitch.conf
COPY --from=build /nfs-provisioner /nfs-provisioner
COPY entrypoint.sh node-fencer.sh /
EXPOSE 2049/tcp 20048/tcp 111/tcp 111/udp
ENTRYPOINT ["/entrypoint.sh"]

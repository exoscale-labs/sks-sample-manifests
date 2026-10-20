#!/bin/sh
# Lets the NFS server move off a node whose VM has stopped.
#
# Kubernetes never restarts a StatefulSet pod elsewhere while its node is
# unreachable: the pod might still be running and writing. Once you know the
# VM is off, the node.kubernetes.io/out-of-service taint tells Kubernetes so;
# it then deletes the pods, detaches their volumes and reschedules them.
#
# This loop applies that taint for you, but only when the Exoscale cloud
# controller manager has marked the node with
# node.cloudprovider.kubernetes.io/shutdown (the Exoscale API reports the VM as
# stopping or stopped), the node is NotReady, and both have been true for
# SHUTDOWN_FOR seconds. A node that hangs while its VM still runs is never
# touched. When the node is Ready again, the taint is removed.
#
# The taint applies to the whole node, so every stateful pod on it benefits,
# not only the NFS server.
set -eu

INTERVAL=${INTERVAL:-15}
SHUTDOWN_FOR=${SHUTDOWN_FOR:-60}

SHUTDOWN_TAINT=node.cloudprovider.kubernetes.io/shutdown
OOS_TAINT=node.kubernetes.io/out-of-service
# Marks nodes we tainted, so we never remove a taint someone else applied.
MARK=nfs-rwx.exoscale-labs.io/fenced

SEEN=$(mktemp -d)   # one file per node: when we first saw it shut down

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

log "watching nodes every ${INTERVAL}s, fencing after ${SHUTDOWN_FOR}s of shutdown"

while true; do
    nodes=$(kubectl get nodes -o json | jq -r --arg s "$SHUTDOWN_TAINT" --arg o "$OOS_TAINT" --arg m "$MARK" '
        .items[] | [
            .metadata.name,
            any(.spec.taints[]?; .key == $s),
            any(.spec.taints[]?; .key == $o),
            ((.status.conditions[]? | select(.type == "Ready") | .status) // "Unknown"),
            (.metadata.annotations[$m] // "")
        ] | @tsv') || { log "listing nodes failed, retrying"; sleep "$INTERVAL"; continue; }

    now=$(date +%s)
    echo "$nodes" | while IFS="$(printf '\t')" read -r node shutdown oos ready mark; do
        [ -n "$node" ] || continue

        if [ "$shutdown" = true ] && [ "$ready" != True ]; then
            [ -f "$SEEN/$node" ] || { echo "$now" > "$SEEN/$node"; log "$node: VM shut down, waiting ${SHUTDOWN_FOR}s"; }
            since=$(( now - $(cat "$SEEN/$node") ))
            if [ "$oos" = false ] && [ "$since" -ge "$SHUTDOWN_FOR" ]; then
                log "$node: shut down for ${since}s, applying $OOS_TAINT"
                kubectl annotate node "$node" "$MARK=true" --overwrite >/dev/null &&
                    kubectl taint node "$node" "$OOS_TAINT=nodeshutdown:NoExecute" >/dev/null ||
                    log "$node: tainting failed, retrying next round"
            fi
        else
            rm -f "$SEEN/$node"
        fi

        if [ "$mark" = true ] && [ "$ready" = True ]; then
            log "$node: Ready again, removing $OOS_TAINT"
            { [ "$oos" = false ] || kubectl taint node "$node" "$OOS_TAINT-" >/dev/null; } &&
                kubectl annotate node "$node" "$MARK-" >/dev/null ||
                log "$node: untainting failed, retrying next round"
        fi
    done

    sleep "$INTERVAL"
done

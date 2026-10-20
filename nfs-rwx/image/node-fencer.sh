#!/bin/sh
# Lets the NFS server move off a node whose VM has stopped.
#
# Kubernetes never restarts a StatefulSet pod elsewhere while its node is
# unreachable: the pod might still be running and writing. Once you know the
# VM is off, the node.kubernetes.io/out-of-service taint tells Kubernetes so;
# it then deletes the pods, detaches their volumes and reschedules them.
#
# This loop applies that taint for you, but only when all of these hold:
#   - the Exoscale cloud controller manager has marked the node with
#     node.cloudprovider.kubernetes.io/shutdown (the Exoscale API reported the
#     VM as stopping or stopped),
#   - the node is NotReady,
#   - both have been true for SHUTDOWN_FOR seconds,
#   - the node's kubelet has not renewed its lease for SHUTDOWN_FOR seconds.
# The last check matters because the cloud controller removes the shutdown
# taint only once the node is Ready again, not when the VM starts: a VM that
# was started again but is not Ready yet still carries it. A live kubelet
# renews its lease every 10 seconds. When the node is Ready again, the taint
# is removed.
#
# The taint applies to the whole node, so every stateful pod on it is
# rescheduled, not only the NFS server.
set -eu

INTERVAL=${INTERVAL:-15}
SHUTDOWN_FOR=${SHUTDOWN_FOR:-60}
# Touched after every successful round; the liveness probe watches it.
HEARTBEAT=${HEARTBEAT:-/tmp/heartbeat}
# Stop after this many rounds; 0 runs forever. Used by the tests.
ROUNDS=${ROUNDS:-0}

SHUTDOWN_TAINT=node.cloudprovider.kubernetes.io/shutdown
OOS_TAINT=node.kubernetes.io/out-of-service
# Marks nodes we tainted, so we never remove a taint someone else applied.
MARK=nfs-rwx.exoscale-labs.io/fenced

whole_number() {
    case $2 in
        ''|*[!0-9]*) echo "$1 must be a whole number, got '$2'" >&2; exit 1 ;;
    esac
}
whole_number INTERVAL "$INTERVAL"
whole_number SHUTDOWN_FOR "$SHUTDOWN_FOR"
whole_number ROUNDS "$ROUNDS"
[ "$INTERVAL" -gt 0 ] || { echo "INTERVAL must be greater than 0" >&2; exit 1; }

SEEN=$(mktemp -d)   # one file per node: when we first saw it shut down

# Exit cleanly when Kubernetes stops the pod, instead of showing it as failed.
trap 'exit 0' TERM INT

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# A hung API call must not stall the loop forever. The timeout is enforced
# from outside: kubectl ignores its in-cluster credentials as soon as a client
# flag such as --request-timeout is given, and then talks to localhost:8080.
k() { timeout 30 kubectl "$@"; }

# Node name, shutdown taint, out-of-service taint, Ready status, our mark.
# shellcheck disable=SC2016 # jq variables, not shell ones
NODE_FIELDS='[
    .metadata.name,
    any(.spec.taints[]?; .key == $s),
    any(.spec.taints[]?; .key == $o),
    ((.status.conditions[]? | select(.type == "Ready") | .status) // "Unknown"),
    (.metadata.annotations[$m] // "")
] | @tsv'

fields() { jq -r --arg s "$SHUTDOWN_TAINT" --arg o "$OOS_TAINT" --arg m "$MARK" "$1"; }

# Re-reads one node right before acting on it, so a node that came back, or
# that the other copy of the fencer tainted, since the listing is left alone.
still_shut_down() {
    k get node "$1" -o json | fields "$NODE_FIELDS" |
        awk -F '\t' '$2 == "true" && $3 == "false" && $4 != "True" { found = 1 } END { exit !found }'
}

# Whether the taint is on the node now, for deciding what a failed call did.
has_oos_taint() {
    k get node "$1" -o json | fields "$NODE_FIELDS" |
        awk -F '\t' '$3 == "true" { found = 1 } END { exit !found }'
}

# True only if the node's kubelet has not renewed its lease for SHUTDOWN_FOR
# seconds. If the lease cannot be read, the node counts as alive.
kubelet_silent() {
    # shellcheck disable=SC2016 # jq program
    renewed=$(k get lease "$1" -n kube-node-lease -o json |
        jq -r '.spec.renewTime // empty | sub("\\.[0-9]+"; "") | fromdateiso8601') || return 1
    [ -n "$renewed" ] && [ $(( $(date +%s) - renewed )) -ge "$SHUTDOWN_FOR" ]
}

# Counts rounds and stops after ROUNDS of them (tests only), then waits.
round=0
next_round() {
    round=$((round + 1))
    [ "$ROUNDS" -eq 0 ] || [ "$round" -lt "$ROUNDS" ] || exit "$1"
    # In the background, so a stop signal is handled at once rather than
    # after the sleep.
    sleep "$INTERVAL" &
    wait $!
}

log "watching nodes every ${INTERVAL}s, fencing after ${SHUTDOWN_FOR}s of shutdown"

while true; do
    # Fetch first, parse second: in a pipeline a kubectl failure would be
    # hidden behind jq's exit status.
    if ! json=$(k get nodes -o json) || ! nodes=$(printf '%s' "$json" | fields ".items[] | $NODE_FIELDS"); then
        log "listing nodes failed, retrying"
        next_round 1
        continue
    fi

    now=$(date +%s)
    printf '%s\n' "$nodes" | while IFS="$(printf '\t')" read -r node shutdown oos ready mark; do
        [ -n "$node" ] || continue

        if [ "$shutdown" = true ] && [ "$ready" != True ]; then
            first=$(cat "$SEEN/$node" 2>/dev/null || true)
            case $first in
                ''|*[!0-9]*) first=$now; echo "$now" > "$SEEN/$node"; log "$node: VM shut down, waiting ${SHUTDOWN_FOR}s" ;;
            esac
            since=$(( now - first ))
            if [ "$oos" = false ] && [ "$since" -ge "$SHUTDOWN_FOR" ] && still_shut_down "$node"; then
                if ! kubelet_silent "$node"; then
                    log "$node: kubelet still renews its lease, not fencing"
                elif k annotate node "$node" "$MARK=true" --overwrite >/dev/null; then
                    log "$node: shut down for ${since}s, applying $OOS_TAINT"
                    # --overwrite: the other copy may have tainted it a moment ago.
                    if ! k taint node "$node" "$OOS_TAINT=nodeshutdown:NoExecute" --overwrite >/dev/null; then
                        log "$node: tainting failed, retrying next round"
                        # A timed-out call may still have tainted the node; keep the
                        # mark then, or the taint would never be removed.
                        has_oos_taint "$node" || k annotate node "$node" "$MARK-" >/dev/null || true
                    fi
                else
                    log "$node: marking failed, retrying next round"
                fi
            fi
        else
            rm -f "$SEEN/$node"
        fi

        if [ "$mark" = true ] && [ "$ready" = True ]; then
            log "$node: Ready again, removing $OOS_TAINT"
            if { [ "$oos" = false ] || k taint node "$node" "$OOS_TAINT:NoExecute-" >/dev/null; } &&
                k annotate node "$node" "$MARK-" >/dev/null; then
                :
            else
                log "$node: untainting failed, retrying next round"
            fi
        fi
    done

    # Forget nodes that no longer exist.
    for f in "$SEEN"/*; do
        [ -e "$f" ] || continue
        printf '%s\n' "$nodes" | cut -f1 | grep -qxF "${f##*/}" || rm -f "$f"
    done

    touch "$HEARTBEAT"
    next_round 0
done

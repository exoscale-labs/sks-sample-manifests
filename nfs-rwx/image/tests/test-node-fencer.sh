#!/bin/sh
# Tests for node-fencer.sh against a stubbed kubectl. Run inside the image:
#   docker run --rm -v "$PWD/tests:/tests:ro" --entrypoint sh IMAGE /tests/test-node-fencer.sh
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
FENCER=${FENCER:-/node-fencer.sh}
WORK=$(mktemp -d)
export PATH="$HERE:$PATH" NODES_JSON="$WORK/nodes.json" CALLS="$WORK/calls"
export HEARTBEAT="$WORK/heartbeat" INTERVAL=1 ROUNDS=1
failed=0

# node NAME READY [shutdown] [oos] [marked]
node() {
    name=$1 ready=$2; shift 2
    taints="[]" annotations="{}"
    for flag in "$@"; do
        case $flag in
            shutdown) taints=$(echo "$taints" | jq '. + [{"key":"node.cloudprovider.kubernetes.io/shutdown","effect":"NoSchedule"}]') ;;
            oos) taints=$(echo "$taints" | jq '. + [{"key":"node.kubernetes.io/out-of-service","value":"nodeshutdown","effect":"NoExecute"}]') ;;
            marked) annotations='{"nfs-rwx.exoscale-labs.io/fenced":"true"}' ;;
        esac
    done
    jq -n --arg n "$name" --arg r "$ready" --argjson t "$taints" --argjson a "$annotations" \
        '{metadata:{name:$n,annotations:$a},spec:{taints:$t},status:{conditions:[{type:"Ready",status:$r}]}}'
}

nodes() { jq -s '{items: .}' > "$NODES_JSON"; }

# run NAME EXPECTED_CALLS [env assignments...]
run() {
    name=$1 expected=$2; shift 2
    : > "$CALLS"
    rm -f "$HEARTBEAT"
    status=0
    env "$@" sh "$FENCER" > "$WORK/out" 2>&1 || status=$?
    actual=$(cat "$CALLS")
    if [ "$actual" = "$expected" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name"; echo "  expected: $(echo "$expected" | tr '\n' '|')"; echo "  actual:   $(echo "$actual" | tr '\n' '|')"
        sed 's/^/  log: /' "$WORK/out"; failed=1
    fi
    echo "$status" > "$WORK/status"
}

TAINT="taint node a node.kubernetes.io/out-of-service=nodeshutdown:NoExecute"
MARK="annotate node a nfs-rwx.exoscale-labs.io/fenced=true --overwrite"
UNTAINT="taint node a node.kubernetes.io/out-of-service-"
UNMARK="annotate node a nfs-rwx.exoscale-labs.io/fenced-"

{ node a False shutdown; node b True; } | nodes
run "stopped VM, NotReady, wait elapsed: fenced" "$MARK
$TAINT" SHUTDOWN_FOR=0
[ -f "$HEARTBEAT" ] || { echo "FAIL heartbeat not written"; failed=1; }

run "stopped VM, wait not elapsed: not fenced" "" SHUTDOWN_FOR=60

run "taint fails: mark rolled back" "$MARK
$TAINT
$UNMARK" SHUTDOWN_FOR=0 FAIL_TAINT=true

{ node a False; } | nodes
run "NotReady but VM running: not fenced" "" SHUTDOWN_FOR=0

{ node a Unknown; } | nodes
run "unreachable but VM running: not fenced" "" SHUTDOWN_FOR=0

{ node a True shutdown; } | nodes
run "shutdown taint but Ready: not fenced" "" SHUTDOWN_FOR=0

{ node a False shutdown oos marked; } | nodes
run "already fenced: nothing to do" "" SHUTDOWN_FOR=0

{ node a True oos marked; } | nodes
run "back to Ready: our taint removed" "$UNTAINT
$UNMARK"

{ node a True oos; } | nodes
run "someone else's taint: left alone" ""

{ node a False shutdown; } | nodes
run "listing fails: no action, non-zero exit" "" SHUTDOWN_FOR=0 FAIL_LIST=true
[ "$(cat "$WORK/status")" != 0 ] || { echo "FAIL listing failure exited 0"; failed=1; }
grep -q "listing nodes failed" "$WORK/out" || { echo "FAIL listing failure not logged"; failed=1; }

for bad in "SHUTDOWN_FOR=abc" "INTERVAL=0" "SHUTDOWN_FOR=-5"; do
    status=0; env "$bad" sh "$FENCER" > /dev/null 2>&1 || status=$?
    if [ "$status" != 0 ]; then echo "ok   rejects $bad"; else echo "FAIL accepted $bad"; failed=1; fi
done

rm -rf "$WORK"
exit "$failed"

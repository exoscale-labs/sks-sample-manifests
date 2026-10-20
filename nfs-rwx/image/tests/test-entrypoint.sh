#!/bin/sh
# Tests for entrypoint.sh. Run inside the image:
#   docker run --rm -v "$PWD/tests:/tests:ro" --entrypoint sh IMAGE /tests/test-entrypoint.sh
set -eu

ENTRYPOINT=${ENTRYPOINT:-/entrypoint.sh}
WORK=$(mktemp -d)
export CONFIG="$WORK/vfs.conf" LOG_TO_STDOUT=false PROVISIONER=true
failed=0

check() {
    name=$1
    if sh "$ENTRYPOINT" > "$WORK/out" 2>&1; then
        bad=""
        for want in 'Only_Numeric_Owners = true;' 'RecoveryBackend = fs_ng;' 'RecoverySkipIp = true;' 'Grace_Period = '; do
            [ "$(grep -c "^[[:space:]]*$want" "$CONFIG")" = 1 ] || bad="$bad [$want]"
        done
        [ "$(grep -ci '^[[:space:]]*NFSV4' "$CONFIG")" = 1 ] || bad="$bad [one NFSV4 block]"
        if [ -z "$bad" ]; then echo "ok   $name"; else echo "FAIL $name: missing or repeated$bad"; cat "$CONFIG"; failed=1; fi
    else
        echo "FAIL $name: entrypoint failed"; cat "$WORK/out"; failed=1
    fi
}

rm -f "$CONFIG"; check "no config: default written"
check "second start: unchanged"

: > "$CONFIG"; check "empty config: default written"

printf 'NFS_Core_Param\n{\n\tMNT_Port = 20048;\n}\n\nNFSV4\n{\n\tGrace_Period = 90;\n}\n' > "$CONFIG"
check "upstream config: settings added"

printf 'NFSV4\n{\n\tGrace_Period = 90;\n\tOnly_Numeric_Owners = true;\n}\n' > "$CONFIG"
check "partial config: missing settings added"

printf 'NFSV4\n{\n\tGrace_Period = 90;\n\tRecoveryBackend = fs;\n\tOnly_Numeric_Owners = false;\n\trecoveryskipip=false;\n}\n' > "$CONFIG"
check "wrong values: corrected"

printf 'NFS_Core_Param\n{\n\tMNT_Port = 20048;\n}\n' > "$CONFIG"
check "no NFSV4 block: block added"

printf 'NFSV4 {\r\n\tGrace_Period = 90;\r\n}\r\n' > "$CONFIG"
check "CRLF line endings and brace on the same line"

printf 'EXPORT {\n\tPath = /export/pvc-1;\n}\n' > "$CONFIG"
sh "$ENTRYPOINT" > /dev/null 2>&1
if grep -q 'Path = /export/pvc-1;' "$CONFIG"; then echo "ok   exports kept"; else echo "FAIL exports lost"; failed=1; fi

export LOG_TO_STDOUT=true GANESHA_LOG="$WORK/ganesha.log" GANESHA_LOG_MAX_BYTES=100 GANESHA_LOG_CHECK_SECONDS=1
ln -s /dev/null "$GANESHA_LOG"
sh "$ENTRYPOINT" > /dev/null 2>&1
if [ -f "$GANESHA_LOG" ] && [ ! -L "$GANESHA_LOG" ]; then echo "ok   symlinked log replaced by a file"; else echo "FAIL symlinked log kept"; failed=1; fi
echo "line from an earlier run" > "$GANESHA_LOG"
sh "$ENTRYPOINT" > "$WORK/stdout" 2>&1
sleep 1
echo "new ganesha line" >> "$GANESHA_LOG"
sleep 2
if grep -q "new ganesha line" "$WORK/stdout" && ! grep -q "earlier run" "$WORK/stdout"; then
    echo "ok   new log lines reach the container log"
else
    echo "FAIL log lines not copied"; cat "$WORK/stdout"; failed=1
fi
head -c 500 /dev/zero >> "$GANESHA_LOG"
sleep 3
if [ "$(stat -c %s "$GANESHA_LOG")" -le 100 ]; then
    echo "ok   log emptied when over the limit"
else
    echo "FAIL log not emptied: $(stat -c %s "$GANESHA_LOG") bytes"; failed=1
fi
echo "after emptying" >> "$GANESHA_LOG"
sleep 2
if grep -q "after emptying" "$WORK/stdout"; then echo "ok   copying continues after emptying"; else echo "FAIL copying stopped after emptying"; failed=1; fi

rm -rf "$WORK"
exit "$failed"

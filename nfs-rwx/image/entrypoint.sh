#!/bin/sh
# Prepares the Ganesha config and log before the provisioner starts.
#
# The image owns three settings in the NFSV4 block of the config:
#
# Only_Numeric_Owners = true: send owners as numeric uid/gid. Without it NFSv4
# sends "user@domain" names, and SKS nodes, which run no idmapd, show every
# file as owned by nobody (65534).
#
# RecoveryBackend = fs_ng: the default "fs" backend replaces its list of
# clients at every start. A second restart within the grace period (a node
# upgrade moving the server twice, for example) then forgets the clients that
# had not reclaimed their locks yet, and they get I/O errors on files they
# hold locked. fs_ng only replaces the list once grace has ended.
#
# RecoverySkipIp = true: Ganesha identifies a client for lock recovery by its
# client ID plus the IP address it connects from. On Kubernetes that address
# depends on where the server pod runs: a node is seen by its tunnel address
# while the server is elsewhere and by its own address while the server runs
# on it. So every time the server moves, clients on the node it leaves and on
# the node it lands on could not reclaim their locks. The client ID alone (it
# contains the node name) is enough to tell them apart.
#
# The provisioner writes the config only when it does not exist yet and then
# edits single lines in it, so lines we add here are kept. If a setting has a
# different value, we overwrite it: these values are what the sample was
# tested with.
#
# Ganesha logs to a file on the data volume (the provisioner sets that). We
# copy new lines to the container log, so `kubectl logs` shows them, and empty
# the file when it grows past GANESHA_LOG_MAX_BYTES, so it cannot fill the
# volume. Ganesha cannot write to the container log directly: it reopens the
# file for every message, and after dropping capabilities at startup it may no
# longer open another process's stdout.
set -eu

CONFIG=${CONFIG:-/export/vfs.conf}
GANESHA_LOG=${GANESHA_LOG:-/export/ganesha.log}
GANESHA_LOG_MAX_BYTES=${GANESHA_LOG_MAX_BYTES:-10485760}
GANESHA_LOG_CHECK_SECONDS=${GANESHA_LOG_CHECK_SECONDS:-300}
LOG_TO_STDOUT=${LOG_TO_STDOUT:-true}
PROVISIONER=${PROVISIONER:-/nfs-provisioner}

SETTINGS='Only_Numeric_Owners=true
RecoveryBackend=fs_ng
RecoverySkipIp=true'

fail() { echo "entrypoint: $*" >&2; exit 1; }

if [ ! -s "$CONFIG" ]; then
    # Same as the provisioner's built-in default, plus our three settings.
    # Written to a temporary file first, so a crash cannot leave a partial
    # config that the next start would take as valid.
    cat > "$CONFIG.tmp" <<'CONF'
EXPORT {
	Export_Id = 0;
	Path = /;
	Pseudo = /;
	Protocols = 4;
	Access_Type = MDONLY_RO;
	Filesystem_Id = 152.152;
	FSAL {
		Name = PSEUDO;
	}
}

NFS_Core_Param
{
	MNT_Port = 20048;
	NLM_Port = 32803;
	fsid_device = true;
	allow_set_io_flusher_fail = true;
}

NFSV4
{
	Grace_Period = 90;
	Only_Numeric_Owners = true;
	RecoveryBackend = fs_ng;
	RecoverySkipIp = true;
}
CONF
    chmod 600 "$CONFIG.tmp"
    mv "$CONFIG.tmp" "$CONFIG"
else
    # A config written by an earlier image or by hand. Changing how clients
    # are recorded drops the existing records once, so clients holding locks
    # during that one restart lose them.
    sed -i 's/\r$//' "$CONFIG"
    if ! grep -qi '^[[:space:]]*NFSV4\b' "$CONFIG"; then
        # The provisioner replaces the Grace_Period line with its own value.
        printf '\nNFSV4\n{\n\tGrace_Period = 90;\n}\n' >> "$CONFIG"
    fi
    for setting in $SETTINGS; do
        key=${setting%%=*}
        value=${setting#*=}
        if grep -qi "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG"; then
            sed -i "s/^[[:space:]]*${key}[[:space:]]*=.*/\t$key = $value;/I" "$CONFIG"
        else
            # Insert after the opening brace of the NFSV4 block.
            awk -v line="	$key = $value;" '
                /^[[:space:]]*NFSV4([^A-Za-z0-9_]|$)/ { inblock = 1 }
                { print }
                inblock && /\{/ { print line; inblock = 0 }
            ' "$CONFIG" > "$CONFIG.tmp"
            mv "$CONFIG.tmp" "$CONFIG"
        fi
    done
fi

# Refuse to start without the settings: a server without them loses client
# locks when it restarts or moves.
for setting in $SETTINGS; do
    key=${setting%%=*}
    value=${setting#*=}
    grep -qx "[[:space:]]*$key = $value;" "$CONFIG" ||
        fail "could not set '$key = $value' in $CONFIG"
done

if [ "$LOG_TO_STDOUT" = true ]; then
    # Both run in the background next to the provisioner. If either stops,
    # only the copy to the container log or the size limit stops; Ganesha
    # keeps running.
    # A symlink here would send Ganesha's log somewhere else; use a plain file.
    [ ! -L "$GANESHA_LOG" ] || rm -f "$GANESHA_LOG"
    touch "$GANESHA_LOG"
    tail -n 0 -F "$GANESHA_LOG" 2>/dev/null &
    (
        while sleep "$GANESHA_LOG_CHECK_SECONDS"; do
            size=$(stat -c %s "$GANESHA_LOG" 2>/dev/null || echo 0)
            [ "$size" -le "$GANESHA_LOG_MAX_BYTES" ] || : > "$GANESHA_LOG"
        done
    ) &
fi

exec "$PROVISIONER" "$@"

#!/bin/sh
# Adds three settings to the Ganesha config before the provisioner starts:
#
# Only_Numeric_Owners: send owners as numeric uid/gid. Without it NFSv4 sends
# "user@domain" names, and SKS nodes, which run no idmapd, show every file as
# owned by nobody (65534).
#
# RecoveryBackend = fs_ng: the default "fs" backend replaces its list of
# clients at every start. A second restart within the grace period (a node
# upgrade moving the server twice, for example) then forgets the clients that
# had not reclaimed their locks yet, and they get I/O errors on files they
# hold locked. fs_ng only replaces the list once grace has ended.
#
# RecoverySkipIp: Ganesha identifies a client for lock recovery by its client
# ID plus the IP address it connects from. On Kubernetes that address depends
# on where the server pod runs: a node is seen by its tunnel address while the
# server is elsewhere and by its own address while the server runs on it. So
# every time the server moves, clients on the node it leaves and on the node
# it lands on could not reclaim their locks. The client ID alone (it contains
# the node name) is enough to tell them apart.
#
# The provisioner writes /export/vfs.conf only when it does not exist yet and
# then edits single lines in it, so lines we add here are kept.
set -eu

CONFIG=/export/vfs.conf

if [ ! -f "$CONFIG" ]; then
    # Same as the provisioner's built-in default, plus our three settings.
    cat > "$CONFIG" <<'CONF'
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
    chmod 600 "$CONFIG"
else
    # Config written by an earlier image: add what is missing to the NFSV4
    # block. Changing how clients are recorded drops the existing records
    # once, so clients holding locks during that one restart lose them.
    for setting in 'Only_Numeric_Owners = true' 'RecoveryBackend = fs_ng' 'RecoverySkipIp = true'; do
        grep -q "^\s*${setting%% *}" "$CONFIG" ||
            sed -i "s/^\(\s*Grace_Period = [0-9]*;\)$/\1\n\t$setting;/" "$CONFIG"
    done
fi

exec /nfs-provisioner "$@"

#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2129  # '$' inside single quotes is go-template / awk syntax on purpose
#
# sks-health-check.sh - READ-ONLY health check for a Kubernetes (Exoscale SKS) cluster.
#
# Looks at memory pressure, node problems, OOM kills, warnings, storage (Longhorn) and
# common Kubernetes pitfalls, and writes everything into one timestamped folder plus a
# short plain-language summary (summary.txt). It only runs kubectl get / describe / top /
# logs / auth can-i. It never creates, changes or deletes anything and never reads
# Secrets or ConfigMaps.
#
# Usage:  ./sks-health-check.sh [-k kubeconfig] [-c context] [-o output-dir] [--with-logs]
# See sks-health-check.md for what is collected and how to make a read-only kubeconfig.

set -u
set -o pipefail
umask 077   # result folder is readable by the current user only

VERSION="2.0"
KUBECONFIG_FILE=""
KCONTEXT=""
OUT_BASE="."
WITH_LOGS=0
ARCHIVE_LOGS=0
MAKE_ARCHIVE=1
ENV_TYPE=""        # prod | test | mixed ("" = not stated)
PROD_RE=""         # extended regex of namespaces that are production
TEST_RE=""         # extended regex of namespaces that are test/dev
ASK=1
EXO_CLUSTER=""; EXO_ZONE=""; EXO_ACCOUNT=""; EXO_GROUP="sks-health-check"; EXO_TTL=3600
PRINT_SETUP=""     # "", "sa" or "group"
SETUP_KC=""        # file to write the read-only kubeconfig to (--setup-kubeconfig)
TOKEN_DURATION="24h"
ERRF=""
EXO_KC=""          # temporary kubeconfig made with the exo CLI (removed on exit)
TAB=$'\t'

# Thresholds (percent unless noted); override from the environment, e.g. HC_MEM_REQ_HIGH=85
MEM_REQ_HIGH="${HC_MEM_REQ_HIGH:-90}"    # node memory requests / allocatable
MEM_REQ_MED="${HC_MEM_REQ_MED:-80}"
MEM_LIMIT_MED="${HC_MEM_LIMIT_MED:-150}" # node memory limits / allocatable (over-commit)
MEM_LIVE_HIGH="${HC_MEM_LIVE_HIGH:-85}"  # live node memory use (kubectl top)
MEM_LIVE_MED="${HC_MEM_LIVE_MED:-70}"
RESTARTS_MED="${HC_RESTARTS_MED:-5}"     # container restarts worth mentioning
MEM_LIMIT_HIGH="${HC_MEM_LIMIT_HIGH:-200}" # over-commit that counts as HIGH risk when the node is also fairly full
OOM_HIGH="${HC_OOM_HIGH:-10}"            # OOMKilled containers in one namespace

cleanup() {
  [ -n "${ERRF:-}" ] && [ "$ERRF" != /dev/null ] && rm -f "$ERRF"
  [ -n "${EXO_KC:-}" ] && rm -f "$EXO_KC" "$EXO_KC.err"
  return 0
}

usage() {
  cat <<'EOF'
Usage: sks-health-check.sh [options]

  -k, --kubeconfig FILE   kubeconfig to use (default: $KUBECONFIG or ~/.kube/config)
  -c, --context NAME      kubeconfig context to use (default: current context)
  -o, --output-dir DIR    where to create the result folder (default: current directory)
      --with-logs         also save the last 50 log lines of containers that restarted
                          (OFF by default: logs can contain secrets and personal data)
      --archive-logs      put those logs into the .tar.gz as well (default: they stay out)
      --no-archive        do not create the .tar.gz next to the result folder
      --env TYPE          what kind of cluster this is: prod, test or mixed (changes how strictly
                          resilience findings such as single replicas or missing PDBs are rated)
      --prod-ns REGEX     namespaces that are production, e.g. '^(shop|billing)'
      --test-ns REGEX     namespaces that are test/dev, e.g. '(test|dev|staging)'
      --exo-cluster NAME  Exoscale only: make a short-lived kubeconfig with the `exo` CLI for this SKS
                          cluster (needs --exo-zone). It is deleted when the script ends.
      --exo-zone ZONE     zone of that cluster, e.g. ch-gva-2
      --exo-account NAME  exo account to use (exo -A NAME)
      --exo-group GROUP   RBAC group put into the certificate (default: sks-health-check; that group
                          must be bound to the read-only roles, see the doc). system:masters = full
                          admin and is only accepted if you ask for it explicitly.
      --exo-ttl SECONDS   lifetime of the certificate (default 3600)
      --print-setup       print the YAML for the read-only access (role + ServiceAccount + bindings)
                          and exit. Apply it with:  ./sks-health-check.sh --print-setup | kubectl apply -f -
                          Remove it again with:    ./sks-health-check.sh --print-setup | kubectl delete -f -
      --print-setup-group same, but bind the group used by --exo-cluster (default sks-health-check)
      --setup-kubeconfig [FILE]
                          after --print-setup was applied: build a kubeconfig (default
                          health-check.kubeconfig) with a short-lived token for that ServiceAccount, from
                          the current admin kubeconfig, and exit. Needs cluster-admin; run once.
      --token-duration D  token lifetime for --setup-kubeconfig (default 24h)
      --no-prompt         never ask questions (the script also never asks when not run in a terminal)
  -h, --help              show this help

The script is read-only. Result: sks-health-check-<cluster>-<date>-<time>-<pid>/summary.txt
Thresholds can be changed with HC_* environment variables (see the top of the script).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -k|--kubeconfig) KUBECONFIG_FILE="${2:?missing value for $1}"; shift 2 ;;
    -c|--context) KCONTEXT="${2:?missing value for $1}"; shift 2 ;;
    -o|--output-dir) OUT_BASE="${2:?missing value for $1}"; shift 2 ;;
    --with-logs) WITH_LOGS=1; shift ;;
    --archive-logs) ARCHIVE_LOGS=1; shift ;;
    --no-archive) MAKE_ARCHIVE=0; shift ;;
    --env) ENV_TYPE="${2:?missing value for $1}"; shift 2 ;;
    --prod-ns) PROD_RE="${2:?missing value for $1}"; shift 2 ;;
    --test-ns) TEST_RE="${2:?missing value for $1}"; shift 2 ;;
    --no-prompt) ASK=0; shift ;;
    --print-setup) PRINT_SETUP="sa"; shift ;;
    --print-setup-group) PRINT_SETUP="group"; shift ;;
    --setup-kubeconfig)
      if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then SETUP_KC="$2"; shift 2; else SETUP_KC="health-check.kubeconfig"; shift; fi ;;
    --token-duration) TOKEN_DURATION="${2:?missing value for $1}"; shift 2 ;;
    --exo-cluster) EXO_CLUSTER="${2:?missing value for $1}"; shift 2 ;;
    --exo-zone) EXO_ZONE="${2:?missing value for $1}"; shift 2 ;;
    --exo-account) EXO_ACCOUNT="${2:?missing value for $1}"; shift 2 ;;
    --exo-group) EXO_GROUP="${2:?missing value for $1}"; shift 2 ;;
    --exo-ttl) EXO_TTL="${2:?missing value for $1}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- read-only access setup (prints YAML; applying it is the cluster admin's own action)
setup_yaml() {
  cat <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sks-health-check-extra
  labels: {app.kubernetes.io/managed-by: sks-health-check}
rules:
- apiGroups: [""]
  resources: [nodes, persistentvolumes]
  verbs: [get, list]
- apiGroups: [metrics.k8s.io]
  resources: [nodes, pods]
  verbs: [get, list]
- apiGroups: [storage.k8s.io]
  resources: [storageclasses, volumeattachments, csidrivers]
  verbs: [get, list]
- apiGroups: [certificates.k8s.io]
  resources: [certificatesigningrequests]
  verbs: [get, list]
- apiGroups: [karpenter.sh]
  resources: [nodepools, nodeclaims]
  verbs: [get, list]
- apiGroups: [karpenter.exoscale.com]
  resources: [exoscalenodeclasses]
  verbs: [get, list]
- apiGroups: [scheduling.k8s.io]
  resources: [priorityclasses]
  verbs: [get, list]
- apiGroups: [longhorn.io]
  resources: [volumes, nodes, replicas, sharemanagers, settings]
  verbs: [get, list]
- nonResourceURLs: [/metrics]
  verbs: [get]
YAML
  if [ "$PRINT_SETUP" = "group" ]; then
    cat <<YAML
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sks-health-check-view
  labels: {app.kubernetes.io/managed-by: sks-health-check}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: view}
subjects: [{apiGroup: rbac.authorization.k8s.io, kind: Group, name: ${EXO_GROUP}}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sks-health-check-extra
  labels: {app.kubernetes.io/managed-by: sks-health-check}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: sks-health-check-extra}
subjects: [{apiGroup: rbac.authorization.k8s.io, kind: Group, name: ${EXO_GROUP}}]
YAML
  else
    cat <<'YAML'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: health-check
  namespace: kube-system
  labels: {app.kubernetes.io/managed-by: sks-health-check}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: health-check-view
  labels: {app.kubernetes.io/managed-by: sks-health-check}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: view}
subjects: [{kind: ServiceAccount, name: health-check, namespace: kube-system}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: health-check-extra
  labels: {app.kubernetes.io/managed-by: sks-health-check}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: sks-health-check-extra}
subjects: [{kind: ServiceAccount, name: health-check, namespace: kube-system}]
YAML
  fi
}
ENV_TYPE="$(printf '%s' "$ENV_TYPE" | tr '[:upper:]' '[:lower:]')"
case "$ENV_TYPE" in ""|prod|test|mixed) ;; *) echo "--env must be prod, test or mixed" >&2; exit 2 ;; esac

for v in MEM_REQ_HIGH MEM_REQ_MED MEM_LIMIT_MED MEM_LIMIT_HIGH MEM_LIVE_HIGH MEM_LIVE_MED RESTARTS_MED OOM_HIGH; do
  case "${!v}" in ''|*[!0-9]*) echo "HC_$v must be a whole number (got: ${!v})" >&2; exit 2 ;; esac
done
for re in "$PROD_RE" "$TEST_RE"; do
  [ -n "$re" ] || continue
  printf '' | grep -E -- "$re" >/dev/null 2>&1
  [ $? -le 1 ] || { echo "Invalid regular expression (extended regex expected): $re" >&2; exit 2; }
  printf 'x\n' | RE="$re" awk '{ if ($0 ~ ENVIRON["RE"]) n++ }' >/dev/null 2>&1 \
    || { echo "This awk cannot use the regular expression (use plain POSIX extended syntax): $re" >&2; exit 2; }
done
case "$EXO_GROUP" in ''|*[!A-Za-z0-9:._-]*) echo "Invalid --exo-group: $EXO_GROUP" >&2; exit 2 ;; esac
case "$EXO_TTL" in ''|*[!0-9]*) echo "--exo-ttl must be a number of seconds" >&2; exit 2 ;; esac
[ "$EXO_TTL" -ge 60 ] && [ "$EXO_TTL" -le 14400 ] || { echo "--exo-ttl must be between 60 and 14400 seconds (a certificate cannot be revoked)" >&2; exit 2; }
case "$EXO_GROUP" in
  system:masters) ;;
  system:*) echo "Refusing --exo-group $EXO_GROUP (built-in groups would give access to everybody in that group)" >&2; exit 2 ;;
esac
[ "$PRINT_SETUP" = group ] && [ "$EXO_GROUP" = system:masters ] && { echo "Refusing to bind system:masters" >&2; exit 2; }
if [ -n "$PRINT_SETUP" ]; then setup_yaml; exit 0; fi

for c in kubectl awk sed sort tar mktemp tr cut paste grep head wc date fold uniq dirname basename; do
  command -v "$c" >/dev/null 2>&1 || { echo "Required tool not found in PATH: $c" >&2; exit 2; }
done

# Optional: let the Exoscale CLI issue a short-lived client certificate instead of a kubeconfig file
if [ -n "$EXO_CLUSTER" ]; then
  [ -n "$EXO_ZONE" ] || { echo "--exo-cluster needs --exo-zone" >&2; exit 2; }
  case "$EXO_TTL" in ''|*[!0-9]*) echo "--exo-ttl must be a number of seconds" >&2; exit 2 ;; esac
  command -v exo >/dev/null 2>&1 || { echo "exo CLI not found in PATH (needed for --exo-cluster)" >&2; exit 2; }
  EXO_KC="$(mktemp)" || exit 1
  trap cleanup EXIT
  EXO_ARGS=()
  [ -n "$EXO_ACCOUNT" ] && EXO_ARGS+=(-A "$EXO_ACCOUNT")
  if ! exo "${EXO_ARGS[@]+"${EXO_ARGS[@]}"}" compute sks kubeconfig "$EXO_CLUSTER" sks-health-check -z "$EXO_ZONE" \
        --group "$EXO_GROUP" --ttl "$EXO_TTL" > "$EXO_KC" 2> "$EXO_KC.err" || [ ! -s "$EXO_KC" ]; then
    echo "Could not get a kubeconfig from the exo CLI:" >&2; cat "$EXO_KC.err" >&2; rm -f "$EXO_KC.err"; exit 1
  fi
  rm -f "$EXO_KC.err"
  KUBECONFIG_FILE="$EXO_KC"
  if [ "$EXO_GROUP" = "system:masters" ]; then
    echo "WARNING: the certificate belongs to system:masters (full cluster admin) for $EXO_TTL s." >&2
    echo "         The script only reads, but prefer the read-only group (see sks-health-check.md)." >&2
  fi
  echo "Note: the certificate stays valid for $EXO_TTL s even after this script deletes its local copy (it cannot be revoked)." >&2
fi

KUBE_ARGS=(--request-timeout=60s)
[ -n "$KUBECONFIG_FILE" ] && KUBE_ARGS+=(--kubeconfig "$KUBECONFIG_FILE")
[ -n "$KCONTEXT" ] && KUBE_ARGS+=(--context "$KCONTEXT")

# ---- build a read-only kubeconfig. This is the ONLY part of the script that does not go through K():
# it needs admin once, reads the cluster CA and asks the API server for a short-lived token for the
# health-check ServiceAccount. The token never appears on a command line (printf is a shell builtin).
if [ -n "$SETUP_KC" ]; then
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found in PATH" >&2; exit 2; }
  command -v base64 >/dev/null 2>&1 || { echo "base64 not found in PATH" >&2; exit 2; }
  [ ! -e "$SETUP_KC" ] || { echo "$SETUP_KC already exists; remove it or choose another name" >&2; exit 2; }
  SA_LABEL="$(kubectl "${KUBE_ARGS[@]}" -n kube-system get serviceaccount health-check -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" \
    || { echo "ServiceAccount health-check not found. First run:  $0 --print-setup | kubectl apply -f -" >&2; exit 1; }
  [ "$SA_LABEL" = "sks-health-check" ] \
    || { echo "The ServiceAccount kube-system/health-check was not created by this script (label missing). Refusing to mint a token for it." >&2; exit 1; }
  for v in "create pods" "get secrets" "delete nodes" "create clusterrolebindings"; do
    # shellcheck disable=SC2086
    if [ "$(kubectl "${KUBE_ARGS[@]}" auth can-i $v --all-namespaces --as=system:serviceaccount:kube-system:health-check 2>/dev/null)" = "yes" ]; then
      echo "The health-check ServiceAccount is allowed to '$v' - it is not read-only. Refusing." >&2; exit 1
    fi
  done
  SRV="$(kubectl "${KUBE_ARGS[@]}" config view --minify -o 'jsonpath={.clusters[0].cluster.server}')"
  [ -n "$SRV" ] || { echo "No server URL found in your kubeconfig" >&2; exit 1; }
  CAD="$(kubectl "${KUBE_ARGS[@]}" config view --minify --raw --flatten -o 'jsonpath={.clusters[0].cluster.certificate-authority-data}')"
  [ -n "$CAD" ] || { echo "Could not find the cluster CA in your kubeconfig" >&2; exit 1; }
  TOK="$(kubectl "${KUBE_ARGS[@]}" -n kube-system create token health-check --duration="$TOKEN_DURATION")" \
    || { echo "Could not create a token (needs cluster-admin)" >&2; exit 1; }
  ( umask 077
    printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: sks\n  cluster:\n    server: %s\n    certificate-authority-data: %s\ncontexts:\n- name: sks\n  context:\n    cluster: sks\n    user: health-check\ncurrent-context: sks\nusers:\n- name: health-check\n  user:\n    token: %s\n' "$SRV" "$CAD" "$TOK" > "$SETUP_KC" ) \
    || { rm -f "$SETUP_KC"; echo "Could not write $SETUP_KC" >&2; exit 1; }
  unset TOK
  if ! KUBECONFIG="$SETUP_KC" kubectl auth can-i get pods --all-namespaces >/dev/null 2>&1; then
    rm -f "$SETUP_KC"; echo "The new kubeconfig does not work (could not read pods); removed it." >&2; exit 1
  fi
  echo "Wrote $SETUP_KC (token requested for $TOKEN_DURATION - the API server may shorten that; read-only). Treat it like a password."
  echo "Now run:    $0 -k $SETUP_KC"
  echo "When done:  $0 --print-setup | kubectl delete -f -    and delete $SETUP_KC"
  exit 0
fi

# EVERY other kubectl call goes through K(). Only read-only verbs are allowed, and Secrets /
# ConfigMaps are refused by resource name, so even a bug or a later edit cannot change the cluster
# or read secrets.
K() {
  case "${1:-}:${2:-}" in
    get:*|describe:*|top:*|logs:*|version:*|auth:can-i|config:current-context) ;;
    *) echo "BUG: refusing kubectl call: ${1:-} ${2:-}" >&2; return 99 ;;
  esac
  local a lc skip=0 verb="$1"
  if [ "$verb" != logs ]; then   # the target of 'logs' is a pod name, which may legitimately contain "secrets"
    for a in "$@"; do
      if [ "$skip" -eq 1 ]; then skip=0; continue; fi
      case "$a" in
        -n|--namespace|-c|--container|-o|--output|-l|--selector|--field-selector|--sort-by|--tail|--context|--kubeconfig|-L|--label-columns|--as|--as-group) skip=1; continue ;;
        --*=*|-o=*|*jsonpath=*|*go-template=*|*custom-columns=*) continue ;;
      esac
      lc="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"
      case "$lc" in
        *secret*|*configmap*|cm|cm,*|*,cm|*,cm,*|cm/*)
          echo "BUG: refusing to touch secrets/configmaps" >&2; return 99 ;;
      esac
    done
  fi
  case "$*" in
    *--raw*) [ "$*" = "get --raw /metrics" ] || { echo "BUG: refusing --raw call" >&2; return 99; } ;;
  esac
  kubectl "${KUBE_ARGS[@]}" "$@"
}

CTX="${KCONTEXT:-$(K config current-context 2>/dev/null || echo unknown)}"
[ -n "$EXO_CLUSTER" ] && CTX="$EXO_CLUSTER"
SAFE_CTX="$(printf '%s' "$CTX" | tr -c 'A-Za-z0-9._-' '_')"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$OUT_BASE" && OUT_BASE="$(cd "$OUT_BASE" && pwd)" || exit 1
OUT="${OUT_BASE%/}/sks-health-check-${SAFE_CTX}-${STAMP}"
mkdir -p "$OUT"/{nodes,pods,events,storage,cluster,longhorn,meta} || exit 1
ERRF=""
trap cleanup EXIT
trap 'echo "Interrupted - the result folder is incomplete: $OUT" >&2; exit 130' INT TERM

FINDINGS="$OUT/meta/findings.tsv"   # LEVEL<TAB>text   (HIGH | MED | INFO)
SKIPPED="$OUT/meta/skipped.tsv"     # what could not be read, and why
: > "$FINDINGS"; : > "$SKIPPED"

say() { printf '%s\n' "$*" >&2; }
finding() { printf '%s\t%s\n' "$1" "$2" >> "$FINDINGS"; }
skip() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SKIPPED"; }

# collect <file relative to $OUT> <kubectl args...>
# Writes stdout to the file. On failure (no permission, resource type not installed...)
# the reason is recorded in meta/skipped.tsv, partial .tsv files are dropped, and the
# script carries on.
collect() {
  local file="$1"; shift
  local rc msg
  ERRF="$(mktemp 2>/dev/null)" || ERRF=/dev/null
  K "$@" > "$OUT/$file" 2> "$ERRF" < /dev/null
  rc=$?
  if [ $rc -ne 0 ]; then
    msg="$(grep -m1 -E '^(error|Error from server)' "$ERRF" 2>/dev/null || head -n 1 "$ERRF")"
    skip "$file" "kubectl $*" "$(printf '%s' "$msg" | cut -c1-220)"
    case "$file" in
      *.tsv) rm -f "$OUT/$file" ;;
      *) [ -s "$OUT/$file" ] || rm -f "$OUT/$file" ;;
    esac
  fi
  [ "$ERRF" = /dev/null ] || rm -f "$ERRF"
  return $rc
}

# like collect, but a resource type that does not exist (optional add-on not installed) is not an error
collect_opt() {
  local file="$1"; shift
  local rc
  ERRF="$(mktemp 2>/dev/null)" || ERRF=/dev/null
  K "$@" > "$OUT/$file" 2> "$ERRF" < /dev/null
  rc=$?
  if [ $rc -ne 0 ]; then
    if ! grep -q -E "have a resource type|could not find the requested resource|NotFound" "$ERRF" 2>/dev/null; then
      skip "$file" "kubectl $*" "$(grep -m1 -E '^(error|Error from server)' "$ERRF" 2>/dev/null | cut -c1-220)"
    fi
    rm -f "$OUT/$file"
  fi
  [ "$ERRF" = /dev/null ] || rm -f "$ERRF"
  return $rc
}

ok()   { [ -f "$OUT/$1" ]; }        # was collected (may legitimately be empty)
have() { [ -s "$OUT/$1" ]; }        # was collected and has content

# awk helper: Kubernetes quantity -> MiB
AWK_MIB='function mib(v,   n, u) {
  n = v + 0; u = v; sub(/^[0-9.]+/, "", u)
  if (u == "Ki") return n / 1024
  if (u == "Mi") return n
  if (u == "Gi") return n * 1024
  if (u == "Ti") return n * 1048576
  if (u == "Pi") return n * 1073741824
  if (u == "k" || u == "K") return n * 1000 / 1048576
  if (u == "M") return n * 1000000 / 1048576
  if (u == "G") return n * 1000000000 / 1048576
  if (u == "T") return n * 1000000000000 / 1048576
  if (u == "m") return n / 1000 / 1048576
  return n / 1048576
}'

iso_epoch() {   # 2026-10-28T11:57:19Z -> epoch seconds (GNU and BSD date)
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}
NOW_EPOCH="$(date -u +%s)"
CUTOFF_24H="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r $((NOW_EPOCH - 86400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -n "$CUTOFF_24H" ] || CUTOFF_24H="9999"   # unknown: nothing counts as recent
CUTOFF_10M="$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r $((NOW_EPOCH - 600)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -n "$CUTOFF_10M" ] || CUTOFF_10M="0000"   # unknown: nothing counts as old enough

# --------------------------------------------------------------------------------------
say "== SKS health check $VERSION  (context: $CTX)"
say "== Writing to $OUT"

if ! K version > "$OUT/meta/kubectl-version.txt" 2> "$OUT/meta/connect-error.txt"; then
  say "Cannot talk to the cluster:"; cat "$OUT/meta/connect-error.txt" >&2
  say "Check the kubeconfig / network and run again."; rm -rf "$OUT"; exit 1
fi
SERVER_VERSION="$(grep -i 'server version' "$OUT/meta/kubectl-version.txt" | head -n 1 | grep -o 'v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -n 1)"

{
  echo "script_version: $VERSION"
  echo "run_at_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "context: $CTX"
  echo "with_logs: $WITH_LOGS"
  [ -n "$EXO_CLUSTER" ] && echo "credential: exo CLI client certificate, group $EXO_GROUP, ttl ${EXO_TTL}s"
  echo "kubectl calls are limited to: get, describe, top, logs, version, auth can-i"
} > "$OUT/meta/run-info.txt"

# What am I allowed to read? (auth can-i is a read-only question to the API server)
{
  for r in nodes pods namespaces events persistentvolumes persistentvolumeclaims storageclasses \
           resourcequotas limitranges poddisruptionbudgets priorityclasses \
           nodes.metrics.k8s.io pods.metrics.k8s.io volumes.longhorn.io; do
    if K auth can-i list "$r" --all-namespaces >/dev/null 2>&1; then
      printf '%-28s yes\n' "$r"
    else
      printf '%-28s NO\n' "$r"
    fi
  done
} > "$OUT/meta/permissions.txt"

# ---------------------------------------------------------------- cluster ---------------
say "-- cluster"
collect cluster/version.txt version
collect cluster/namespaces.txt get namespaces -o wide --show-labels
collect cluster/resourcequotas.txt get resourcequotas -A
collect cluster/limitranges.txt get limitranges -A
collect cluster/limitranges-detail.txt describe limitranges -A
collect cluster/poddisruptionbudgets.txt get poddisruptionbudgets -A
collect cluster/priorityclasses.txt get priorityclasses
collect cluster/workloads.txt get deployments,statefulsets,daemonsets,cronjobs -A
collect cluster/namespaces.tsv get namespaces -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}'
collect cluster/namespace-env.tsv get namespaces -o \
  'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.env}{"\t"}{.metadata.labels.environment}{"\n"}{end}'
collect cluster/limitranges.tsv get limitranges -A -o 'jsonpath={range .items[*]}{.metadata.namespace}{"\n"}{end}'
collect cluster/resourcequotas.tsv get resourcequotas -A -o 'jsonpath={range .items[*]}{.metadata.namespace}{"\n"}{end}'
# ns name minAvailable maxUnavailable disruptionsAllowed currentHealthy expectedPods
collect cluster/pdb.tsv get poddisruptionbudgets -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.minAvailable}{"\t"}{.spec.maxUnavailable}{"\t"}{.status.disruptionsAllowed}{"\t"}{.status.currentHealthy}{"\t"}{.status.expectedPods}{"\n"}{end}'
collect cluster/priorityclasses.tsv get priorityclasses -o \
  'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.value}{"\t"}{.globalDefault}{"\t"}{.preemptionPolicy}{"\n"}{end}'

# ---------------------------------------------------------------- exoscale ---------------
# Optional (only with --exo-cluster): what only the Exoscale API knows - plan, CNI, add-ons, nodepools.
EXO_OK=0; EXO_PLAN=""; EXO_CNI=""; EXO_ADDONS=""; EXO_AUTOUP=""; EXO_VERSION=""; EXO_STATE=""; EXO_KUBEPROXY=""
EXO() {   # read-only subset of the exo CLI
  case "${1:-} ${2:-} ${3:-} ${4:-}" in
    "compute sks show "*|"compute sks versions "*|"compute sks nodepool show"|"compute sks nodepool list") ;;
    *) echo "BUG: refusing exo call: $*" >&2; return 99 ;;
  esac
  exo "${EXO_ARGS[@]+"${EXO_ARGS[@]}"}" "$@"
}
if [ -n "$EXO_CLUSTER" ]; then
  say "-- exoscale cluster data"
  EXO_LINE="$(EXO compute sks show "$EXO_CLUSTER" -z "$EXO_ZONE" -O text --output-template '{{.ServiceLevel}}|{{.CNI}}|{{.AddOns}}|{{.AutoUpgrade}}|{{.Version}}|{{.State}}|{{.EnableKubeProxy}}' 2>/dev/null < /dev/null)"
  if [ -n "$EXO_LINE" ]; then
    IFS='|' read -r EXO_PLAN EXO_CNI EXO_ADDONS EXO_AUTOUP EXO_VERSION EXO_STATE EXO_KUBEPROXY <<< "$EXO_LINE"
    EXO_OK=1
    printf '%s\n' "$EXO_LINE" > "$OUT/meta/exo-cluster.txt"
    EXO compute sks versions -O text > "$OUT/meta/exo-versions.txt" 2>/dev/null < /dev/null
    : > "$OUT/meta/exo-nodepools.tsv"
    EXO compute sks nodepool list -z "$EXO_ZONE" -O text 2>/dev/null < /dev/null | awk -F'\t' -v c="$EXO_CLUSTER" '$3 == c { print $2 }' | while IFS= read -r npname; do
      EXO compute sks nodepool show "$EXO_CLUSTER" "$npname" -z "$EXO_ZONE" -O text --output-template '{{.ID}}|{{.Name}}|{{.InstancePoolID}}|{{.InstanceType}}|{{.DiskSize}}|{{.Size}}|{{.Version}}|{{.State}}' 2>/dev/null < /dev/null >> "$OUT/meta/exo-nodepools.tsv"
      echo >> "$OUT/meta/exo-nodepools.tsv"
    done
    awk 'NF' "$OUT/meta/exo-nodepools.tsv" > "$OUT/meta/.np" && mv "$OUT/meta/.np" "$OUT/meta/exo-nodepools.tsv"
  else
    skip meta/exo-cluster.txt "exo compute sks show" "could not read the cluster from the Exoscale API (account, zone or permission)"
  fi
fi

# ---------------------------------------------------------------- nodes -----------------
say "-- nodes"
collect nodes/nodes-wide.txt get nodes -o wide --show-labels
NODE_JSONPATH='{range .items[*]}{.metadata.name}{"\t"}'
NODE_JSONPATH+='{.status.conditions[?(@.type=="Ready")].status}{"\t"}'
NODE_JSONPATH+='{.status.conditions[?(@.type=="MemoryPressure")].status}{"\t"}'
NODE_JSONPATH+='{.status.conditions[?(@.type=="DiskPressure")].status}{"\t"}'
NODE_JSONPATH+='{.status.conditions[?(@.type=="PIDPressure")].status}{"\t"}'
NODE_JSONPATH+='{.metadata.labels.node\.kubernetes\.io/instance-type}{"\t"}'
NODE_JSONPATH+='{.metadata.labels.node\.exoscale\.net/nodepool-id}{"\t"}'
NODE_JSONPATH+='{.status.capacity.memory}{"\t"}{.status.allocatable.memory}{"\t"}'
NODE_JSONPATH+='{.status.allocatable.cpu}{"\t"}{.status.nodeInfo.kubeletVersion}{"\t"}'
NODE_JSONPATH+='{.status.nodeInfo.containerRuntimeVersion}{"\t"}{.status.nodeInfo.kernelVersion}{"\t"}'
NODE_JSONPATH+='{.spec.unschedulable}{"\t"}{.spec.taints[*].key}{"\t"}'
NODE_JSONPATH+='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}{"\t"}{.metadata.creationTimestamp}{"\t"}'
NODE_JSONPATH+='{.metadata.labels.karpenter\.sh/nodepool}{"\t"}{.metadata.labels.exoscale\.com/node-role}{"\t"}'
NODE_JSONPATH+='{.status.allocatable.pods}{"\t"}{.spec.providerID}{"\n"}{end}'
collect nodes/nodes.tsv get nodes -o "jsonpath=$NODE_JSONPATH"
if have nodes/nodes.tsv; then
  {
    printf 'NODE\tREADY\tMEMORY-PRESSURE\tDISK-PRESSURE\tPID-PRESSURE\tINSTANCE-TYPE\tNODEPOOL-ID\tCAPACITY-MEM\tALLOCATABLE-MEM\tALLOCATABLE-CPU\tKUBELET\tRUNTIME\tKERNEL\tCORDONED\tTAINTS\tREADY-SINCE\tCREATED\tKARPENTER-NODEPOOL\tNODE-ROLE\tMAX-PODS\tPROVIDER-ID\n'
    cat "$OUT/nodes/nodes.tsv"
  } > "$OUT/nodes/nodes-conditions.txt"
fi
# Node conditions with reasons/messages (kubelet's own words about why it is unhappy)
collect nodes/node-conditions-detail.txt get nodes -o \
  'jsonpath={range .items[*]}{"== "}{.metadata.name}{"\n"}{range .status.conditions[*]}{.type}{"="}{.status}{"  ("}{.reason}{") "}{.message}{"  since "}{.lastTransitionTime}{"\n"}{end}{end}'
collect nodes/describe-nodes.txt describe nodes
collect nodes/top-nodes.txt top nodes
collect nodes/top-nodes.tsv top nodes --no-headers

# allocatable vs requested/limited, parsed from "kubectl describe nodes"
# -> node  cpu_alloc  cpu_req  cpu_req%  cpu_lim%  mem_alloc_MiB  mem_req  mem_req%  mem_lim  mem_lim%
if have nodes/describe-nodes.txt; then
  awk "$AWK_MIB"'
    /^Name:/ { node = $2; sect = ""; seen[node] = 1 }
    /^Allocatable:/ { sect = "alloc"; next }
    /^Capacity:/ { sect = "cap"; next }
    /^Allocated resources:/ { sect = "res"; next }
    /^[A-Za-z]/ && !/^Allocatable:|^Allocated resources:|^Capacity:/ { if (sect != "") sect = "" }
    sect == "alloc" && $1 == "cpu:" { cpu_alloc[node] = $2 }
    sect == "alloc" && $1 == "memory:" { mem_alloc[node] = mib($2) }
    sect == "res" && $1 == "cpu" { c_req[node] = $2; c_reqp[node] = $3; c_limp[node] = $5 }
    sect == "res" && $1 == "memory" { m_req[node] = $2; m_reqp[node] = $3; m_lim[node] = $4; m_limp[node] = $5 }
    END {
      for (n in seen) {
        cr = c_reqp[n]; cl = c_limp[n]; mr = m_reqp[n]; ml = m_limp[n]
        gsub(/[()%]/, "", cr); gsub(/[()%]/, "", cl); gsub(/[()%]/, "", mr); gsub(/[()%]/, "", ml)
        printf "%s\t%s\t%s\t%s\t%s\t%.0f\t%s\t%s\t%s\t%s\n", n, cpu_alloc[n], c_req[n], cr, cl, mem_alloc[n], m_req[n], mr, m_lim[n], ml
      }
    }' "$OUT/nodes/describe-nodes.txt" | sort > "$OUT/nodes/node-resources.tsv"
  {
    printf 'NODE\tCPU-ALLOCATABLE\tCPU-REQUESTED\tCPU-REQ%%\tCPU-LIMIT%%\tMEM-ALLOCATABLE(MiB)\tMEM-REQUESTED\tMEM-REQ%%\tMEM-LIMITS\tMEM-LIMIT%%\n'
    cat "$OUT/nodes/node-resources.tsv"
  } > "$OUT/nodes/node-resources.txt"
fi

# ---------------------------------------------------------------- pods ------------------
say "-- pods"
collect pods/pods-wide.txt get pods -A -o wide
collect pods/top-pods.txt top pods -A --sort-by=memory
collect pods/top-pods-containers.txt top pods -A --containers --sort-by=memory
collect pods/top-pods.tsv top pods -A --no-headers

# one line per pod: ns name node phase reason qos priorityClass priorityValue ownerKind ownerName
#                   hostNetwork hostPID hostIPC created
collect pods/pods.tsv get pods -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\t"}{.status.reason}{"\t"}{.status.qosClass}{"\t"}{.spec.priorityClassName}{"\t"}{.spec.priority}{"\t"}{.metadata.ownerReferences[0].kind}{"\t"}{.metadata.ownerReferences[0].name}{"\t"}{.spec.hostNetwork}{"\t"}{.spec.hostPID}{"\t"}{.spec.hostIPC}{"\t"}{.metadata.creationTimestamp}{"\t"}{.status.podIP}{"\t"}{.spec.hostUsers}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}'

# Per-container data uses go-template, because jsonpath cannot reach the pod name from
# inside the container loop. row() joins template fragments with a tab.
T='{{"\t"}}'
row() { local s="" f; for f in "$@"; do s+="$f$T"; done; printf '%s' "${s%"$T"}"; }
opt() { printf '{{with %s}}{{.}}{{end}}' "$1"; }                 # value or empty
res() { printf '{{with .resources}}{{with .%s}}{{with .%s}}{{.}}{{end}}{{end}}{{end}}' "$1" "$2"; }
yes() { printf '{{with %s}}y{{end}}' "$1"; }                     # "y" when present
PODS_HEAD='{{range .items}}{{$ns := .metadata.namespace}}{{$p := .metadata.name}}'
NL='{{"\n"}}'

# ns pod container mem_request mem_limit cpu_request cpu_limit
collect pods/containers-spec.tsv get pods -A -o "go-template=${PODS_HEAD}{{range .spec.containers}}$(row '{{$ns}}' '{{$p}}' '{{.name}}' "$(res requests memory)" "$(res limits memory)" "$(res requests cpu)" "$(res limits cpu)")${NL}{{end}}{{end}}"
# ns pod container image pullPolicy readiness liveness startup privileged
collect pods/containers-extra.tsv get pods -A -o "go-template=${PODS_HEAD}{{range .spec.containers}}$(row '{{$ns}}' '{{$p}}' '{{.name}}' '{{.image}}' "$(opt .imagePullPolicy)" "$(yes .readinessProbe)" "$(yes .livenessProbe)" "$(yes .startupProbe)" '{{with .securityContext}}{{with .privileged}}{{.}}{{end}}{{end}}')${NL}{{end}}{{end}}"
# ns pod container restarts lastReason lastExit lastFinished waitingReason
STATUS_ROW="$(row '{{$ns}}' '{{$p}}' '{{.name}}' '{{.restartCount}}' '{{with .lastState.terminated}}{{.reason}}{{end}}' '{{with .lastState.terminated}}{{.exitCode}}{{end}}' '{{with .lastState.terminated}}{{.finishedAt}}{{end}}' '{{with .state.waiting}}{{.reason}}{{end}}' '{{with .state.terminated}}{{.reason}}{{end}}' '{{with .state.terminated}}{{.finishedAt}}{{end}}')"
collect pods/containers-status.tsv get pods -A -o "go-template=${PODS_HEAD}{{range .status.containerStatuses}}${STATUS_ROW}${NL}{{end}}{{end}}"
collect pods/containers-status-init.tsv get pods -A -o "go-template=${PODS_HEAD}{{range .status.initContainerStatuses}}${STATUS_ROW}${NL}{{end}}{{end}}"
[ -f "$OUT/pods/containers-status.tsv" ] && [ -f "$OUT/pods/containers-status-init.tsv" ] \
  && cat "$OUT/pods/containers-status-init.tsv" >> "$OUT/pods/containers-status.tsv"
rm -f "$OUT/pods/containers-status-init.tsv"
# ns pod volume kind detail   (memory-backed emptyDir and hostPath volumes)
collect pods/volumes-special.tsv get pods -A -o "go-template=${PODS_HEAD}{{range .spec.volumes}}{{\$v := .name}}{{with .emptyDir}}$(row '{{$ns}}' '{{$p}}' '{{$v}}' emptyDir "$(opt .medium)" "$(opt .sizeLimit)")${NL}{{end}}{{with .hostPath}}$(row '{{$ns}}' '{{$p}}' '{{$v}}' hostPath '{{.path}}' '')${NL}{{end}}{{end}}{{end}}"

# finished Job pods (Succeeded/Failed) hold no memory: leave them out of requests/limits statistics
if have pods/pods.tsv; then
  for f in containers-spec containers-extra; do
    [ -f "$OUT/pods/$f.tsv" ] || continue
    awk -F'\t' -v pf="$OUT/pods/pods.tsv" 'BEGIN { while ((getline l < pf) > 0) { split(l, q, "\t"); if (q[4] == "Succeeded" || q[4] == "Failed") done[q[1] "/" q[2]] = 1 } }
      !(($1 "/" $2) in done)' "$OUT/pods/$f.tsv" > "$OUT/pods/$f.tmp" && mv "$OUT/pods/$f.tmp" "$OUT/pods/$f.tsv"
  done
fi

if have pods/containers-status.tsv; then
  # OOMKilled per namespace. Kubernetes remembers only the LAST termination of each
  # container, so this is a lower bound. "recent" = finished in the last 24 hours.
  awk -F'\t' -v cut="$CUTOFF_24H" '$5 == "OOMKilled" || $9 == "OOMKilled" { n[$1]++; r[$1] += $4; t = ($9 == "OOMKilled" ? $10 : $7); if (t >= cut) rc[$1]++ }
       END { for (k in n) printf "%s\t%d\t%d\t%d\n", k, n[k], r[k], rc[k] }' \
    "$OUT/pods/containers-status.tsv" | sort -t"$TAB" -k2,2nr > "$OUT/pods/oomkilled-by-namespace.tsv"
  { printf 'NAMESPACE\tCONTAINERS-LAST-OOMKILLED\tRESTARTS-OF-THOSE-ANY-REASON\tOOMKILLED-IN-LAST-24H\n'; cat "$OUT/pods/oomkilled-by-namespace.tsv"; } > "$OUT/pods/oomkilled-by-namespace.txt"
  awk -F'\t' '$5 == "OOMKilled" || $9 == "OOMKilled" { print $1 "/" $2 " (" $3 ")  restarts=" $4 "  last=" ($9 == "OOMKilled" ? $10 : $7) }' \
    "$OUT/pods/containers-status.tsv" > "$OUT/pods/oomkilled-containers.txt"
  awk -F'\t' '$4 >= 3 { print $4 "\t" $1 "/" $2 " (" $3 ")\t" $5 "\t" $8 }' "$OUT/pods/containers-status.tsv" \
    | sort -nr > "$OUT/pods/restarts.tsv"
  { printf 'RESTARTS\tPOD (CONTAINER)\tLAST-END-REASON\tWAITING-REASON\n'; cat "$OUT/pods/restarts.tsv"; } > "$OUT/pods/restarts.txt"
fi

if have pods/containers-spec.tsv; then
  # containers without memory request / limit (empty column)
  awk -F'\t' '$4 == "" { print $1 "/" $2 " (" $3 ")" }' "$OUT/pods/containers-spec.tsv" > "$OUT/pods/no-memory-request.txt"
  awk -F'\t' '$5 == "" { print $1 "/" $2 " (" $3 ")" }' "$OUT/pods/containers-spec.tsv" > "$OUT/pods/no-memory-limit.txt"
  awk -F'\t' '$4 == "" { n[$1]++ } END { for (k in n) printf "%s\t%d\n", k, n[k] }' "$OUT/pods/containers-spec.tsv" \
    | sort -t"$TAB" -k2,2nr > "$OUT/pods/no-memory-request-by-namespace.tsv"
  { printf 'NAMESPACE\tCONTAINERS-WITHOUT-MEMORY-REQUEST\n'; cat "$OUT/pods/no-memory-request-by-namespace.tsv"; } > "$OUT/pods/no-memory-request-by-namespace.txt"
  awk -F'\t' '$7 != "" { print $1 "/" $2 " (" $3 ")  cpu-limit=" $7 }' "$OUT/pods/containers-spec.tsv" > "$OUT/pods/cpu-limits-set.txt"
fi

if have pods/pods.tsv; then
  { printf 'NAMESPACE\tPOD\tNODE\tPHASE\tREASON\tQOS\tPRIORITYCLASS\tPRIORITY\tOWNER-KIND\tOWNER\tHOSTNET\tHOSTPID\tHOSTIPC\tCREATED\tPOD-IP\tHOST-USERS\tDELETING-SINCE\n'; cat "$OUT/pods/pods.tsv"; } > "$OUT/pods/pods-qos-priority.txt"
  awk -F'\t' '{ q[$6]++ } END { for (k in q) printf "%s\t%d\n", (k == "" ? "unknown" : k), q[k] }' "$OUT/pods/pods.tsv" | sort > "$OUT/pods/qos-counts.tsv"
  awk -F'\t' '{ p = ($7 == "" ? "(none - default priority 0)" : $7); n[p]++ } END { for (k in n) printf "%s\t%d\n", k, n[k] }' \
    "$OUT/pods/pods.tsv" | sort -t"$TAB" -k2,2nr > "$OUT/pods/priorityclass-usage.tsv"
  awk -F'\t' '$6 == "BestEffort" { print $1 "/" $2 "  on " $3 }' "$OUT/pods/pods.tsv" > "$OUT/pods/besteffort-pods.txt"
  awk -F'\t' '$4 != "Running" && $4 != "Succeeded" { print $1 "/" $2 "  phase=" $4 " reason=" $5 "  on " $3 }' "$OUT/pods/pods.tsv" > "$OUT/pods/not-running.txt"
  # workload placement: replicas and distinct nodes per workload (ReplicaSet name minus hash)
  awk -F'\t' '$4 == "Running" && $9 != "" {
      w = $10; if ($9 == "ReplicaSet") sub(/-[a-z0-9]+$/, "", w)
      k = $1 "\t" $9 "\t" w; n[k]++
      nk = k "\t" $3; if (!(nk in s)) { s[nk] = 1; nodes[k]++ } }
    END { for (k in n) printf "%s\t%d\t%d\n", k, n[k], nodes[k] }' "$OUT/pods/pods.tsv" | sort > "$OUT/pods/workload-placement.tsv"
  { printf 'NAMESPACE\tOWNER-KIND\tWORKLOAD\tRUNNING-PODS\tDISTINCT-NODES\n'; cat "$OUT/pods/workload-placement.tsv"; } > "$OUT/pods/workload-placement.txt"
  awk -F'\t' '$9 == "" { print $1 "/" $2 }' "$OUT/pods/pods.tsv" > "$OUT/pods/bare-pods.txt"
fi

# --- per-pod memory: requests, limits and live use, joined (feeds the namespace table)
if have pods/containers-spec.tsv && have pods/pods.tsv; then
  awk "$AWK_MIB"'
    BEGIN { FS = "\t" }
    FILENAME == F1 { k = $1 "\t" $2; if (!(k in seen)) { seen[k] = 1; order[++n] = k }
                     req[k] += mib($4); if ($5 == "") nolim[k] = 1; else lim[k] += mib($5)
                     if ($4 == "") noreq[k]++; next }
    FILENAME == F2 { k = $1 "\t" $2; qos[k] = $6; node[k] = $3; owner[k] = $9; next }
    FILENAME == F3 { split($0, a, /[ \t]+/); k = a[1] "\t" a[2]; live[k] = mib(a[4]); has[k] = 1; next }
    END { for (i = 1; i <= n; i++) { k = order[i]
            printf "%s\t%s\t%s\t%.0f\t%.0f\t%d\t%d\t%s\t%s\n", k, node[k], qos[k], req[k], lim[k], nolim[k] + 0, noreq[k] + 0, (k in has ? sprintf("%.0f", live[k]) : ""), owner[k] } }
  ' F1="$OUT/pods/containers-spec.tsv" F2="$OUT/pods/pods.tsv" F3="${OUT}/pods/top-pods.tsv" \
    "$OUT/pods/containers-spec.tsv" "$OUT/pods/pods.tsv" "$( [ -f "$OUT/pods/top-pods.tsv" ] && echo "$OUT/pods/top-pods.tsv" || echo /dev/null )" \
    > "$OUT/pods/pod-memory.tsv"
  # cols: 1 ns 2 pod 3 node 4 qos 5 req_MiB 6 lim_MiB(sum of set limits) 7 any_container_without_limit
  #       8 containers_without_request 9 live_MiB 10 ownerKind
  { printf 'NAMESPACE\tPOD\tNODE\tQOS\tREQUEST-MiB\tLIMIT-MiB\tHAS-UNLIMITED-CONTAINER\tCONTAINERS-NO-REQUEST\tLIVE-MiB\tOWNER-KIND\n'; sort -t"$TAB" -k9,9nr "$OUT/pods/pod-memory.tsv"; } > "$OUT/pods/pod-memory.txt"
  # usage vs request / limit flags
  awk -F'\t' '
    { live = ($9 == "" ? -1 : $9 + 0); req = $5 + 0; lim = $6 + 0
      if (live < 0) next
      if (req > 0 && live > req * 1.2 && live - req > 32) print "OVER-REQUEST\t" $1 "/" $2 "\t" $5 "\t" $9 "\t" $6
      else if (req == 0 && live > 100 && $1 != "kube-system") print "NO-REQUEST-BIG\t" $1 "/" $2 "\t" $5 "\t" $9 "\t" $6
      if ($7 == 0 && lim > 0 && live >= lim * 0.95) print "NEAR-LIMIT\t" $1 "/" $2 "\t" $5 "\t" $9 "\t" $6
      if ($7 == 0 && req > 0 && lim / req > 4) print "BURST-RATIO\t" $1 "/" $2 "\t" $5 "\t" $9 "\t" $6 }
  ' "$OUT/pods/pod-memory.tsv" | sort > "$OUT/pods/pod-memory-flags.tsv"
  { printf 'FLAG\tPOD\tREQUEST-MiB\tLIVE-MiB\tLIMIT-MiB\n'; cat "$OUT/pods/pod-memory-flags.tsv"; } > "$OUT/pods/pod-memory-flags.txt"

  # per namespace: class (prod-like / test-like / other), pods, requests, limits, live use, QoS counts
  awk "$AWK_MIB"'
    function cls(name,   s) {
      s = "-" tolower(name) "-"; gsub(/[_.]/, "-", s)
      if (s ~ /-(prod|production|prd)-/) return "prod"
      if (s ~ /-(test|testing|dev|develop|development|staging|stage|stg|qa|uat|preview|sandbox|demo|tmp)-/) return "test"
      return "other"
    }
    BEGIN { FS = "\t" }
    FILENAME == E { c = cls($2); if (c == "other") c = cls($3); if (c != "other") force[$1] = c; next }
    { ns = $1; pods[ns]++; req[ns] += $5; lim[ns] += $6; if ($7 == 1) unl[ns]++
      if ($9 != "") live[ns] += $9
      if ($4 == "BestEffort") be[ns]++; else if ($4 == "Burstable") bu[ns]++; else if ($4 == "Guaranteed") gu[ns]++ }
    END { for (ns in pods) { c = (ns in force ? force[ns] : cls(ns))
            printf "%s\t%s\t%d\t%.0f\t%.0f\t%d\t%.0f\t%d\t%d\t%d\n", ns, c, pods[ns], req[ns], lim[ns], unl[ns], live[ns], be[ns], bu[ns], gu[ns] } }
  ' E="$OUT/cluster/namespace-env.tsv" "$( [ -f "$OUT/cluster/namespace-env.tsv" ] && echo "$OUT/cluster/namespace-env.tsv" || echo /dev/null )" "$OUT/pods/pod-memory.tsv" \
    | sort -t"$TAB" -k4,4nr > "$OUT/pods/namespace-memory.tsv"
  { printf 'NAMESPACE\tCLASS\tPODS\tREQUESTED-MiB\tLIMITS-MiB\tPODS-WITH-UNLIMITED-CONTAINER\tLIVE-MiB\tBESTEFFORT\tBURSTABLE\tGUARANTEED\n'; cat "$OUT/pods/namespace-memory.tsv"; } > "$OUT/pods/namespace-memory.txt"
fi

# Optional: recent logs of restarted containers (can contain secrets -> opt-in)
if [ "$WITH_LOGS" -eq 1 ] && have pods/restarts.tsv; then
  say "-- logs (opt-in, max 10 containers)"
  mkdir -p "$OUT/pods/logs"
  head -n 10 "$OUT/pods/restarts.tsv" | while IFS="$TAB" read -r _ target _; do
    ns="${target%%/*}"; rest="${target#*/}"; pod="${rest%% (*}"; ctr="${rest##*(}"; ctr="${ctr%)}"
    lf="pods/logs/${ns}__${pod}__${ctr}.log"
    if K logs -n "$ns" "$pod" -c "$ctr" --previous --tail=50 > "$OUT/$lf" 2>/dev/null < /dev/null; then :
    else collect "$lf" logs -n "$ns" "$pod" -c "$ctr" --tail=50; fi
  done
fi

# ---------------------------------------------------------------- workloads / pitfalls ---
say "-- workloads"
collect cluster/deployments.tsv get deployments -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}'
collect cluster/statefulsets.tsv get statefulsets -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}'
# ns name minReplicas maxReplicas currentReplicas ScalingActive-status
collect cluster/hpa.tsv get hpa -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.minReplicas}{"\t"}{.spec.maxReplicas}{"\t"}{.status.currentReplicas}{"\t"}{.status.conditions[?(@.type=="ScalingActive")].status}{"\n"}{end}'
# zero-replica ReplicaSets per owner
collect cluster/replicasets.tsv get replicasets -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.metadata.ownerReferences[0].name}{"\n"}{end}'
# ns name succeeded failed active ttlSecondsAfterFinished ownedByCronJob
collect cluster/jobs.tsv get jobs -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.succeeded}{"\t"}{.status.failed}{"\t"}{.status.active}{"\t"}{.spec.ttlSecondsAfterFinished}{"\t"}{.metadata.ownerReferences[0].kind}{"\n"}{end}'
# Services with a selector but no ready endpoint address
collect cluster/services.tsv get services -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.type}{"\t"}{.spec.selector}{"\t"}{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}{"\t"}{.metadata.annotations.service\.beta\.kubernetes\.io/exoscale-loadbalancer-service-instancepool-id}{"\t"}{.metadata.annotations.service\.beta\.kubernetes\.io/exoscale-loadbalancer-external}{"\n"}{end}'
collect cluster/endpoints.tsv get endpoints -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .subsets[*]}{.addresses[0].ip}{" "}{end}{"\n"}{end}'
# Deprecated APIs still being called (needs access to /metrics; usually admin only)
if K get --raw /metrics > "$OUT/cluster/.metrics" 2> /dev/null < /dev/null; then
  grep '^apiserver_requested_deprecated_apis' "$OUT/cluster/.metrics" > "$OUT/cluster/deprecated-apis.txt"
else
  skip cluster/deprecated-apis.txt "kubectl get --raw /metrics" "no permission to read API server metrics"
fi
rm -f "$OUT/cluster/.metrics"
# managed components and platform pieces
collect cluster/daemonsets.tsv get daemonsets -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.desiredNumberScheduled}{"\t"}{.status.numberReady}{"\n"}{end}'
collect_opt cluster/csidrivers.tsv get csidrivers -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}'
collect storage/storageclasses.tsv get storageclasses -o \
  'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.provisioner}{"\t"}{.volumeBindingMode}{"\t"}{.allowVolumeExpansion}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
# kubelet serving certificate requests (a Pending one for a long time = the cloud controller is not approving them)
collect_opt cluster/csr.tsv get certificatesigningrequests -o \
  'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.spec.signerName}{"\t"}{.metadata.creationTimestamp}{"\t"}{.status.conditions[0].type}{"\n"}{end}'
collect_opt cluster/autoscaler-image.txt get deployment cluster-autoscaler -n kube-system -o 'jsonpath={.spec.template.spec.containers[0].image}'
# Karpenter (optional add-on): present if its CRDs exist
KARPENTER=0
collect_opt cluster/karpenter-nodepools.tsv get nodepools.karpenter.sh -o \
  'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' && KARPENTER=1
if [ "$KARPENTER" -eq 1 ]; then
  collect_opt cluster/karpenter-nodeclaims.tsv get nodeclaims.karpenter.sh -o \
    'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.metadata.labels.karpenter\.sh/nodepool}{"\n"}{end}'
  collect_opt cluster/karpenter-nodeclasses.tsv get exoscalenodeclasses.karpenter.exoscale.com -o \
    'jsonpath={range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[*]}{.type}{"="}{.status}{"/"}{.reason}{";"}{end}{"\n"}{end}'
fi

# ---------------------------------------------------------------- events ----------------
say "-- events"
collect events/events-all.txt get events -A --sort-by=.lastTimestamp
collect events/events-warnings.txt get events -A --field-selector type=Warning --sort-by=.lastTimestamp
# ns type reason kind object count series.count lastTimestamp eventTime message
collect events/events.tsv get events -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.type}{"\t"}{.reason}{"\t"}{.involvedObject.kind}{"\t"}{.involvedObject.name}{"\t"}{.count}{"\t"}{.series.count}{"\t"}{.lastTimestamp}{"\t"}{.eventTime}{"\t"}{.message}{"\n"}{end}'

if have events/events.tsv; then
  # normalise: pick the best count and time (events.k8s.io style events have series.count /
  # eventTime), join message pieces, drop malformed lines (messages with embedded newlines)
  # -> ns type reason kind object count time message
  awk -F'\t' -v OFS='\t' '
    function num(x) { return (x ~ /^[0-9]+$/ && x + 0 > 0) ? x + 0 : 0 }
    NF >= 10 { msg = $10; for (i = 11; i <= NF; i++) msg = msg " " $i
               c = num($6); if (!c) c = num($7); if (!c) c = 1
               t = $8; if (t == "" || t == "null" || t == "<nil>") t = $9
               if (t == "null" || t == "<nil>") t = ""
               gsub(/\r/, " ", msg); print $1, $2, $3, $4, $5, c, t, msg }' "$OUT/events/events.tsv" > "$OUT/events/events.clean.tsv"
  # events grouped and counted by type / reason / kind
  awk -F'\t' '{ k = $2 "\t" $3 "\t" $4; n[k] += $6; o[k]++ }
              END { for (k in n) printf "%s\t%d\t%d\n", k, n[k], o[k] }' "$OUT/events/events.clean.tsv" \
    | sort -t"$TAB" -k4,4nr > "$OUT/events/events-by-reason-kind.tsv"
  { printf 'TYPE\tREASON\tKIND\tOCCURRENCES\tEVENT-OBJECTS\n'; cat "$OUT/events/events-by-reason-kind.tsv"; } > "$OUT/events/events-by-reason-kind.txt"
  # Warning messages: names/hashes replaced so similar messages group together
  awk -F'\t' '$2 == "Warning"' "$OUT/events/events.clean.tsv" > "$OUT/events/.warn.raw"
  cut -f1-7 "$OUT/events/.warn.raw" > "$OUT/events/.warn.meta"
  cut -f8- "$OUT/events/.warn.raw" \
    | LC_ALL=C sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<uid>/g; s/[0-9a-f]{20,}/<id>/g; s/-[a-z0-9]{8,10}-[a-z0-9]{5}([^a-z0-9-]|$)/-<hash>\1/g; s/-[a-z]*[0-9][a-z0-9]*([ "_:,)]|$)/-<id>\1/g; s/[0-9]+(\.[0-9]+)?(Mi|Ki|Gi|ms|s)/<n>\2/g' \
    | LC_ALL=C cut -c1-200 > "$OUT/events/.warn.msg"
  if [ "$(wc -l < "$OUT/events/.warn.meta")" -eq "$(wc -l < "$OUT/events/.warn.msg")" ]; then
    paste "$OUT/events/.warn.meta" "$OUT/events/.warn.msg" \
      | awk -F'\t' '{ k = $3 "\t" $8; n[k] += $6; if (!(k in ex)) ex[k] = $1 "/" $4 "/" $5 }
                    END { for (k in n) printf "%d\t%s\t%s\n", n[k], k, ex[k] }' \
      | sort -t"$TAB" -k1,1nr | head -n 40 > "$OUT/events/warning-top-messages.tsv"
    { printf 'OCCURRENCES\tREASON\tMESSAGE (names normalised)\tEXAMPLE (namespace/kind/name)\n'; cat "$OUT/events/warning-top-messages.tsv"; } > "$OUT/events/warning-top-messages.txt"
  else
    skip events/warning-top-messages.txt "message grouping" "text could not be processed (unusual characters)"
  fi
  rm -f "$OUT"/events/.warn.*
  # Warnings by namespace, and by workload (pod name minus hash, approximate)
  awk -F'\t' '$2 == "Warning" { n[$1] += $6 } END { for (k in n) printf "%s\t%d\n", k, n[k] }' "$OUT/events/events.clean.tsv" \
    | sort -t"$TAB" -k2,2nr > "$OUT/events/warnings-by-namespace.tsv"
  awk -F'\t' '$2 == "Warning" { w = $5
      if ($4 == "Pod") { sub(/-[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]+-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]$/, "", w)
                         if (w == $5) sub(/-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]$/, "", w) }
      k = $1 "\t" $4 "\t" w; n[k] += $6; if (!(($3 "|" k) in r)) { r[$3 "|" k] = 1; rs[k] = rs[k] (rs[k] == "" ? "" : ",") $3 } }
    END { for (k in n) printf "%s\t%d\t%s\n", k, n[k], rs[k] }' "$OUT/events/events.clean.tsv" \
    | sort -t"$TAB" -k4,4nr | head -n 25 > "$OUT/events/warnings-by-workload.tsv"
  { printf 'NAMESPACE\tKIND\tWORKLOAD (approx.)\tOCCURRENCES\tREASONS\n'; cat "$OUT/events/warnings-by-workload.tsv"; } > "$OUT/events/warnings-by-workload.txt"
  # time range the events cover (Kubernetes keeps events only about 1 hour by default)
  cut -f7 "$OUT/events/events.clean.tsv" | grep -v -E '^(null|<nil>)?$' | sort | sed -n '1p;$p' | uniq > "$OUT/events/time-range.txt"
fi

# ---------------------------------------------------------------- storage ---------------
say "-- storage"
collect storage/storageclasses.txt get storageclasses
collect storage/pv.txt get pv -o wide
collect storage/pvc.txt get pvc -A -o wide
collect storage/pv.tsv get pv -o \
  'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.spec.storageClassName}{"\t"}{.status.phase}{"\t"}{.spec.capacity.storage}{"\t"}{.spec.accessModes[0]}{"\t"}{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}{end}'
collect storage/pvc.tsv get pvc -A -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.storageClassName}{"\t"}{.status.phase}{"\t"}{.spec.resources.requests.storage}{"\t"}{.spec.accessModes[0]}{"\n"}{end}'
for f in pv pvc; do
  have "storage/$f.tsv" || continue
  if [ "$f" = pv ]; then sc=2; ph=3; am=5; else sc=3; ph=4; am=6; fi
  awk -F"\t" -v sc=$sc -v ph=$ph -v am=$am '{ s = ($sc == "" ? "(none)" : $sc); k = s "\t" $ph "\t" $am; n[k]++ }
       END { for (k in n) printf "%s\t%d\n", k, n[k] }' "$OUT/storage/$f.tsv" | sort > "$OUT/storage/$f-by-class-status.tsv"
  { printf 'STORAGECLASS\tSTATUS\tACCESSMODE\tCOUNT\n'; cat "$OUT/storage/$f-by-class-status.tsv"; } > "$OUT/storage/$f-by-class-status.txt"
done
collect storage/volumeattachments.txt get volumeattachments

# ---------------------------------------------------------------- longhorn --------------
LONGHORN=0
LH_ERR="$(K get namespace longhorn-system 2>&1 >/dev/null < /dev/null)"
LH_RC=$?
if [ $LH_RC -eq 0 ]; then
  LONGHORN=1
elif ! printf '%s' "$LH_ERR" | grep -q 'NotFound'; then
  skip longhorn/ "kubectl get namespace longhorn-system" "$(printf '%s' "$LH_ERR" | head -n 1 | cut -c1-200)"
fi
if [ "$LONGHORN" -eq 1 ]; then
  say "-- longhorn-system found"
  collect longhorn/pods.txt get pods -n longhorn-system -o wide
  collect longhorn/top-pods.txt top pods -n longhorn-system --containers --sort-by=memory
  collect longhorn/top-pods.tsv top pods -n longhorn-system --no-headers
  collect longhorn/pod-resources.txt get pods -n longhorn-system -o \
    'custom-columns=POD:.metadata.name,NODE:.spec.nodeName,QOS:.status.qosClass,MEM-REQ:.spec.containers[*].resources.requests.memory,MEM-LIMIT:.spec.containers[*].resources.limits.memory,RESTARTS:.status.containerStatuses[*].restartCount'
  collect longhorn/volumes.txt get volumes.longhorn.io -n longhorn-system -o \
    'custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,ACCESSMODE:.spec.accessMode,REPLICAS:.spec.numberOfReplicas,SIZE:.spec.size,NODE:.status.currentNodeID,PVC:.status.kubernetesStatus.pvcName,NAMESPACE:.status.kubernetesStatus.namespace'
  collect longhorn/volumes.tsv get volumes.longhorn.io -n longhorn-system -o \
    'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.status.state}{"\t"}{.status.robustness}{"\t"}{.spec.accessMode}{"\t"}{.spec.numberOfReplicas}{"\t"}{.status.kubernetesStatus.namespace}/{.status.kubernetesStatus.pvcName}{"\n"}{end}'
  collect longhorn/nodes.txt get nodes.longhorn.io -n longhorn-system -o \
    'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,SCHEDULABLE:.status.conditions[?(@.type=="Schedulable")].status'
  collect longhorn/sharemanagers.txt get sharemanagers.longhorn.io -n longhorn-system
  collect longhorn/replicas.txt get replicas.longhorn.io -n longhorn-system -o \
    'custom-columns=NAME:.metadata.name,STATE:.status.currentState,NODE:.spec.nodeID,VOLUME:.spec.volumeName'
  collect longhorn/settings.txt get settings.longhorn.io -n longhorn-system
fi

# ---------------------------------------------------------------- questions -------------
# Names only give a rough guess which namespaces are prod and which are test. When that guess
# found nothing and we run in a terminal, ask - but only then, and an empty answer is fine.
# Answers are written to meta/answers.txt and marked in the summary.
NS_CLASS="$OUT/meta/ns-class.tsv"; : > "$NS_CLASS"
INTERACTIVE=0; [ "$ASK" -eq 1 ] && [ -t 0 ] && [ -t 2 ] && INTERACTIVE=1
if [ "$INTERACTIVE" -eq 1 ] && [ -z "$ENV_TYPE" ]; then
  {
    echo
    echo "Quick questions make the result more accurate (press Enter to skip any of them)."
  } >&2
  printf 'Is this cluster mainly (p)roduction, (t)est/dev, or (m)ixed? [p/t/m/Enter=skip]: ' >&2
  read -r ans
  case "$ans" in
    p*|P*) ENV_TYPE="prod" ;;
    t*|T*) ENV_TYPE="test" ;;
    m*|M*) ENV_TYPE="mixed" ;;
    '') ;;
    *) echo "  (not understood, skipped)" >&2 ;;
  esac
fi
if have pods/namespace-memory.tsv; then
  guessed=$(awk -F'\t' '{ c[$2]++ } END { print (c["prod"] > 0 && c["test"] > 0) ? "yes" : "no" }' "$OUT/pods/namespace-memory.tsv")
  cands=$(awk -F'\t' '$1 !~ /^(kube-system|kube-public|kube-node-lease)$/ && ($7 >= 50 || $4 >= 128) { print $1 }' "$OUT/pods/namespace-memory.tsv")
  ncand=$(printf '%s\n' "$cands" | grep -c .)
  if [ "$INTERACTIVE" -eq 1 ] && [ -z "$PROD_RE$TEST_RE" ] && [ "$guessed" = no ] && [ "$ncand" -ge 3 ]; then
    awk -F'\t' '$1 !~ /^(kube-system|kube-public|kube-node-lease)$/ && ($7 >= 50 || $4 >= 128) { printf "%s\t%s\t%s\n", $1, $7, $4 }' "$OUT/pods/namespace-memory.tsv" \
      | sort -t"$TAB" -k2,2nr | head -n 12 > "$OUT/meta/.ask-list"
    nask=$(wc -l < "$OUT/meta/.ask-list" | tr -d ' ')
    {
      echo "These namespaces use the most memory:"
      awk -F'\t' '{ printf "  %2d) %-28s live %6s MiB   requested %6s MiB\n", NR, $1, $2, $3 }' "$OUT/meta/.ask-list"
    } >&2
    printf 'Which of them are PRODUCTION? (numbers or names, separated by space/comma, Enter=skip): ' >&2
    read -r prod_ans
    printf 'Which of them are TEST / DEV / STAGING? (same, Enter=skip): ' >&2
    read -r test_ans
    set -f   # no file-name expansion of what was typed
    for pair in "prod:$prod_ans" "test:$test_ans"; do
      cls="${pair%%:*}"; list="$(printf '%s' "${pair#*:}" | tr ',' ' ')"
      for tok in $list; do
        case "$tok" in
          *[!0-9]*) name="$tok" ;;
          *) if [ "$tok" -ge 1 ] && [ "$tok" -le "$nask" ]; then name="$(sed -n "${tok}p" "$OUT/meta/.ask-list" | cut -f1)"; else name=""; fi ;;
        esac
        if [ -z "$name" ] || ! grep -qxF -- "$name" "$OUT/cluster/namespaces.tsv" 2>/dev/null; then
          echo "  ignored (not a namespace of this cluster): $tok" >&2; continue
        fi
        if grep -q "^$(printf '%s' "$name" | sed 's/[.[\*^$]/\\&/g')	" "$NS_CLASS" 2>/dev/null; then
          echo "  $name was named twice; the later answer ($cls) is used" >&2
        fi
        printf '%s\t%s\n' "$name" "$cls" >> "$NS_CLASS"
      done
    done
    set +f
    {
      echo "Understood: production = $(awk -F'\t' '$2 == "prod" { printf "%s ", $1 }' "$NS_CLASS")"
      echo "            test/dev   = $(awk -F'\t' '$2 == "test" { printf "%s ", $1 }' "$NS_CLASS")"
    } >&2
    rm -f "$OUT/meta/.ask-list"
  fi
  # apply regex flags / answers on top of the name guess; column 11 = who decided
  if PRE="$PROD_RE" TRE="$TEST_RE" awk -F'\t' -v OFS='\t' -v f="$NS_CLASS" '
    BEGIN { pre = ENVIRON["PRE"]; tre = ENVIRON["TRE"]; while ((getline line < f) > 0) { split(line, a, "\t"); m[a[1]] = a[2] } }
    { src = ($2 == "other" ? "" : "guess")
      if ($1 in m) { $2 = m[$1]; src = "operator" }
      else if (pre != "" && $1 ~ pre) { $2 = "prod"; src = "operator" }
      else if (tre != "" && $1 ~ tre) { $2 = "test"; src = "operator" }
      print $0, src }' "$OUT/pods/namespace-memory.tsv" > "$OUT/pods/.nsm"; then mv "$OUT/pods/.nsm" "$OUT/pods/namespace-memory.tsv"
  else rm -f "$OUT/pods/.nsm"; say "WARNING: could not apply the prod/test classification"; fi
  { printf 'NAMESPACE\tCLASS\tPODS\tREQUESTED-MiB\tLIMITS-MiB\tPODS-WITH-UNLIMITED-CONTAINER\tLIVE-MiB\tBESTEFFORT\tBURSTABLE\tGUARANTEED\tCLASS-SET-BY\n'; cat "$OUT/pods/namespace-memory.tsv"; } > "$OUT/pods/namespace-memory.txt"
fi
{
  echo "cluster_type: ${ENV_TYPE:-not stated}"
  echo "prod_ns_regex: ${PROD_RE:-}"
  echo "test_ns_regex: ${TEST_RE:-}"
  echo "namespaces marked by the operator:"; cat "$NS_CLASS"
} > "$OUT/meta/answers.txt"

# Resilience findings are rated by cluster type: a missing PDB or single replica matters on
# prod and is noise on a test cluster.
res_level() {   # $1 = default level
  case "$ENV_TYPE:$1" in
    prod:INFO) echo MED ;;
    test:MED)  echo INFO ;;
    *)         echo "$1" ;;
  esac
}

# ======================================================================================
# Analysis -> findings
# ======================================================================================
say "-- analysing"

# ---- nodes
if ok nodes/nodes.tsv && [ ! -s "$OUT/nodes/nodes.tsv" ]; then
  if [ "$KARPENTER" -eq 1 ]; then
    finding INFO "The cluster has no worker nodes right now. Karpenter is installed and scales to zero, so this is expected until a pod needs capacity."
  else
    finding HIGH "The cluster has NO worker nodes. Nothing can run: every pod stays Pending (FailedScheduling)."
  fi
fi
if have nodes/nodes.tsv; then
  awk -F'\t' '
    $2 != "True" { printf "HIGH\tNode %s is NOT Ready (status: %s). Pods on it are unreachable or being moved.\n", $1, ($2 == "" ? "unknown" : $2) }
    $3 == "True" { printf "HIGH\tNode %s reports MemoryPressure: it is running out of memory and the kubelet starts evicting pods.\n", $1 }
    $4 == "True" { printf "HIGH\tNode %s reports DiskPressure: its disk is nearly full, the kubelet starts evicting pods and deleting images.\n", $1 }
    $5 == "True" { printf "HIGH\tNode %s reports PIDPressure: too many processes.\n", $1 }
    $14 == "true" && $18 == "" { printf "MED\tNode %s is cordoned (SchedulingDisabled): it is Ready but takes no new pods, so its memory is not usable.\n", $1 }
    $15 ~ /node\.kubernetes\.io\/(unreachable|not-ready|memory-pressure|disk-pressure|pid-pressure)|node\.cloudprovider\.kubernetes\.io\/uninitialized/ { printf "MED\tNode %s carries a problem taint (%s): Kubernetes itself marked the node as unhealthy.\n", $1, $15 }
  ' "$OUT/nodes/nodes.tsv" >> "$FINDINGS"
  n_nodes=$(wc -l < "$OUT/nodes/nodes.tsv" | tr -d ' ')
  types=$(cut -f6 "$OUT/nodes/nodes.tsv" | sed 's/^$/unknown/' | sort | uniq -c | awk '{ printf "%s x %s, ", $1, $2 }' | sed 's/, $//')
  finding INFO "The cluster has $n_nodes node(s); instance types: ${types:-unknown}."
  # nodes that were NotReady / restarted: Ready status changed long after the node was created
  awk -F'\t' '$2 == "True" && $18 == "" { print $1 "|" $16 "|" $17 }' "$OUT/nodes/nodes.tsv" | while IFS='|' read -r name rsince created; do
    [ -n "$rsince" ] && [ -n "$created" ] || continue
    re=$(iso_epoch "$rsince"); ce=$(iso_epoch "$created")
    [ -n "$re" ] && [ -n "$ce" ] || continue
    if [ $((re - ce)) -gt 900 ]; then
      ago=$(( (NOW_EPOCH - re) / 3600 ))
      lvl=INFO; [ "$ago" -lt 24 ] && lvl=MED
      finding "$lvl" "Node $name became Ready again ${ago} h ago, long after it was created: it was NotReady or restarted since (the cause is in nodes/node-conditions-detail.txt and the kubelet/containerd logs on the node)."
    fi
  done
  # memory reserved for the system = capacity - allocatable (SKS nodes reserve a flat 500 MiB)
  awk "$AWK_MIB"'BEGIN { FS = "\t" } { cap = mib($8); al = mib($9); if (cap > 0 && al > 0 && cap - al < 400)
       printf "MED\t[mem] Node %s: only %.0f MiB of its memory is reserved for the system (kubelet, containerd, OS); SKS nodes normally reserve about 500 MiB. The node itself can run out of memory more easily.\n", $1, cap - al }' \
    "$OUT/nodes/nodes.tsv" >> "$FINDINGS"
  # kubelet versions: patch differences are normal after an upgrade, minor differences are not
  nver=$(cut -f11 "$OUT/nodes/nodes.tsv" | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/' | sort -u | grep -c .)
  [ "$nver" -gt 1 ] && finding INFO "Nodes run $nver different kubelet minor versions ($(cut -f11 "$OUT/nodes/nodes.tsv" | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/' | sort -u | tr '\n' ' ')): a nodepool upgrade is half done. SKS upgrades one minor version at a time and nodepools must be replaced after each step."
  smin=$(printf '%s' "$SERVER_VERSION" | sed -E 's/^v?[0-9]+\.([0-9]+).*/\1/')
  case "$smin" in ''|*[!0-9]*) ;; *)
    cut -f1,11 "$OUT/nodes/nodes.tsv" | awk -F'\t' -v s="$smin" '{ split($2, v, "."); m = v[2] + 0
      if (m > s) printf "MED\tNode %s runs kubelet %s, NEWER than the control plane (not supported).\n", $1, $2
      else if (s - m >= 2) printf "MED\tNode %s runs kubelet %s, %d minor versions behind the control plane. SKS expects nodepools to be replaced after every minor upgrade; this one is overdue and outside the supported skew soon.\n", $1, $2, s - m }' >> "$FINDINGS" ;;
  esac
fi

# Per-node memory risk: combines what pods may use (limits), what is reserved (requests) and
# what is used now. Lots of over-commit alone is "elevated"; over-commit on a node that is
# already full is a real OOM risk.
if have nodes/node-resources.tsv; then
  PM="/dev/null"; [ -f "$OUT/pods/pod-memory.tsv" ] && PM="$OUT/pods/pod-memory.tsv"
  TN="/dev/null"; [ -f "$OUT/nodes/top-nodes.tsv" ] && TN="$OUT/nodes/top-nodes.tsv"
  # node-risk.tsv: node requests% limits% live% risk reason unlimited-pods
  awk -F'\t' -v OFS='\t' -v top="$TN" -v pm="$PM" -v rh="$MEM_REQ_HIGH" -v rm="$MEM_REQ_MED" \
      -v lh="$MEM_LIVE_HIGH" -v lm="$MEM_LIVE_MED" -v lim="$MEM_LIMIT_MED" -v lhi="$MEM_LIMIT_HIGH" '
    BEGIN {
      while ((getline line < top) > 0) { split(line, a, /[ \t]+/); p = a[5]; gsub(/%/, "", p); if (a[5] !~ /unknown/ && p != "") live[a[1]] = p + 0 }
      # pods without a memory limit per node (outside kube-system): count and live MiB
      while ((getline line < pm) > 0) { split(line, b, "\t"); if (b[7] == 1 && b[1] != "kube-system") { unl[b[3]]++; unlmib[b[3]] += b[9] + 0 } }
    }
    { if ($8 == "" || $6 + 0 == 0) { print $1, "", "", ($1 in live ? live[$1] : ""), "UNKNOWN", "could not read this node'"'"'s requests/limits", 0; next }
      req = $8 + 0; lmt = $10 + 0; has = ($1 in live); lv = (has ? live[$1] : -1)
      risk = "OK"; why = ""
      ushare = ($6 > 0 ? unlmib[$1] / $6 * 100 : 0)
      if ((lmt > lim && (req >= 40 || lv >= 40)) || req >= rm || lv >= lm || ushare >= 10) { risk = "ELEVATED"
        why = (lmt > lim ? "limits " lmt "%; " : "") (req >= rm ? "requests " req "%; " : "") (lv >= lm ? "live use " lv "%; " : "") (ushare >= 10 ? unl[$1] " pods without a memory limit use " sprintf("%.0f", unlmib[$1]) " MiB; " : "") }
      if (lv >= lh || req >= rh || (lmt >= lhi && (req >= rm || lv >= lm))) { risk = "HIGH"
        why = (lv >= lh ? "live use " lv "%; " : "") (req >= rh ? "requests " req "%; " : "") (lmt >= lhi && (req >= rm || lv >= lm) ? "limits " lmt "% on an already fairly full node; " : "") }
      sub(/; $/, "", why)
      print $1, req, lmt, (has ? lv : ""), risk, why, unl[$1] + 0 }' "$OUT/nodes/node-resources.tsv" > "$OUT/nodes/node-risk.tsv"
  { printf 'NODE\tREQUESTED-%%\tLIMITS-%%\tLIVE-%%\tMEMORY-RISK\tWHY\tPODS-WITHOUT-LIMIT\n'; cat "$OUT/nodes/node-risk.tsv"; } > "$OUT/nodes/node-risk.txt"
  awk -F'\t' '
    $5 == "OK" { if ($3 + 0 > 100) printf "INFO\t[mem] Node %s: memory limits add up to %s%% of the node memory (over-commit; normal up to a point).\n", $1, $3; next }
    $5 == "UNKNOWN" { printf "MED\t[mem] Node %s: its memory figures could not be read, so its OOM risk is unknown.\n", $1; next }
    { lvl = ($5 == "HIGH" ? "HIGH" : "MED")
      live = ($4 == "" ? "live use unknown" : $4 "% in use right now")
      printf "%s\t[mem] Node %s has %s risk of running out of memory (%s). Its pods may use up to %s%% of the node memory (limits), %s%% is reserved by requests, %s. If several pods peak together the Linux kernel kills processes - possibly kubelet or containerd, which takes the whole node offline. Fix: set limits closer to requests, add memory/nodes, or move workloads.\n", lvl, $1, ($5 == "HIGH" ? "a HIGH" : "an elevated"), $6, $3, $2, live }' \
    "$OUT/nodes/node-risk.tsv" >> "$FINDINGS"
  awk -F'\t' '{ if ($4 + 0 >= 90) printf "MED\tNode %s: CPU requests are %s%% of allocatable CPU.\n", $1, $4 }' "$OUT/nodes/node-resources.tsv" >> "$FINDINGS"
fi

if have nodes/top-nodes.tsv; then
  awk '$5 ~ /unknown/ { printf "MED\tNode %s: no live metrics available (<unknown>).\n", $1 }' "$OUT/nodes/top-nodes.tsv" >> "$FINDINGS"
fi

# ---- pods
if have pods/oomkilled-by-namespace.tsv; then
  awk -F'\t' -v oh="$OOM_HIGH" '{ lvl = ($2 >= oh || $4 > 0 ? "HIGH" : "MED")
                recent = ($4 > 0 ? sprintf(", %d of them within the last 24 h", $4) : ", none in the last 24 h")
                printf "%s\t[mem] %d container(s) in namespace %s were last stopped because they ran out of memory (OOMKilled)%s. Either their memory limit is too low, or the application uses more memory than expected. (Those containers restarted %d times in total, for any reason.)\n", lvl, $2, $1, recent, $3 }' \
    "$OUT/pods/oomkilled-by-namespace.tsv" >> "$FINDINGS"
fi
if have pods/containers-status.tsv; then
  crash=$(awk -F'\t' '$8 == "CrashLoopBackOff"' "$OUT/pods/containers-status.tsv" | wc -l | tr -d ' ')
  [ "$crash" -gt 0 ] && finding HIGH "$crash container(s) are in CrashLoopBackOff (start, crash, wait, start again)."
  pull=$(awk -F'\t' '$8 == "ImagePullBackOff" || $8 == "ErrImagePull"' "$OUT/pods/containers-status.tsv" | wc -l | tr -d ' ')
  [ "$pull" -gt 0 ] && finding HIGH "$pull container(s) cannot pull their image (ImagePullBackOff): wrong image name or tag, registry down, credentials missing, or rate limit."
  many=$(awk -F'\t' -v m="$RESTARTS_MED" '$4 >= m' "$OUT/pods/containers-status.tsv" | wc -l | tr -d ' ')
  if [ "$many" -gt 0 ] && have pods/restarts.tsv; then
    names=$(awk -F'\t' -v m="$RESTARTS_MED" '$1 >= m { printf "%s [%sx], ", $2, $1 }' "$OUT/pods/restarts.tsv" | cut -d, -f1-3 | sed 's/, *$//')
    finding MED "$many container(s) have restarted $RESTARTS_MED times or more, e.g. $names (see pods/restarts.txt)."
  fi
fi
if have pods/containers-spec.tsv; then
  total_c=$(wc -l < "$OUT/pods/containers-spec.tsv" | tr -d ' ')
  # kube-system holds SKS-managed components (calico, kube-proxy, ...): not the customer's to fix, so counted apart
  nreq=$(grep -vc '^kube-system/' "$OUT/pods/no-memory-request.txt")
  nlim=$(grep -vc '^kube-system/' "$OUT/pods/no-memory-limit.txt")
  nsys=$(grep -c '^kube-system/' "$OUT/pods/no-memory-request.txt")
  if [ "$nreq" -gt 0 ]; then
    top3=$(grep -v '^kube-system\b' "$OUT/pods/no-memory-request-by-namespace.tsv" | head -n 3 | awk -F'\t' '{ printf "%s (%s), ", $1, $2 }' | sed 's/, $//')
    finding MED "[mem] $nreq of $total_c containers (outside kube-system) have no memory request. The scheduler cannot place them sensibly and they are first in line when a node runs low. Most in: $top3."
  fi
  [ "$nlim" -gt 0 ] && finding MED "[mem] $nlim of $total_c containers (outside kube-system) have no memory limit. Each one can grow until the whole node is out of memory."
  [ "$nsys" -gt 0 ] && finding INFO "[mem] $nsys container(s) in kube-system (SKS-managed, for example calico-node and kube-proxy) have no memory request. That is how SKS ships them; it only means the scheduler does not see their memory (about 130 MiB per calico-node)."
  ncpu=$(awk -F'\t' -v pf="$OUT/pods/pods.tsv" 'BEGIN { while ((getline l < pf) > 0) { split(l, q, "\t"); qos[q[1] "/" q[2]] = q[6] } }
        $7 != "" && qos[$1 "/" $2] != "Guaranteed" { c++ } END { print c + 0 }' "$OUT/pods/containers-spec.tsv")
  [ "$ncpu" -gt 0 ] && finding INFO "$ncpu of $total_c containers have a CPU limit (and are not Guaranteed QoS). CPU limits can throttle an application (slow responses) even when the node is idle; many teams set only CPU requests. Throttling itself is not visible with kubectl."
fi
if have pods/qos-counts.tsv; then
  be=0; [ -f "$OUT/pods/besteffort-pods.txt" ] && be=$(grep -vc '^kube-system/' "$OUT/pods/besteffort-pods.txt")
  [ "${be:-0}" -gt 0 ] && finding MED "[mem] ${be} pod(s) are QoS class BestEffort (no requests or limits at all). They are killed first when memory is short, but also hide how much the node is really used."
  qos=$(awk -F'\t' '{ printf "%s=%s ", $1, $2 }' "$OUT/pods/qos-counts.tsv")
  finding INFO "Pods by QoS class: $qos"
fi
if have pods/priorityclass-usage.tsv; then
  custom=$(awk -F'\t' '$1 !~ /^system-/ && $1 !~ /^\(none/ { n++ } END { print n + 0 }' "$OUT/pods/priorityclass-usage.tsv")
  if [ "$custom" -eq 0 ]; then
    finding MED "[mem] No pod uses a custom PriorityClass, so Kubernetes cannot be told that production pods matter more than test pods. When a node runs low on memory, only QoS class and usage compared to the request decide who is stopped first."
  else
    finding INFO "Custom PriorityClasses in use: $(awk -F'\t' '$1 !~ /^system-/ && $1 !~ /^\(none/ { printf "%s (%s pods), ", $1, $2 }' "$OUT/pods/priorityclass-usage.tsv" | sed 's/, $//')"
  fi
fi
if have pods/not-running.txt; then
  nr=$(wc -l < "$OUT/pods/not-running.txt" | tr -d ' ')
  ev=$(grep -c 'reason=Evicted' "$OUT/pods/not-running.txt")
  evev=0; [ -f "$OUT/events/events-by-reason-kind.tsv" ] && evev=$(awk -F'\t' '$2 == "Evicted" { s += $4 } END { print s + 0 }' "$OUT/events/events-by-reason-kind.tsv")
  if [ "$ev" -gt 0 ] && [ "$evev" -gt 0 ]; then
    finding HIGH "[mem] $ev pod(s) are listed as Evicted and eviction events happened within the last hour: the kubelet removed pods because a node was short of memory or disk."
  elif [ "$ev" -gt 0 ]; then
    finding INFO "$ev old evicted pod(s) are still listed (no eviction in the last hour). They are leftovers of earlier memory or disk pressure; clean up with: kubectl delete pod --field-selector=status.phase=Failed -A"
  fi
  [ "$((nr - ev))" -gt 0 ] && finding MED "$((nr - ev)) pod(s) are neither Running nor Succeeded (Pending/Failed/Unknown) - see pods/not-running.txt."
fi
if have pods/bare-pods.txt; then
  nb=$(wc -l < "$OUT/pods/bare-pods.txt" | tr -d ' ')
  [ "$nb" -gt 0 ] && finding INFO "$nb pod(s) have no owner (no Deployment/StatefulSet/Job...): nobody recreates them if the node fails or they are evicted (e.g. $(head -n 3 "$OUT/pods/bare-pods.txt" | tr '\n' ' '))."
fi
if have pods/volumes-special.tsv; then
  nm=$(awk -F'\t' '$4 == "emptyDir" && $5 == "Memory"' "$OUT/pods/volumes-special.tsv" | wc -l | tr -d ' ')
  [ "$nm" -gt 0 ] && finding MED "[mem] $nm volume(s) are memory-backed emptyDir (tmpfs): their content counts as RAM of the pod and of the node, and can cause OOM kills (e.g. $(awk -F'\t' '$4 == "emptyDir" && $5 == "Memory" { print $1 "/" $2 }' "$OUT/pods/volumes-special.tsv" | head -n 3 | tr '\n' ' '))."
  nh=$(awk -F'\t' '$4 == "hostPath" && $1 != "kube-system"' "$OUT/pods/volumes-special.tsv" | wc -l | tr -d ' ')
  [ "$nh" -gt 0 ] && finding INFO "$nh hostPath volume(s) outside kube-system: the pod reads/writes files on the node itself (ties it to one node and widens the damage if it is compromised)."
fi
if have pods/containers-extra.tsv; then
  awk -F'\t' -v l="$(res_level INFO)" '
    { n = split($4, ip, "/"); last = ip[n] }
    $4 !~ /@/ && (last !~ /:/ || last ~ /:latest$/) { lat++; if (lat <= 3) lx = lx $1 "/" $2 " " }
    $1 != "kube-system" && $6 != "y" { norp++ }
    $1 != "kube-system" && $7 != "y" { nolp++ }
    $9 == "true" && $1 != "kube-system" { priv++; if (priv <= 3) px = px $1 "/" $2 " " }
    END {
      if (lat > 0) printf "MED\t%d container(s) use an image tagged :latest or with no tag, so the same manifest can run different code on different days (e.g. %s).\n", lat, lx
      if (norp > 0) printf l "\t%d container(s) outside kube-system have no readiness probe: traffic can reach them before they are ready.\n", norp
      if (nolp > 0) printf l "\t%d container(s) outside kube-system have no liveness probe: a hung process is never restarted.\n", nolp
      if (priv > 0) printf "MED\t%d privileged container(s) outside kube-system (e.g. %s): a compromise of the container is a compromise of the node.\n", priv, px
    }' "$OUT/pods/containers-extra.tsv" >> "$FINDINGS"
fi
if have pods/pods.tsv; then
  nhn=$(awk -F'\t' '($11 == "true" || $12 == "true" || $13 == "true") && $1 != "kube-system"' "$OUT/pods/pods.tsv" | wc -l | tr -d ' ')
  [ "$nhn" -gt 0 ] && finding INFO "$nhn pod(s) outside kube-system use the node's network/PID/IPC namespace (hostNetwork/hostPID/hostIPC)."
fi
# DaemonSet pods with no memory request: the scheduler thinks that memory is free
if have pods/pod-memory.tsv; then
  ds=$(awk -F'\t' '$10 == "DaemonSet" && $8 > 0 && $1 != "kube-system"' "$OUT/pods/pod-memory.tsv" | wc -l | tr -d ' ')
  [ "$ds" -gt 0 ] && finding MED "[mem] $ds DaemonSet pod(s) (one per node) have containers without a memory request, e.g. $(awk -F'\t' '$10 == "DaemonSet" && $8 > 0 && $1 != "kube-system" { print $2 }' "$OUT/pods/pod-memory.tsv" | head -n 3 | tr '\n' ' '): the memory they use is invisible to the scheduler."
fi

# usage compared to request/limit (who is evicted first, who is close to OOM)
if have pods/pod-memory-flags.tsv; then
  for fl in OVER-REQUEST NEAR-LIMIT NO-REQUEST-BIG BURST-RATIO; do
    cnt=$(awk -F'\t' -v f="$fl" '$1 == f' "$OUT/pods/pod-memory-flags.tsv" | wc -l | tr -d ' ')
    [ "$cnt" -gt 0 ] || continue
    ex=$(awk -F'\t' -v f="$fl" '$1 == f { print $2 " (use " $4 " MiB, request " $3 " MiB)" }' "$OUT/pods/pod-memory-flags.tsv" | head -n 3 | paste -sd';' - | sed 's/;/; /g')
    case "$fl" in
      OVER-REQUEST) finding MED "[mem] $cnt pod(s) use clearly more memory than they requested, e.g. $ex. Under node memory pressure these are stopped first, and the node is fuller than the requests suggest." ;;
      NEAR-LIMIT) finding MED "[mem] $cnt pod(s) use 95% or more of their memory limit right now, e.g. $ex. An OOM kill is possible soon (a single snapshot: caches and Java applications are often steady near their limit)." ;;
      NO-REQUEST-BIG) finding MED "[mem] $cnt pod(s) without a memory request already use over 100 MiB, e.g. $ex." ;;
      BURST-RATIO) finding INFO "[mem] $cnt pod(s) have a memory limit more than 4 times their request, e.g. $ex: they can burst far beyond what was reserved for them." ;;
    esac
  done
fi
# prod vs test namespaces
if have pods/namespace-memory.tsv; then
  FL="/dev/null"; [ -f "$OUT/pods/pod-memory-flags.tsv" ] && FL="$OUT/pods/pod-memory-flags.tsv"
  awk -F'\t' -v fl="$FL" -v env="$ENV_TYPE" '
    BEGIN { while ((getline line < fl) > 0) { split(line, a, "\t"); if (a[1] == "OVER-REQUEST" || a[1] == "NEAR-LIMIT") { split(a[2], b, "/"); hot[b[1]] = 1 } } }
    { tot_req += $4; tot_live += $7; c = $2; req[c] += $4; live[c] += $7; pods[c] += $3
      if ($11 == "operator") st[c] = 1
      nm[c] = nm[c] (nm[c] == "" ? "" : ", ") $1
      if (c == "prod") { be += $8; bu += $9; gu += $10; unk += $3 - $8 - $9 - $10; if ($1 in hot) prodhot = 1 } }
    END {
      if (!("prod" in pods) || !("test" in pods)) {
        print "INFO\t[mem] No prod/test split known: namespace names do not show it and it was not stated (run again with --prod-ns / --test-ns REGEX, or answer the questions in a terminal), so memory use per environment cannot be compared (see pods/namespace-memory.txt)."
        exit }
      printf "INFO\t[mem] Namespaces %s TEST/DEV (%s) hold %.0f%% of the requested memory and %.0f%% of the live pod memory; namespaces %s PROD (%s) hold %.0f%% and %.0f%%.\n", (st["test"] ? "marked as" : "that look like"), nm["test"], (tot_req ? req["test"] / tot_req * 100 : 0), (tot_live ? live["test"] / tot_live * 100 : 0), (st["prod"] ? "marked as" : "that look like"), nm["prod"], (tot_req ? req["prod"] / tot_req * 100 : 0), (tot_live ? live["prod"] / tot_live * 100 : 0)
      lvl = (be > 0 || prodhot) ? "MED" : "INFO"
      if (env == "test") lvl = "INFO"
      if (be + bu > 0) printf "%s\t[mem] In PROD namespaces only %d of %d pods are QoS Guaranteed (request = limit); %d are Burstable and %d BestEffort%s. Under node memory pressure a prod pod that uses more than it requested can be stopped before a test pod.\n", lvl, gu, be + bu + gu + unk, bu, be, (prodhot ? ", and some prod pods already use more than they requested or sit near their limit" : "")
    }' "$OUT/pods/namespace-memory.tsv" >> "$FINDINGS"
fi

# ---- workloads
if have pods/workload-placement.tsv && have nodes/nodes.tsv; then
  nn=$(wc -l < "$OUT/nodes/nodes.tsv" | tr -d ' ')
  if [ "$nn" -gt 1 ]; then
    awk -F'\t' -v l="$(res_level MED)" '$1 != "kube-system" && $4 >= 2 && $5 == 1 { c++; if (c <= 3) x = x $1 "/" $3 " (" $4 " pods) " }
                END { if (c > 0) printf l "\t%d workload(s) have several replicas but all on ONE node (e.g. %s): if that node fails, the service is down. Consider anti-affinity or topologySpreadConstraints.\n", c, x }' \
      "$OUT/pods/workload-placement.tsv" >> "$FINDINGS"
  fi
  awk -F'\t' -v l="$(res_level INFO)" '$1 != "kube-system" && $2 != "DaemonSet" && $2 != "Job" && $4 == 1 { c++; if (c <= 3) x = x $1 "/" $3 " " }
              END { if (c > 0) printf l "\t%d workload(s) run a single replica (e.g. %s): they are down during every node drain, upgrade or failure.\n", c, x }' \
    "$OUT/pods/workload-placement.tsv" >> "$FINDINGS"
fi
if have cluster/hpa.tsv; then
  awk -F'\t' '$6 == "False" { c++; if (c <= 3) x = x $1 "/" $2 " " }
              END { if (c > 0) printf "MED\t%d HorizontalPodAutoscaler(s) cannot compute their metric (ScalingActive=False, e.g. %s): autoscaling does nothing. Usual cause: pods without CPU/memory requests, or metrics-server problems.\n", c, x }' \
    "$OUT/cluster/hpa.tsv" >> "$FINDINGS"
fi
if have cluster/pdb.tsv; then
  awk -F'\t' '$5 == "0" && $7 + 0 > 0 { c++; if (c <= 3) x = x $1 "/" $2 " " }
              END { if (c > 0) printf "MED\t%d PodDisruptionBudget(s) currently allow ZERO disruptions (e.g. %s): a node drain or upgrade will hang on them.\n", c, x }' \
    "$OUT/cluster/pdb.tsv" >> "$FINDINGS"
fi
if [ -f "$OUT/cluster/pdb.tsv" ] && [ ! -s "$OUT/cluster/pdb.tsv" ]; then
  finding "$(res_level INFO)" "There are no PodDisruptionBudgets. Node drains/upgrades can take all replicas of a service down at once."
fi
if have cluster/replicasets.tsv; then
  awk -F'\t' '$3 == "0" { n[$1 "/" $4]++; tot++ } END { for (k in n) if (n[k] > 10) { c++; if (c <= 3) x = x k " (" n[k] ") " } if (c > 0) printf "INFO\t%d deployment(s) keep more than 10 old ReplicaSets (e.g. %s): set revisionHistoryLimit lower to reduce clutter.\n", c, x }' \
    "$OUT/cluster/replicasets.tsv" >> "$FINDINGS"
fi
if have cluster/jobs.tsv; then
  awk -F'\t' '($3 != "" || $4 != "") && $5 == "" && $6 == "" && $7 != "CronJob" { c++; if (c <= 3) x = x $1 "/" $2 " " }
              ($4 != "" && $4 != "0") { f++ }
              END { if (c > 0) printf "INFO\t%d finished Job(s) have no ttlSecondsAfterFinished and are not owned by a CronJob (e.g. %s): they pile up forever.\n", c, x
                    if (f > 0) printf "MED\t%d Job(s) report failed pods (Job pods that errored; see kubectl get jobs -A).\n", f }' \
    "$OUT/cluster/jobs.tsv" >> "$FINDINGS"
fi
if have cluster/services.tsv && ok cluster/endpoints.tsv; then
  awk -F'\t' -v ep="$OUT/cluster/endpoints.tsv" 'BEGIN { while ((getline l < ep) > 0) { split(l, e, "\t"); if (e[3] != "") ready[e[1] "/" e[2]] = 1 } }
              $3 != "ExternalName" && $4 != "" && !(($1 "/" $2) in ready) { c++; if (c <= 5) x = x $1 "/" $2 " " }
              END { if (c > 0) printf "MED\t%d Service(s) have a selector but NO ready endpoint (e.g. %s): connections to them fail. Selector typo, or pods that never become Ready.\n", c, x }' \
    "$OUT/cluster/services.tsv" >> "$FINDINGS"
fi
if have cluster/deprecated-apis.txt; then
  # lines look like: ...{group="g",removed_release="1.39",resource="r",subresource="",version="v1beta1"} 1
  dep=$(grep 'removed_release="[0-9]' "$OUT/cluster/deprecated-apis.txt" \
        | sed -E 's/.*group="([^"]*)",removed_release="([^"]*)",resource="([^"]*)",subresource="[^"]*",version="([^"]*)".*/\2 \3.\1 \4/' | sort -u)
  if [ -n "$dep" ]; then
    smin3=$(printf '%s' "$SERVER_VERSION" | sed -E 's/^v?[0-9]+\.([0-9]+).*/\1/')
    soon=$(printf '%s\n' "$dep" | awk -v s="$smin3" '{ split($1, v, "."); if (v[2] + 0 <= s + 1) c++ } END { print c + 0 }')
    lvl=INFO; [ "${soon:-0}" -gt 0 ] && lvl=MED
    finding "$lvl" "Deprecated API versions are still being called: $(printf '%s\n' "$dep" | awk '{ printf "%s %s (removed in %s), ", $2, $3, $1 }' | sed 's/, $//'). They stop working when the cluster reaches that Kubernetes version (callers can be your applications or SKS components); see cluster/deprecated-apis.txt."
  fi
fi

# ---- events
if have events/events-by-reason-kind.tsv; then
  nw=$(awk -F'\t' '$1 == "Warning" { s += $4 } END { print s + 0 }' "$OUT/events/events-by-reason-kind.tsv")
  top=$(awk -F'\t' '$1 == "Warning" { printf "%s on %s (%s), ", $2, $3, $4 }' "$OUT/events/events-by-reason-kind.tsv" | cut -d, -f1-3 | sed 's/, $//')
  [ "$nw" -gt 0 ] && finding INFO "$nw Warning event occurrences are currently recorded. Most frequent: $top. (Kubernetes keeps events for only about 1 hour after the last repeat, so this is a snapshot, not the history; counts include repeats since an event was first seen.)"
  if have events/warnings-by-workload.tsv; then
    w1=$(head -n 1 "$OUT/events/warnings-by-workload.tsv" | awk -F'\t' '{ printf "%s/%s %s (%s events, %s)", $1, $2, $3, $4, $5 }')
    [ -n "$w1" ] && [ "$nw" -gt 0 ] && finding INFO "The noisiest single workload is $w1; see events/warnings-by-workload.txt (fixing the top few removes most of the noise)."
  fi
  # one total per reason (a reason can appear under several kinds)
  kstart=$(awk -F'\t' '$4 == "Node" && $3 == "Starting" && $8 ~ /kubelet/ { s += $6 } END { print s + 0 }' "$OUT/events/events.clean.tsv")
  nnodes=0; [ -f "$OUT/nodes/nodes.tsv" ] && nnodes=$(wc -l < "$OUT/nodes/nodes.tsv" | tr -d ' ')
  awk -F'\t' -v kstart="$kstart" -v nnodes="$nnodes" '
    function say(lvl, txt) { printf "%s\t%s\n", lvl, txt }
    $1 == "Warning" || $2 == "NodeNotReady" || $2 == "NodeHasInsufficientMemory" || ($3 == "Node" && ($2 == "Starting" || $2 == "Rebooted")) { n[$2] += $4 }
    END {
      if (n["SystemOOM"])            say("HIGH", "[mem] Node out-of-memory events (SystemOOM): " n["SystemOOM"] "x. The Linux kernel killed processes because the NODE ran out of memory - this is how kubelet or containerd can die and a node goes offline.")
      if (n["OOMKilling"])           say("MED",  "[mem] Kernel OOM-kill events (OOMKilling): " n["OOMKilling"] "x.")
      if (n["EvictionThresholdMet"]) say("HIGH", "[mem] Node eviction threshold was reached " n["EvictionThresholdMet"] "x (kubelet started evicting pods because memory/disk was short).")
      if (n["Evicted"])              say("HIGH", "[mem] Pods were evicted: " n["Evicted"] "x.")
      if (n["NodeHasInsufficientMemory"]) say("HIGH", "[mem] NodeHasInsufficientMemory: " n["NodeHasInsufficientMemory"] "x - a node reported low memory.")
      if (n["NodeNotReady"])         say("HIGH", "NodeNotReady events: " n["NodeNotReady"] "x - a node went NotReady recently.")
      if (n["Rebooted"])             say("HIGH", "A node rebooted (event Rebooted): " n["Rebooted"] "x.")
      if (kstart > nnodes)           say("MED",  "The kubelet started " kstart "x in the last hour but there are only " nnodes " node(s): the kubelet restarted or crashed (nodes created in the last hour also produce one start each).")
      if (n["ContainerGCFailed"] || n["ImageGCFailed"] || n["FreeDiskSpaceFailed"]) say("MED", "The node could not free disk space (ContainerGCFailed/ImageGCFailed/FreeDiskSpaceFailed): " n["ContainerGCFailed"] + n["ImageGCFailed"] + n["FreeDiskSpaceFailed"] "x.")
      if (n["FailedScheduling"])     say("MED",  "FailedScheduling: " n["FailedScheduling"] "x - pods could not be placed on any node (see events/warning-top-messages.txt, often \"Insufficient memory\").")
      if (n["BackOff"])              say("MED",  "BackOff: " n["BackOff"] "x - containers keep crashing (or images cannot be pulled) and Kubernetes delays their restarts.")
      if (n["FailedMount"] || n["FailedAttachVolume"] || n["VolumeFailedDelete"]) say("MED", "Volume problems (FailedMount/FailedAttachVolume/VolumeFailedDelete): " n["FailedMount"] + n["FailedAttachVolume"] + n["VolumeFailedDelete"] "x - storage could not be attached, mounted or deleted.")
      if (n["Unhealthy"])            say("INFO", "Unhealthy: " n["Unhealthy"] "x failed readiness/liveness probes.")
    }' "$OUT/events/events-by-reason-kind.tsv" >> "$FINDINGS"
  # BackOff because of image pulls is a different problem from a crashing application
  if have events/events.clean.tsv; then
    ip=$(awk -F'\t' '$2 == "Warning" && $8 ~ /[Ii]mage/ && ($3 == "BackOff" || $3 == "Failed") { s += $6 } END { print s + 0 }' "$OUT/events/events.clean.tsv")
    [ "$ip" -gt 0 ] && finding MED "$ip image-pull failure event(s) (registry, credentials, wrong tag or rate limit) - these are not application crashes."
  fi
fi

# ---- platform checks (Exoscale SKS specifics, from the SKS documentation)
nn_all=0; have nodes/nodes.tsv && nn_all=$(wc -l < "$OUT/nodes/nodes.tsv" | tr -d ' ')
kn_all=0; have nodes/nodes.tsv && kn_all=$(awk -F'\t' '$18 != ""' "$OUT/nodes/nodes.tsv" | wc -l | tr -d ' ')

# add-ons that are normally enabled: unusual if missing, so a note (the "Metrics API" error is the clearest sign)
METRICS_MISSING=0
grep -q 'Metrics API not available' "$SKIPPED" 2>/dev/null && METRICS_MISSING=1
if [ "$EXO_OK" -eq 1 ] && ! printf '%s' "$EXO_ADDONS" | grep -q metrics-server; then METRICS_MISSING=1; fi
if [ "$METRICS_MISSING" -eq 1 ]; then
  lvl=INFO; have cluster/hpa.tsv && lvl=MED
  finding "$lvl" "[mem] The Kubernetes Metrics API is not available (no metrics-server). SKS clusters normally have the metrics-server add-on, so this is unusual. Without it, kubectl top, HorizontalPodAutoscalers and the live memory figures in this report do not work."
fi
CSI_KNOWN=0; CSI_PRESENT=0
if [ "$EXO_OK" -eq 1 ]; then CSI_KNOWN=1; printf '%s' "$EXO_ADDONS" | grep -q container-storage && CSI_PRESENT=1
elif ok cluster/csidrivers.tsv; then CSI_KNOWN=1; grep -qi exoscale "$OUT/cluster/csidrivers.tsv" && CSI_PRESENT=1
elif ok storage/storageclasses.tsv; then CSI_KNOWN=1; grep -qi exoscale "$OUT/storage/storageclasses.tsv" && CSI_PRESENT=1; fi
if [ "$CSI_KNOWN" -eq 1 ] && [ "$CSI_PRESENT" -eq 0 ]; then
  pend=0; have storage/pvc.tsv && pend=$(awk -F'\t' '$4 == "Pending"' "$OUT/storage/pvc.tsv" | wc -l | tr -d ' ')
  lvl=INFO; [ "$pend" -gt 0 ] && lvl=MED
  finding "$lvl" "No Exoscale CSI driver is installed. SKS clusters normally have the CSI add-on enabled so that volumes (PVCs) can be created on Exoscale block storage, so this is unusual$([ "$pend" -gt 0 ] && echo "; $pend PVC(s) are Pending and cannot be satisfied")."
fi

if have nodes/nodes.tsv; then
  if [ "$nn_all" -eq 1 ] && [ "$kn_all" -eq 0 ]; then
    finding MED "The cluster has only ONE worker node. SKS recommends at least two: with one node every upgrade, drain or failure takes all workloads down, and some components cannot be upgraded safely."
  fi
  # the cloud controller (runs on the SKS control plane) sets providerID and removes the "uninitialized" taint
  awk -F'\t' '$21 == "" && $18 == "" { c++; if (c <= 3) x = x $1 " " }
              END { if (c > 0) printf "MED\tThe cloud controller has not initialised %d node(s) (no providerID, e.g. %s): they were probably created before the controller was enabled. Move workloads to a new nodepool.\n", c, x }' "$OUT/nodes/nodes.tsv" >> "$FINDINGS"
  # taints that keep ordinary pods away: their memory is not available to everyone
  awk -F'\t' '$15 != "" && $15 !~ /node\.kubernetes\.io|node\.cloudprovider\.kubernetes\.io|karpenter\.sh/ { printf "INFO\tNode %s carries taints (%s): only pods that tolerate them run there, so its memory is not available to other workloads.\n", $1, $15 }' "$OUT/nodes/nodes.tsv" >> "$FINDINGS"
  # GPU nodes
  awk -F'\t' '$6 ~ /^gpu2/ { split($11, v, "."); m = v[2] + 0; if (m >= 33) { c++; x = x $1 " " } }
              END { if (c > 0) printf "MED\t%d node(s) use a gpu2 instance type with kubelet 1.33 or newer, which SKS does not support (%s).\n", c, x }' "$OUT/nodes/nodes.tsv" >> "$FINDINGS"
  # pods per node versus the kubelet limit
  if have pods/pods.tsv; then
    awk -F'\t' -v pf="$OUT/pods/pods.tsv" 'BEGIN { while ((getline l < pf) > 0) { split(l, q, "\t"); if (q[3] != "" && q[4] != "Succeeded" && q[4] != "Failed") cnt[q[3]]++ } }
      $20 + 0 > 0 && cnt[$1] >= $20 * 0.8 { printf "MED\tNode %s runs %d pods; its limit is %d. New pods will stay Pending (\"Too many pods\").\n", $1, cnt[$1], $20 }' "$OUT/nodes/nodes.tsv" >> "$FINDINGS"
  fi
  # user namespaces need kubelet 1.33+
  if have pods/pods.tsv; then
    nu=$(awk -F'\t' '$16 == "false"' "$OUT/pods/pods.tsv" | wc -l | tr -d ' ')
    old=$(awk -F'\t' '{ split($11, v, "."); if (v[2] + 0 < 33) c++ } END { print c + 0 }' "$OUT/nodes/nodes.tsv")
    [ "$nu" -gt 0 ] && [ "$old" -gt 0 ] && finding MED "$nu pod(s) ask for user namespaces (hostUsers: false), which needs kubelet 1.33 or newer, and $old node(s) are older."
  fi
fi

# pending kubelet certificate requests: the cloud controller approves them; Pending for long = it is not working
if ok cluster/csr.tsv; then
  awk -F'\t' -v cut="$CUTOFF_10M" '$4 == "" && $3 < cut { c++; if (c <= 3) x = x $1 " " }
    END { if (c > 0) printf "MED\t%d certificate signing request(s) have been Pending for over 10 minutes (e.g. %s). On SKS the cloud controller approves kubelet certificates; if it does not, kubectl logs/exec/top fail for those nodes.\n", c, x }' "$OUT/cluster/csr.tsv" >> "$FINDINGS"
fi

# Karpenter
if [ "$KARPENTER" -eq 1 ]; then
  finding INFO "Karpenter is installed ($kn_all of $nn_all node(s) are Karpenter nodes). Karpenter nodes are replaced regularly (expiry, drift, consolidation), so node restarts and young nodes are normal. They are not part of an Instance Pool, so they cannot be Network Load Balancer backends."
  if have cluster/karpenter-nodeclaims.tsv; then
    awk -F'\t' '$2 != "True" { c++; if (c <= 3) x = x $1 " " } END { if (c > 0) printf "MED\t%d Karpenter NodeClaim(s) are not Ready (e.g. %s): nodes were requested but did not join.\n", c, x }' "$OUT/cluster/karpenter-nodeclaims.tsv" >> "$FINDINGS"
  fi
  if have cluster/karpenter-nodepools.tsv; then
    awk -F'\t' '$2 != "True" { c++; if (c <= 3) x = x $1 " " } END { if (c > 0) printf "MED\t%d Karpenter NodePool(s) are not Ready (e.g. %s).\n", c, x }' "$OUT/cluster/karpenter-nodepools.tsv" >> "$FINDINGS"
  fi
  if have cluster/karpenter-nodeclasses.tsv; then
    awk -F'\t' '$2 ~ /=False/ { printf "MED\tKarpenter ExoscaleNodeClass %s has a failing condition: %s\n", $1, $2 }' "$OUT/cluster/karpenter-nodeclasses.tsv" >> "$FINDINGS"
  fi
  have cluster/autoscaler-image.txt && finding INFO "Both the Cluster Autoscaler and Karpenter are present. Running both can lead to over-provisioning; use one of them."
fi
if have cluster/autoscaler-image.txt; then
  amin=$(sed -E 's/.*:v?[0-9]+\.([0-9]+).*/\1/' "$OUT/cluster/autoscaler-image.txt")
  smin2=$(printf '%s' "$SERVER_VERSION" | sed -E 's/^v?[0-9]+\.([0-9]+).*/\1/')
  case "$amin$smin2" in *[!0-9]*|'') ;; *) [ "$amin" != "$smin2" ] && finding MED "The Cluster Autoscaler image ($(cat "$OUT/cluster/autoscaler-image.txt")) does not match the cluster version ($SERVER_VERSION). SKS asks for the autoscaler minor version to match the cluster." ;; esac
fi

# managed components in kube-system
if have cluster/deployments.tsv; then
  awk -F'\t' '$1 == "kube-system" && $2 ~ /^(coredns|konnectivity-agent|metrics-server|calico-kube-controllers|cilium-operator)$/ {
      want = $3 + 0; got = $4 + 0
      crit = ($2 == "coredns" || $2 == "konnectivity-agent")
      if (got < want || want == 0) printf "%s\tManaged component %s is not healthy: %d of %d replicas ready%s.\n", (crit ? "HIGH" : "MED"), $2, got, want, ($2 == "coredns" ? " - cluster DNS is affected" : ($2 == "konnectivity-agent" ? " - kubectl logs/exec/top and webhooks can fail" : ""))
    }' "$OUT/cluster/deployments.tsv" >> "$FINDINGS"
fi
if have cluster/daemonsets.tsv; then
  awk -F'\t' '$1 == "kube-system" && $2 ~ /^(calico-node|cilium|kube-proxy|exoscale-csi-node)$/ && $4 + 0 < $3 + 0 {
      printf "%s\tManaged component %s is not ready on every node (%d of %d).\n", ($2 ~ /calico|cilium/ ? "HIGH" : "MED"), $2, $4, $3 }' "$OUT/cluster/daemonsets.tsv" >> "$FINDINGS"
  if [ "$nn_all" -gt 0 ] && ! awk -F'\t' '$1 == "kube-system" && $2 ~ /^(calico-node|cilium)/ { f = 1 } END { exit !f }' "$OUT/cluster/daemonsets.tsv"; then
    finding MED "No CNI DaemonSet (calico-node or cilium) was found in kube-system, although the cluster has nodes: pod networking may not work."
  fi
  if [ "$EXO_OK" -eq 1 ] && [ "$EXO_KUBEPROXY" = "true" ] && ! awk -F'\t' '$1 == "kube-system" && $2 == "kube-proxy" { f = 1 } END { exit !f }' "$OUT/cluster/daemonsets.tsv"; then
    finding MED "kube-proxy is enabled for this cluster but no kube-proxy DaemonSet exists."
  fi
fi
if have pods/workload-placement.tsv && [ "$nn_all" -gt 1 ]; then
  awk -F'\t' '$1 == "kube-system" && ($3 == "coredns" || $3 == "konnectivity-agent") && $4 >= 2 && $5 == 1 { printf "MED\t%s runs %d replicas, all on the same node: when that node fails, %s.\n", $3, $4, ($3 == "coredns" ? "cluster DNS is down" : "kubectl logs/exec and webhooks fail") }' "$OUT/pods/workload-placement.tsv" >> "$FINDINGS"
fi
if have pods/pods.tsv; then
  awk -F'\t' '$2 ~ /cloud-controller/ { c++; x = $1 "/" $2 } END { if (c > 0) printf "INFO\tA cloud-controller pod runs inside the cluster (%s). On SKS the Exoscale cloud controller runs on the managed control plane; an extra one can conflict with it.\n", x }' "$OUT/pods/pods.tsv" >> "$FINDINGS"
  awk -F'\t' '$11 != "true" && $4 == "Running" && $15 != "" && $15 !~ /^192\.168\./ { c++; if (c <= 3) x = x $1 "/" $2 " " }
              END { if (c > 0) printf "INFO\t%d pod(s) have an IP outside the SKS pod range 192.168.0.0/16 (e.g. %s): a custom network setup, or a hostNetwork pod.\n", c, x }' "$OUT/pods/pods.tsv" >> "$FINDINGS"
  awk -F'\t' -v cut="$CUTOFF_10M" '$17 != "" && $17 < cut && $4 != "Succeeded" && $4 != "Failed" { c++; if (c <= 3) x = x $1 "/" $2 " " }
              END { if (c > 0) printf "MED\t%d pod(s) are stuck Terminating for over 10 minutes (e.g. %s): typically pods on a node that went NotReady, or a finalizer that never finishes.\n", c, x }' "$OUT/pods/pods.tsv" >> "$FINDINGS"
  awk -F'\t' '$5 ~ /Admission|SMTAlignment|^OutOf/ { c++; if (c <= 3) x = x $1 "/" $2 " (" $5 ") " }
              END { if (c > 0) printf "MED\t%d pod(s) were rejected by the kubelet (%s): the node ran out of CPU, memory or pods at the moment they were placed.\n", c, x }' "$OUT/pods/pods.tsv" >> "$FINDINGS"
fi
# LoadBalancer services
if have cluster/services.tsv; then
  awk -F'\t' '$3 == "LoadBalancer" && $5 == "" { c++; if (c <= 3) x = x $1 "/" $2 " " }
              END { if (c > 0) printf "MED\t%d LoadBalancer Service(s) have no external address yet (e.g. %s): the cloud controller did not create the load balancer (credentials? quota? the Service is new?).\n", c, x }' "$OUT/cluster/services.tsv" >> "$FINDINGS"
  awk -F'\t' '$3 == "LoadBalancer" && $7 == "true" { c++; x = $1 "/" $2 }
              END { if (c > 0) printf "INFO\t%d Service(s) use exoscale-loadbalancer-external (e.g. %s): that load balancer is never deleted automatically; remove it by hand after deleting the cluster or Service.\n", c, x }' "$OUT/cluster/services.tsv" >> "$FINDINGS"
  nlb=$(awk -F'\t' '$3 == "LoadBalancer"' "$OUT/cluster/services.tsv" | wc -l | tr -d ' ')
  if [ "$nlb" -gt 0 ] && [ "$nn_all" -gt 0 ]; then
    [ "$kn_all" -eq "$nn_all" ] && finding MED "$nlb LoadBalancer Service(s) exist but all nodes are Karpenter nodes. Karpenter nodes are not in an Instance Pool and cannot be Network Load Balancer backends."
    npu=$(cut -f7 "$OUT/nodes/nodes.tsv" | sort -u | grep -c .)
    if [ "$npu" -gt 1 ]; then
      awk -F'\t' '$3 == "LoadBalancer" && $6 == "" { c++; if (c <= 3) x = x $1 "/" $2 " " }
        END { if (c > 0) printf "INFO\t%d LoadBalancer Service(s) (e.g. %s) have no instancepool-id annotation although the nodes span several nodepools: an Exoscale Network Load Balancer routes to ONE Instance Pool only.\n", c, x }' "$OUT/cluster/services.tsv" >> "$FINDINGS"
    fi
  fi
fi
# ReadWriteMany on Exoscale block storage can never be satisfied
if have storage/pvc.tsv && have storage/storageclasses.tsv; then
  awk -F'\t' -v sc="$OUT/storage/storageclasses.tsv" 'BEGIN { while ((getline l < sc) > 0) { split(l, q, "\t"); prov[q[1]] = q[2] } }
    $6 == "ReadWriteMany" && prov[$3] ~ /exoscale/ { c++; if (c <= 3) x = x $1 "/" $2 " " }
    END { if (c > 0) printf "MED\t%d PVC(s) ask for ReadWriteMany on Exoscale block storage (e.g. %s). A block volume can be attached to one node only, so this can never work; use a different storage layer (for example Longhorn or an S3-based CSI) for RWX.\n", c, x }' "$OUT/storage/pvc.tsv" >> "$FINDINGS"
fi
# image-pull problems together with unhealthy managed components look like blocked egress
if have cluster/deployments.tsv; then
  pullfail=0
  [ -f "$OUT/pods/containers-status.tsv" ] && pullfail=$(awk -F'\t' '$8 == "ImagePullBackOff" || $8 == "ErrImagePull"' "$OUT/pods/containers-status.tsv" | wc -l | tr -d ' ')
  mgd=$(awk -F'\t' '$1 == "kube-system" && $2 ~ /^(konnectivity-agent|metrics-server)$/ && $4 + 0 < $3 + 0' "$OUT/cluster/deployments.tsv" | wc -l | tr -d ' ')
  if [ "$pullfail" -gt 0 ] && [ "$mgd" -gt 0 ]; then
    finding MED "Images cannot be pulled AND managed components (konnectivity-agent / metrics-server) are not ready. This combination is typical of blocked outgoing traffic: if the nodes use a restrictive security group or firewall, check the egress rules SKS needs (see the SKS 'egress security groups' page)."
  fi
fi
if have events/events.clean.tsv; then
  rl=$(awk -F'\t' 'tolower($8) ~ /toomanyrequests|rate limit/ { s += $6 } END { print s + 0 }' "$OUT/events/events.clean.tsv")
  [ "$rl" -gt 0 ] && finding MED "$rl event(s) mention registry rate limiting (toomanyrequests): pulls from a public registry are being throttled. Use an authenticated pull or a registry mirror."
fi

# ---- Exoscale API data (only with --exo-cluster)
if [ "$EXO_OK" -eq 1 ]; then
  finding INFO "Exoscale cluster data: plan $EXO_PLAN, CNI $EXO_CNI, Kubernetes $EXO_VERSION, add-ons $(printf '%s' "$EXO_ADDONS" | tr -d '[]'), automatic upgrade $EXO_AUTOUP."
  [ "$EXO_PLAN" = "starter" ] && finding INFO "The cluster is on the Starter plan: no SLA and a control plane that is not highly available. The SLA of the Pro plan covers the control plane only, not worker nodes or workloads."
  [ "$EXO_STATE" != "running" ] && finding HIGH "The Exoscale API reports the cluster state as '$EXO_STATE', not 'running'."
  [ "$EXO_AUTOUP" = "false" ] && finding INFO "Automatic control-plane upgrades are off: remember to upgrade by hand, one minor version at a time."
  if [ -s "$OUT/meta/exo-versions.txt" ] && [ -n "$EXO_VERSION" ]; then
    cmin=$(printf '%s' "$EXO_VERSION" | sed -E 's/^v?[0-9]+\.([0-9]+).*/\1/'); cpat=$(printf '%s' "$EXO_VERSION" | sed -E 's/^v?[0-9]+\.[0-9]+\.([0-9]+).*/\1/')
    newest=$(sed -E 's/^v?[0-9]+\.([0-9]+).*/\1/' "$OUT/meta/exo-versions.txt" | sort -n | tail -n 1)
    latest_same=$(grep -E "^v?[0-9]+\.${cmin}\." "$OUT/meta/exo-versions.txt" | sed -E 's/^v?[0-9]+\.[0-9]+\.([0-9]+).*/\1/' | sort -n | tail -n 1)
    case "$cmin$cpat$newest" in *[!0-9]*|'') ;; *)
      if [ -z "$latest_same" ]; then finding MED "Kubernetes $EXO_VERSION is no longer offered by SKS (supported minors end at 1.$newest): plan an upgrade."
      elif [ "$cpat" -lt "$latest_same" ]; then finding INFO "Kubernetes $EXO_VERSION is $((latest_same - cpat)) patch release(s) behind the latest 1.$cmin.$latest_same."; fi
      [ $((newest - cmin)) -ge 2 ] && finding MED "Kubernetes $EXO_VERSION is $((newest - cmin)) minor versions behind the newest SKS offers (1.$newest). SKS upgrades one minor version at a time and each step needs a nodepool replacement."
      ;; esac
  fi
  if [ -s "$OUT/meta/exo-nodepools.tsv" ]; then
    # nodepool size from the API versus nodes that exist (label node.exoscale.net/nodepool-id = SKS nodepool id)
    awk -F'|' -v nf="$OUT/nodes/nodes.tsv" 'BEGIN { while ((getline l < nf) > 0) { split(l, q, "\t"); have[q[7]]++ } }
      { if (($6 + 0) != have[$1] + 0 && $8 == "running") printf "MED\tNodepool %s should have %d node(s) but %d exist in the cluster (%s).\n", $2, $6, have[$1] + 0, "nodes still joining or failed to join" }
      { if ($5 + 0 > 0 && $5 + 0 < 30) printf "INFO\tNodepool %s uses a small disk (%d GB): images and logs can fill it quickly (DiskPressure).\n", $2, $5 }' "$OUT/meta/exo-nodepools.tsv" >> "$FINDINGS"
  fi
fi

# ---- cluster guard rails
if have cluster/namespaces.tsv; then
  user_ns=$(grep -v -E '^(kube-.*|default|.*-system|cert-manager|ingress-nginx|karpenter|monitoring-system)$' "$OUT/cluster/namespaces.tsv")
  nns=$(printf '%s\n' "$user_ns" | grep -c .)
  if [ "$nns" -gt 0 ] && ok cluster/limitranges.tsv && ok cluster/resourcequotas.tsv; then
    nolr=$(printf '%s\n' "$user_ns" | awk -v f="$OUT/cluster/limitranges.tsv" 'BEGIN { while ((getline l < f) > 0) have[l] = 1 } $1 != "" && !($1 in have)')
    noq=$(printf '%s\n' "$user_ns" | awk -v f="$OUT/cluster/resourcequotas.tsv" 'BEGIN { while ((getline l < f) > 0) have[l] = 1 } $1 != "" && !($1 in have)')
    cl=$(printf '%s\n' "$nolr" | grep -c .); cq=$(printf '%s\n' "$noq" | grep -c .)
    [ "$cl" -gt 0 ] && finding "$(res_level MED)" "$cl of $nns non-system namespaces have no LimitRange, so pods there can be created without any memory request/limit (e.g. $(printf '%s\n' "$nolr" | head -n 5 | tr '\n' ' '))."
    [ "$cq" -gt 0 ] && finding "$(res_level MED)" "$cq of $nns non-system namespaces have no ResourceQuota, so nothing stops one namespace (e.g. test) from using all memory (e.g. $(printf '%s\n' "$noq" | head -n 5 | tr '\n' ' '))."
  fi
fi

# ---- storage
if have storage/pvc.tsv; then
  bad=$(awk -F'\t' '$4 != "Bound"' "$OUT/storage/pvc.tsv" | wc -l | tr -d ' ')
  [ "$bad" -gt 0 ] && finding MED "$bad PersistentVolumeClaim(s) are not Bound (Pending/Lost). Pending is normal while the storage class waits for the first pod to use it; otherwise the pods using it cannot start."
fi
if have storage/pv.tsv; then
  rel=$(awk -F'\t' '$3 == "Released" || $3 == "Failed"' "$OUT/storage/pv.tsv" | wc -l | tr -d ' ')
  [ "$rel" -gt 0 ] && finding INFO "$rel PersistentVolume(s) are Released/Failed: leftover disks that may still cost money."
fi

# ---- longhorn
if [ "$LONGHORN" -eq 1 ]; then
  finding INFO "Longhorn is installed (namespace longhorn-system). It runs its own pods on every node and they use node memory/CPU."
  if have longhorn/top-pods.tsv && have nodes/node-resources.tsv; then
    lh_mib=$(awk "$AWK_MIB"'{ s += mib($3) } END { printf "%.0f", s }' "$OUT/longhorn/top-pods.tsv")
    tot_mib=$(awk -F'\t' '{ s += $6 } END { printf "%.0f", s }' "$OUT/nodes/node-resources.tsv")
    if [ "${tot_mib:-0}" -gt 0 ]; then
      pct=$((lh_mib * 100 / tot_mib))
      lvl=INFO; [ "$pct" -ge 15 ] && lvl=MED
      finding "$lvl" "[mem] Longhorn pods currently use about ${lh_mib} MiB of memory = ${pct}% of all allocatable node memory (${tot_mib} MiB)."
    fi
  fi
  if have longhorn/pods.txt; then
    sm=$(grep -c '^share-manager' "$OUT/longhorn/pods.txt")
    [ "$sm" -gt 0 ] && finding INFO "Longhorn runs $sm share-manager pod(s): one NFS server per ReadWriteMany volume, each using node memory. Many RWX volumes = many of these."
  fi
  if have longhorn/volumes.tsv; then
    awk -F'\t' '
      $3 == "faulted"  { printf "HIGH\tLonghorn volume %s (%s) is FAULTED: data not accessible.\n", $1, $6 }
      $3 == "degraded" { printf "MED\tLonghorn volume %s (%s) is degraded: fewer healthy replicas than configured.\n", $1, $6 }
      $2 == "attached" && $3 == "unknown" { printf "MED\tLonghorn volume %s (%s) is attached but its health is unknown.\n", $1, $6 }
    ' "$OUT/longhorn/volumes.tsv" >> "$FINDINGS"
    nv=$(wc -l < "$OUT/longhorn/volumes.tsv" | tr -d ' ')
    nrwx=$(awk -F'\t' 'tolower($4) ~ /rwx/' "$OUT/longhorn/volumes.tsv" | wc -l | tr -d ' ')
    nunk=$(awk -F'\t' '$3 != "healthy" && $3 != "degraded" && $3 != "faulted"' "$OUT/longhorn/volumes.tsv" | wc -l | tr -d ' ')
    finding INFO "Longhorn has $nv volume(s), $nrwx of them ReadWriteMany; $nunk have no health status (usually detached volumes, which is normal)."
  fi
  if have longhorn/nodes.txt; then
    awk 'NR > 1 && $2 != "True" && $2 != "<none>" { printf "HIGH\tLonghorn node %s is not Ready.\n", $1 }
         NR > 1 && $3 != "True" && $3 != "<none>" { printf "MED\tLonghorn node %s is not schedulable (disk full or disabled): new replicas cannot be placed there.\n", $1 }' \
      "$OUT/longhorn/nodes.txt" >> "$FINDINGS"
  fi
  if have longhorn/replicas.txt; then
    nrep=$(awk 'NR > 1 && $2 != "running" && $2 != "<none>"' "$OUT/longhorn/replicas.txt" | wc -l | tr -d ' ')
    [ "$nrep" -gt 0 ] && finding INFO "$nrep Longhorn replica(s) are not in state running (stopped replicas of detached volumes are normal; for attached volumes they mean reduced redundancy)."
  fi
fi

# ---- OOM risk at a glance: a qualitative estimate from the evidence above, not a prediction.
# Two different things can go wrong: a CONTAINER hits its own memory limit (that pod restarts),
# or the whole NODE runs out of memory (kernel kills processes, kubelet/containerd can die).
POD_RISK="UNKNOWN"; POD_WHY="pod data could not be read"
if ok pods/containers-status.tsv && [ ! -s "$OUT/pods/containers-status.tsv" ]; then
  POD_RISK="LOW"; POD_WHY="no containers are running"
elif ok pods/containers-status.tsv; then
  oom_recent=0; oom_total=0
  if have pods/oomkilled-by-namespace.tsv; then
    oom_recent=$(awk -F'\t' '{ s += $4 } END { print s + 0 }' "$OUT/pods/oomkilled-by-namespace.tsv")
    oom_total=$(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$OUT/pods/oomkilled-by-namespace.tsv")
  fi
  near=0; [ -f "$OUT/pods/pod-memory-flags.tsv" ] && near=$(awk -F'\t' '$1 == "NEAR-LIMIT"' "$OUT/pods/pod-memory-flags.tsv" | wc -l | tr -d ' ')
  measured=1; have pods/top-pods.tsv || measured=0
  if [ "$oom_recent" -gt 0 ]; then POD_RISK="VERY HIGH"; POD_WHY="$oom_recent container(s) were OOM-killed in the last 24 h - it is happening now"
  elif [ "$near" -gt 0 ]; then POD_RISK="HIGH"; POD_WHY="$near pod(s) use 95% or more of their memory limit right now"
  elif [ "$oom_total" -gt 0 ]; then POD_RISK="MODERATE"; POD_WHY="$oom_total container(s) were OOM-killed in the past$([ "$CUTOFF_24H" = 9999 ] && echo " (their time could not be checked)" || echo " (not in the last 24 h)")"
  elif [ "$measured" -eq 0 ]; then POD_RISK="LOW?"; POD_WHY="no OOM kills recorded, but live memory use could not be measured (metrics-server missing or not readable), so pods near their limit would not show"
  else POD_RISK="LOW"; POD_WHY="no OOM kills recorded and no pod close to its limit"; fi
fi
NODE_RISK="UNKNOWN"; NODE_WHY="node data could not be read (the kubeconfig may not list nodes)"
if ok nodes/nodes.tsv && [ ! -s "$OUT/nodes/nodes.tsv" ]; then
  if [ "$KARPENTER" -eq 1 ]; then NODE_RISK="UNKNOWN"; NODE_WHY="no nodes right now (Karpenter scales to zero)"
  else NODE_RISK="VERY HIGH"; NODE_WHY="the cluster has no worker nodes at all"; fi
elif have nodes/node-risk.tsv; then
  nhigh=$(awk -F'\t' '$5 == "HIGH"' "$OUT/nodes/node-risk.tsv" | wc -l | tr -d ' ')
  nelev=$(awk -F'\t' '$5 == "ELEVATED"' "$OUT/nodes/node-risk.tsv" | wc -l | tr -d ' ')
  nunk=$(awk -F'\t' '$5 == "UNKNOWN"' "$OUT/nodes/node-risk.tsv" | wc -l | tr -d ' ')
  nlive=$(awk -F'\t' '$4 != ""' "$OUT/nodes/node-risk.tsv" | wc -l | tr -d ' ')
  nn=$(wc -l < "$OUT/nodes/node-risk.tsv" | tr -d ' ')
  sysoom=0; [ -f "$OUT/events/events-by-reason-kind.tsv" ] && sysoom=$(awk -F'\t' '$2 == "SystemOOM" || $2 == "NodeHasInsufficientMemory" { s += $4 } END { print s + 0 }' "$OUT/events/events-by-reason-kind.tsv")
  mpress=0; [ -f "$OUT/nodes/nodes.tsv" ] && mpress=$(awk -F'\t' '$3 == "True"' "$OUT/nodes/nodes.tsv" | wc -l | tr -d ' ')
  evicted=0; [ -f "$OUT/events/events-by-reason-kind.tsv" ] && evicted=$(awk -F'\t' '$2 == "Evicted" { s += $4 } END { print s + 0 }' "$OUT/events/events-by-reason-kind.tsv")
  if [ "$sysoom" -gt 0 ] || [ "$mpress" -gt 0 ] || [ "$evicted" -gt 0 ]; then NODE_RISK="VERY HIGH"; NODE_WHY="the cluster is already showing node-level memory trouble (memory pressure, a node OOM / insufficient-memory event, or pods evicted within the last hour)"
  elif [ "$nhigh" -gt 0 ]; then NODE_RISK="HIGH"; NODE_WHY="$nhigh of $nn node(s) are at HIGH risk: $(awk -F'\t' '$5 == "HIGH" { print $1 ": " $6 }' "$OUT/nodes/node-risk.tsv" | head -n 2 | paste -sd'|' - | sed 's/|/ | /g')"
  elif [ "$nelev" -gt 0 ]; then NODE_RISK="MODERATE"; NODE_WHY="$nelev of $nn node(s) are over-committed, fairly full or have many pods without limits$([ "$nunk" -gt 0 ] && echo "; $nunk other node(s) could not be evaluated")"
  elif [ "$nunk" -gt 0 ]; then NODE_RISK="UNKNOWN"; NODE_WHY="$nunk of $nn node(s) could not be evaluated"
  elif [ "$nlive" -eq 0 ]; then NODE_RISK="LOW?"; NODE_WHY="requests and limits look fine, but live memory use could not be measured (metrics-server missing or not readable)"
  else NODE_RISK="LOW"; NODE_WHY="enough free memory on every node and limits not heavily over-committed"; fi
fi
{
  echo "Pod-level OOM  (a container hits its memory limit and restarts): $POD_RISK"
  echo "    because $POD_WHY"
  echo "Node-level OOM (a whole node runs out of memory; node may go offline): $NODE_RISK"
  echo "    because $NODE_WHY"
} > "$OUT/meta/oom-risk.txt"
# ======================================================================================
# Summary
# ======================================================================================
hi=$(grep -c '^HIGH' "$FINDINGS"); me=$(grep -c '^MED' "$FINDINGS")
nskip=$(wc -l < "$SKIPPED" | tr -d ' ')
{
  echo "SKS cluster health check - summary"
  echo "=================================="
  echo "Cluster context : $CTX"
  if [ "$EXO_OK" -eq 1 ]; then
    echo "Exoscale        : plan $EXO_PLAN, CNI $EXO_CNI, add-ons $(printf '%s' "$EXO_ADDONS" | tr -d '[]')"
  fi
  case "$ENV_TYPE" in
    "") echo "Cluster type    : not stated (use --env prod|test|mixed for a sharper rating)" ;;
    *)  echo "Cluster type    : $ENV_TYPE (stated by the person running the check)" ;;
  esac
  echo "Collected at    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Kubernetes      : ${SERVER_VERSION:-unknown}"
  echo
  echo "This check only read information from the cluster; it changed nothing."
  echo "Legend: [!!] needs attention soon   [! ] worth a look   [i] for information"
  echo
  echo "OOM RISK AT A GLANCE"
  echo "===================="
  echo "(OOM = out of memory. A qualitative estimate from the evidence below, not a prediction.)"
  echo
  while IFS= read -r l; do
    printf '  %s\n' "$l" | fold -s -w 100 | sed '2,$s/^/        /'
  done < "$OUT/meta/oom-risk.txt"
  echo
  echo "What we found"
  echo "-------------"
  if [ "$hi" -eq 0 ] && [ "$me" -eq 0 ]; then
    if [ "$nskip" -gt 0 ]; then
      echo "  No problems found in the data that could be read - BUT $nskip check(s) could not run (see"
      echo "  'Not checked' below). This is NOT an all-clear."
    else
      echo "  No obvious problems were detected by the automatic checks."
    fi
    echo
  fi
  awk -F'\t' '
    function wrap(prefix, txt,   w, n, i, line, pre, ind, first) {
      if (txt == "") return
      pre = "  " prefix " "; ind = sprintf("%" length(pre) "s", "")
      n = split(txt, w, " "); line = pre; first = 1
      for (i = 1; i <= n; i++) {
        if (!first && length(line) + length(w[i]) + 1 > 100) { print line; line = ind; first = 1 }
        line = line (first ? "" : " ") w[i]; first = 0
      }
      print line
    }
    function ismem(t) { return (substr(t, 1, 6) == "[mem] ") }
    function clean(t) { return (ismem(t) ? substr(t, 7) : t) }
    function mark(l) { return (l == "HIGH" ? "[!!]" : (l == "MED" ? "[! ]" : "[i] ")) }
    function section(lvl, title, topic,   c, i, bar) {
      c = 0
      for (i = 1; i <= N; i++) if (L[i] == lvl && (topic == "any" || (topic == "mem") == ismem(T[i]))) c++
      if (c == 0) return
      title = title " (" c ")"; bar = title; gsub(/./, "=", bar)
      print title; print bar; print ""
      for (i = 1; i <= N; i++) if (L[i] == lvl && (topic == "any" || (topic == "mem") == ismem(T[i]))) { wrap(mark(lvl), clean(T[i])); print "" }
    }
    { N++; L[N] = $1; T[N] = $2 }
    END {
      # memory / OOM topics first, most severe first, then everything else
      for (j = 1; j <= 3; j++) { l = (j == 1 ? "HIGH" : (j == 2 ? "MED" : "INFO")); t = (j == 1 ? "MEMORY AND OOM RISK - needs attention soon" : (j == 2 ? "MEMORY AND OOM RISK - worth a look" : "MEMORY - for information")); section(l, t, "mem") }
      section("HIGH", "OTHER PROBLEMS - need attention soon", "other")
      section("MED", "OTHER FINDINGS - worth a look", "other")
      section("INFO", "FOR INFORMATION", "other")
    }' "$FINDINGS"
  if have nodes/node-resources.tsv; then
    echo "Memory per node (what Kubernetes has promised vs what exists)"
    echo "-------------------------------------------------------------"
    echo "  'requested' = memory the pods asked for (reserved for them)."
    echo "  'limits'    = the most the pods may use; may exceed 100% (over-commit)."
    echo
    awk -F'\t' 'BEGIN { printf "  %-28s %12s %10s %8s %8s   %s\n", "NODE", "ALLOCATABLE", "REQUESTED", "LIMITS", "IN USE", "MEMORY RISK" }
                NR == FNR { alloc[$1] = $6; next }
                { printf "  %-28s %9.1f GiB %9s%% %7s%% %7s%%   %s\n", $1, alloc[$1] / 1024, $2, $3, ($4 == "" ? "?" : $4), $5 }' "$OUT/nodes/node-resources.tsv" "$OUT/nodes/node-risk.tsv"
    if have nodes/top-nodes.tsv; then
      echo
      awk 'BEGIN { printf "  %-34s %12s %12s\n", "NODE (live use)", "MEMORY USED", "CPU USED" } { printf "  %-34s %12s %12s\n", $1, $4 " (" $5 ")", $2 " (" $3 ")" }' "$OUT/nodes/top-nodes.tsv"
    fi
    echo
  fi
  if have pods/namespace-memory.tsv; then
    echo "Memory per namespace (top 10 by requested memory)"
    echo "-------------------------------------------------"
    awk -F'\t' 'BEGIN { printf "  %-26s %-7s %5s %10s %10s %10s  %s\n", "NAMESPACE", "CLASS", "PODS", "REQUESTED", "LIMITS", "LIVE", "QoS (BestEffort/Burstable/Guaranteed)" }
                NR <= 10 { printf "  %-26s %-7s %5s %7s MiB %7s MiB %7s MiB  %s/%s/%s\n", $1, $2 ($11 == "operator" ? "*" : ""), $3, $4, $5, $7, $8, $9, $10 }' "$OUT/pods/namespace-memory.tsv"
    echo "  (CLASS = prod, test or other. Guessed from the namespace name / env label; * = stated by the person running the check)"
    echo
  fi
  if have pods/top-pods.tsv; then
    echo "Biggest memory users right now"
    echo "------------------------------"
    awk "$AWK_MIB"'{ printf "%s %s %.0f\n", $1, $2, mib($4) }' "$OUT/pods/top-pods.tsv" | sort -k3,3nr \
      | awk 'NR <= 8 { printf "  %-22s %-50s %6s MiB\n", $1, $2, $3 }'
    echo
  fi
  if [ -s "$SKIPPED" ] || grep -q ' NO$' "$OUT/meta/permissions.txt"; then
    echo "Not checked (no permission, or the feature is not installed)"
    echo "------------------------------------------------------------"
    awk -F'\t' '{ n = split($3, q, "\"")
                  if ($3 ~ /is forbidden/) print q[4] (q[6] == "" ? "" : "." q[6]) ": no permission"
                  else if ($3 ~ /have a resource type/) print q[2] (q[4] == "" ? "" : "." q[4]) ": not installed"
                  else print $1 ": " $3 }' "$SKIPPED" | sort -u | sed 's/^/  - /'
    echo "  Details: meta/skipped.tsv and meta/permissions.txt. 'no permission' = the kubeconfig may not read it"
    echo "  (the standard 'view' role cannot read nodes, metrics, PersistentVolumes, PriorityClasses - see"
    echo "  sks-health-check.md for the small extra read-only role). 'Metrics API not available' = metrics-server"
    echo "  is missing or not running."
    echo
  fi
  echo "Where to look next"
  echo "------------------"
  echo "  nodes/        node status, conditions, instance types, requests vs capacity, live usage"
  echo "  pods/         restarts, OOMKilled, missing requests/limits, QoS, usage vs request, per-namespace memory"
  echo "  events/       warnings grouped by reason, by message and by workload"
  echo "  storage/      volumes and claims by storage class and status"
  echo "  longhorn/     (only if installed) volume health and Longhorn pod memory"
  echo "  cluster/      versions, namespaces, quotas, limit ranges, disruption budgets, workloads"
} > "$OUT/summary.txt"

rmdir "$OUT"/* 2>/dev/null
say ""
cat "$OUT/summary.txt"
say ""
say "Result folder: $OUT"
if [ "$MAKE_ARCHIVE" -eq 1 ] && command -v tar >/dev/null 2>&1; then
  excl=()
  [ "$ARCHIVE_LOGS" -eq 1 ] || excl=(--exclude='*/pods/logs')
  say ""
  say "The archive contains node and pod IPs, node/namespace/workload names, image names and event messages (which can quote probe output). No Secrets, no environment variables. Look through it before sending."
  [ "$WITH_LOGS" -eq 1 ] && [ "$ARCHIVE_LOGS" -eq 0 ] && say "Container logs were saved in the folder but are NOT in the archive (use --archive-logs to include them)."
  if tar -czf "$OUT.tar.gz" "${excl[@]+"${excl[@]}"}" -C "$(dirname "$OUT")" "$(basename "$OUT")"; then
    say "Archive to send back: $OUT.tar.gz"
  else
    say "WARNING: could not create the archive; send the folder $OUT instead."
  fi
fi

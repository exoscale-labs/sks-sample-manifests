#!/bin/bash
#
# DBaaS IP Filter Automation for SKS
# Automatically updates DBaaS IP filters with node IPs from SKS clusters
# Supports single or multiple clusters via exo CLI
#

set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

# Configuration: Can be set via environment variables (for Kubernetes)
# or hardcoded below (for standalone use)

# If running in Kubernetes with env vars, use those
if [[ -n "${SKS_CLUSTERS_CONFIG}" ]]; then
  IFS=',' read -ra SKS_CLUSTERS <<< "${SKS_CLUSTERS_CONFIG}"
  IFS=',' read -ra DBAAS_SERVICES <<< "${DBAAS_SERVICES_CONFIG}"
  IFS=',' read -ra STATIC_IPS <<< "${STATIC_IPS_CONFIG}"
  CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
else
  # Standalone mode: hardcoded configuration

  # SKS Clusters to monitor (format: "cluster-name:zone")
  SKS_CLUSTERS=(
    "de-sks:ch-gva-2"
    # "my-cluster-2:de-fra-1"
    # "my-cluster-3:at-vie-1"
  )

  # DBaaS services to update (format: "db-name:zone:type")
  # Supported types: pg, mysql, kafka, opensearch, valkey, grafana
  DBAAS_SERVICES=(
    "my-postgres-db:ch-gva-2:pg"
    # "my-mysql-db:ch-gva-2:mysql"
    # "my-kafka-db:de-fra-1:kafka"
    # "my-opensearch-db:de-fra-1:opensearch"
    # "my-valkey-db:ch-gva-2:valkey"
  )

  # Optional: Static IPs to always include (CIDR format)
  STATIC_IPS=(
    # "192.168.1.1/32"
    # "10.0.0.0/24"
  )

  # Check interval in seconds
  CHECK_INTERVAL=10
fi

# ============================================================================
# FUNCTIONS
# ============================================================================

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" >&2
}

error() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] ERROR: $*" >&2
}

# Get all node IPs from a single SKS cluster
get_cluster_ips() {
  local cluster_name="$1"
  local zone="$2"
  local ips=()

  log "  Querying cluster: $cluster_name (zone: $zone)"

  # Get all nodepools for this cluster
  local nodepools
  nodepools=$(exo compute sks nodepool list "$cluster_name" -z "$zone" -O json 2>/dev/null || echo "[]")

  # Extract instance pool IDs
  local pool_ids
  pool_ids=$(echo "$nodepools" | jq -r '.[].id // empty')

  if [[ -z "$pool_ids" ]]; then
    log "    No nodepools found"
    return 0
  fi

  # For each nodepool, get instance pool details
  while IFS= read -r pool_id; do
    if [[ -z "$pool_id" ]]; then
      continue
    fi

    # Get nodepool details to find instance_pool_id
    local nodepool_details
    nodepool_details=$(exo compute sks nodepool show "$cluster_name" "$pool_id" -z "$zone" -O json 2>/dev/null || echo "{}")

    local instance_pool_id
    instance_pool_id=$(echo "$nodepool_details" | jq -r '.instance_pool_id // empty')

    if [[ -z "$instance_pool_id" ]]; then
      continue
    fi

    # Get instance pool details
    local instance_pool
    instance_pool=$(exo compute instance-pool show "$instance_pool_id" -z "$zone" -O json 2>/dev/null || echo "{}")

    # Get instance names
    local instance_names
    instance_names=$(echo "$instance_pool" | jq -r '.instances[]? // empty')

    if [[ -z "$instance_names" ]]; then
      continue
    fi

    # For each instance, get the IP address
    while IFS= read -r instance_name; do
      if [[ -z "$instance_name" ]]; then
        continue
      fi

      local instance_details
      instance_details=$(exo compute instance show "$instance_name" -z "$zone" -O json 2>/dev/null || echo "{}")

      local ip
      ip=$(echo "$instance_details" | jq -r '.ip_address // empty')

      if [[ -n "$ip" ]] && [[ "$ip" != "-" ]]; then
        ips+=("${ip}/32")
        log "    Found IP: $ip (instance: $instance_name)"
      fi
    done <<< "$instance_names"

  done <<< "$pool_ids"

  # Return IPs as comma-separated string
  if [[ ${#ips[@]} -gt 0 ]]; then
    IFS=, ; echo "${ips[*]}"
  fi
}

# Get all IPs from all configured SKS clusters
get_all_cluster_ips() {
  local all_ips=()

  log "Gathering IPs from all clusters..."

  for cluster_config in "${SKS_CLUSTERS[@]}"; do
    IFS=: read -r cluster_name zone <<< "$cluster_config"

    local cluster_ips
    cluster_ips=$(get_cluster_ips "$cluster_name" "$zone")

    if [[ -n "$cluster_ips" ]]; then
      IFS=, read -ra ip_array <<< "$cluster_ips"
      all_ips+=("${ip_array[@]}")
    fi
  done

  # Add static IPs
  if [[ ${#STATIC_IPS[@]} -gt 0 ]]; then
    log "  Adding ${#STATIC_IPS[@]} static IP(s)"
    all_ips+=("${STATIC_IPS[@]}")
  fi

  # Return unique IPs as comma-separated string
  if [[ ${#all_ips[@]} -gt 0 ]]; then
    # Remove duplicates and sort
    printf '%s\n' "${all_ips[@]}" | sort -u | tr '\n' ',' | sed 's/,$//'
  fi
}

# Update DBaaS IP filters
update_dbaas_filters() {
  local ip_list="$1"

  log "Updating DBaaS IP filters..."

  for dbaas_config in "${DBAAS_SERVICES[@]}"; do
    IFS=: read -r db_name zone db_type <<< "$dbaas_config"

    log "  Updating $db_type database: $db_name (zone: $zone)"

    case "$db_type" in
      pg)
        yes | exo dbaas update "$db_name" -z "$zone" --pg-ip-filter "$ip_list" 2>&1 || error "Failed to update $db_name"
        ;;
      mysql)
        yes | exo dbaas update "$db_name" -z "$zone" --mysql-ip-filter "$ip_list" 2>&1 || error "Failed to update $db_name"
        ;;
      kafka)
        yes | exo dbaas update "$db_name" -z "$zone" --kafka-ip-filter "$ip_list" 2>&1 || error "Failed to update $db_name"
        ;;
      opensearch)
        yes | exo dbaas update "$db_name" -z "$zone" --opensearch-ip-filter "$ip_list" 2>&1 || error "Failed to update $db_name"
        ;;
      valkey)
        yes | exo dbaas update "$db_name" -z "$zone" --valkey-ip-filter "$ip_list" 2>&1 || error "Failed to update $db_name"
        ;;
      grafana)
        yes | exo dbaas update "$db_name" -z "$zone" --grafana-ip-filter "$ip_list" 2>&1 || error "Failed to update $db_name"
        ;;
      *)
        error "Unknown database type: $db_type"
        ;;
    esac
  done

  log "Update complete."
}

# ============================================================================
# MAIN
# ============================================================================

log "Starting DBaaS IP filter automation"
log "Monitoring ${#SKS_CLUSTERS[@]} SKS cluster(s)"
log "Managing IP filters for ${#DBAAS_SERVICES[@]} DBaaS service(s)"
log "Check interval: ${CHECK_INTERVAL}s"
log "========================================================================"

# Verify exo CLI is available
if ! command -v exo &> /dev/null; then
  error "exo CLI not found. Please install it first."
  exit 1
fi

# Verify jq is available
if ! command -v jq &> /dev/null; then
  error "jq not found. Please install it first."
  exit 1
fi

# Verify API credentials are set
if [[ -z "${EXOSCALE_API_KEY}" ]]; then
  error "EXOSCALE_API_KEY environment variable not set"
  exit 1
fi

if [[ -z "${EXOSCALE_API_SECRET}" ]]; then
  error "EXOSCALE_API_SECRET environment variable not set"
  exit 1
fi

# Main loop
PREVIOUS_IPS=""
while true; do
  log "Checking for IP changes..."

  CURRENT_IPS=$(get_all_cluster_ips)

  if [[ -z "$CURRENT_IPS" ]]; then
    error "No IPs found! Skipping update."
  elif [[ "$CURRENT_IPS" != "$PREVIOUS_IPS" ]]; then
    log "IP change detected!"
    log "New IP list: $CURRENT_IPS"

    update_dbaas_filters "$CURRENT_IPS"

    PREVIOUS_IPS="$CURRENT_IPS"
  else
    log "No IP changes detected."
  fi

  log ""
  sleep "$CHECK_INTERVAL"
done

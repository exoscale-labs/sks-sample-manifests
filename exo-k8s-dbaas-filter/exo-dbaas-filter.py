#!/usr/bin/env python3
"""
Exoscale DBaaS IP Filter Automation

Automatically synchronizes SKS cluster node IPs with DBaaS IP filters.
Monitors one or more SKS clusters and updates IP filters for one or more DBaaS services.

Usage:
  - Standalone: Configure variables below, then run: python3 exo-dbaas-filter.py
  - Kubernetes: Set environment variables (see deployment.yaml)
"""

import os
import sys
import time
import logging
from typing import List, Set, Dict
from datetime import datetime

try:
    import requests
    from exoscale_auth import ExoscaleV2Auth
except ImportError:
    print("Error: Required dependencies not installed.")
    print("Install with: pip install requests requests-exoscale-auth")
    sys.exit(1)

# Configure logging
log_level = os.getenv('LOG_LEVEL', 'INFO').upper()
logging.basicConfig(
    level=getattr(logging, log_level),
    format='[%(asctime)s UTC] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logging.Formatter.converter = time.gmtime  # Use UTC
logger = logging.getLogger(__name__)


# ============================================================================
# Configuration
# ============================================================================

# Read from environment variables (Kubernetes) or use defaults (standalone)
def get_config():
    """Read configuration from environment or use defaults."""

    # API credentials (required)
    api_key = os.getenv('EXOSCALE_API_KEY')
    api_secret = os.getenv('EXOSCALE_API_SECRET')

    if not api_key or not api_secret:
        logger.error("EXOSCALE_API_KEY and EXOSCALE_API_SECRET must be set")
        sys.exit(1)

    # SKS clusters to monitor (format: "cluster-name:zone,cluster-name:zone")
    sks_clusters_str = os.getenv('SKS_CLUSTERS', 'my-cluster:ch-gva-2')
    sks_clusters = []
    for cluster in sks_clusters_str.split(','):
        cluster = cluster.strip()
        if cluster:
            parts = cluster.split(':')
            if len(parts) == 2:
                sks_clusters.append({'name': parts[0], 'zone': parts[1]})

    # DBaaS services to update (format: "db-name:zone:type,db-name:zone:type")
    # Supported types: pg, mysql, kafka, opensearch, valkey, grafana
    dbaas_services_str = os.getenv('DBAAS_SERVICES', 'my-postgres-db:ch-gva-2:pg')
    dbaas_services = []
    for service in dbaas_services_str.split(','):
        service = service.strip()
        if service:
            parts = service.split(':')
            if len(parts) == 3:
                dbaas_services.append({
                    'name': parts[0],
                    'zone': parts[1],
                    'type': parts[2]
                })

    # Optional static IPs (format: "192.168.1.1/32,10.0.0.0/24")
    static_ips_str = os.getenv('STATIC_IPS', '')
    static_ips = [ip.strip() for ip in static_ips_str.split(',') if ip.strip()]

    # Check interval in seconds
    check_interval = int(os.getenv('CHECK_INTERVAL', '10'))

    return {
        'api_key': api_key,
        'api_secret': api_secret,
        'sks_clusters': sks_clusters,
        'dbaas_services': dbaas_services,
        'static_ips': static_ips,
        'check_interval': check_interval
    }


# ============================================================================
# Exoscale API Client
# ============================================================================

class ExoscaleAPI:
    """Simple Exoscale API v2 client."""

    def __init__(self, api_key: str, api_secret: str):
        self.api_key = api_key
        self.api_secret = api_secret
        self.auth = ExoscaleV2Auth(api_key, api_secret)
        self.zone_endpoints = {}

    def _get_zone_endpoint(self, zone: str) -> str:
        """Get API endpoint for a zone."""
        if zone not in self.zone_endpoints:
            # List zones to get endpoint
            resp = requests.get(
                'https://api-ch-gva-2.exoscale.com/v2/zone',
                auth=self.auth,
                timeout=30
            )
            resp.raise_for_status()
            zones = resp.json().get('zones', [])
            for z in zones:
                self.zone_endpoints[z['name']] = z['api-endpoint']

        return self.zone_endpoints.get(zone, f'https://api-{zone}.exoscale.com/v2')

    def get_sks_clusters(self, zone: str) -> List[Dict]:
        """List SKS clusters in a zone."""
        endpoint = self._get_zone_endpoint(zone)
        resp = requests.get(
            f'{endpoint}/sks-cluster',
            auth=self.auth,
            timeout=30
        )
        resp.raise_for_status()
        return resp.json().get('sks-clusters', [])

    def get_sks_cluster(self, cluster_id: str, zone: str) -> Dict:
        """Get SKS cluster details."""
        endpoint = self._get_zone_endpoint(zone)
        resp = requests.get(
            f'{endpoint}/sks-cluster/{cluster_id}',
            auth=self.auth,
            timeout=30
        )
        resp.raise_for_status()
        return resp.json()


    def get_instance_pool(self, pool_id: str, zone: str) -> Dict:
        """Get instance pool details."""
        endpoint = self._get_zone_endpoint(zone)
        resp = requests.get(
            f'{endpoint}/instance-pool/{pool_id}',
            auth=self.auth,
            timeout=30
        )
        resp.raise_for_status()
        return resp.json()

    def get_instance(self, instance_id: str, zone: str) -> Dict:
        """Get instance details."""
        endpoint = self._get_zone_endpoint(zone)
        resp = requests.get(
            f'{endpoint}/instance/{instance_id}',
            auth=self.auth,
            timeout=30
        )
        resp.raise_for_status()
        return resp.json()

    def update_dbaas_ip_filter(self, db_name: str, db_type: str, zone: str, ip_filter: List[str]) -> None:
        """Update DBaaS IP filter."""
        endpoint = self._get_zone_endpoint(zone)

        # Map short type to API endpoint type
        type_map = {
            'pg': 'pg',
            'mysql': 'mysql',
            'kafka': 'kafka',
            'opensearch': 'opensearch',
            'valkey': 'redis',
            'grafana': 'grafana'
        }
        api_type = type_map.get(db_type, db_type)

        # Get database first to verify it exists
        resp = requests.get(
            f'{endpoint}/dbaas-{api_type}/{db_name}',
            auth=self.auth,
            timeout=30
        )
        resp.raise_for_status()

        # Update IP filter
        resp = requests.put(
            f'{endpoint}/dbaas-{api_type}/{db_name}',
            auth=self.auth,
            json={'ip-filter': ip_filter},
            timeout=30
        )
        resp.raise_for_status()


# ============================================================================
# Main Logic
# ============================================================================

def get_cluster_ips(api: ExoscaleAPI, cluster_name: str, zone: str) -> Set[str]:
    """Get all node IPs from an SKS cluster."""
    ips = set()

    try:
        # Find cluster by name
        clusters = api.get_sks_clusters(zone)
        cluster = None
        for c in clusters:
            if c['name'] == cluster_name:
                cluster = c
                break

        if not cluster:
            logger.warning(f"  Cluster '{cluster_name}' not found in zone {zone}")
            return ips

        cluster_id = cluster['id']

        # Get full cluster details (includes nodepools)
        cluster_details = api.get_sks_cluster(cluster_id, zone)
        nodepools = cluster_details.get('nodepools', [])

        for nodepool in nodepools:
            # API returns instance-pool as an object with 'id' field
            instance_pool = nodepool.get('instance-pool', {})
            pool_id = instance_pool.get('id') if isinstance(instance_pool, dict) else None

            if not pool_id:
                logger.debug(f"    Nodepool {nodepool.get('name', 'unknown')} has no instance-pool")
                continue

            logger.debug(f"    Nodepool: {nodepool.get('name')}, pool_id: {pool_id}")

            # Get instance pool
            pool = api.get_instance_pool(pool_id, zone)
            instances = pool.get('instances', [])
            logger.debug(f"    Found {len(instances)} instances in pool")

            for instance_ref in instances:
                instance_id = instance_ref.get('id')
                if not instance_id:
                    continue

                # Get instance details
                instance = api.get_instance(instance_id, zone)
                # The API returns the IP in the 'public-ip' field
                ip_address = instance.get('public-ip')

                if ip_address:
                    ips.add(f"{ip_address}/32")
                    logger.info(f"    Found IP: {ip_address} (instance: {instance.get('name', instance_id)})")

    except requests.exceptions.RequestException as e:
        logger.error(f"  Error querying cluster {cluster_name}: {e}")

    return ips


def gather_all_ips(api: ExoscaleAPI, clusters: List[Dict], static_ips: List[str]) -> Set[str]:
    """Gather IPs from all clusters and add static IPs."""
    all_ips = set()

    logger.info("Gathering IPs from all clusters...")

    for cluster in clusters:
        cluster_name = cluster['name']
        zone = cluster['zone']
        logger.info(f"  Querying cluster: {cluster_name} (zone: {zone})")

        cluster_ips = get_cluster_ips(api, cluster_name, zone)
        all_ips.update(cluster_ips)

    # Add static IPs
    if static_ips:
        logger.info(f"  Adding {len(static_ips)} static IP(s)")
        all_ips.update(static_ips)

    return all_ips


def update_dbaas_services(api: ExoscaleAPI, services: List[Dict], ip_list: List[str]) -> None:
    """Update IP filters for all DBaaS services."""
    logger.info("Updating DBaaS IP filters...")

    for service in services:
        db_name = service['name']
        db_type = service['type']
        zone = service['zone']

        try:
            logger.info(f"  Updating {db_type} database: {db_name} (zone: {zone})")
            api.update_dbaas_ip_filter(db_name, db_type, zone, ip_list)
        except requests.exceptions.RequestException as e:
            logger.error(f"  Failed to update {db_name}: {e}")


def main():
    """Main automation loop."""
    config = get_config()

    logger.info("Starting DBaaS IP filter automation")
    logger.info(f"Monitoring {len(config['sks_clusters'])} SKS cluster(s)")
    logger.info(f"Managing IP filters for {len(config['dbaas_services'])} DBaaS service(s)")

    api = ExoscaleAPI(config['api_key'], config['api_secret'])
    previous_ips = set()

    while True:
        try:
            logger.info("Checking for IP changes...")

            # Gather all IPs
            current_ips = gather_all_ips(
                api,
                config['sks_clusters'],
                config['static_ips']
            )

            # Check if IPs changed
            if current_ips != previous_ips:
                if not current_ips:
                    logger.error("No IPs found! Skipping update.")
                else:
                    logger.info("IP change detected!")
                    ip_list = sorted(list(current_ips))
                    logger.info(f"New IP list: {', '.join(ip_list)}")

                    # Update all DBaaS services
                    update_dbaas_services(api, config['dbaas_services'], ip_list)

                    previous_ips = current_ips
                    logger.info("Update complete.")
            else:
                logger.info("No IP changes detected.")

        except Exception as e:
            logger.error(f"Error in main loop: {e}")

        # Wait before next check
        time.sleep(config['check_interval'])


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        sys.exit(0)

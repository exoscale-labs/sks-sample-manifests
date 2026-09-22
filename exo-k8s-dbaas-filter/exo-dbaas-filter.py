#!/usr/bin/env python3
"""
Exoscale DBaaS IP Filter Automation

Automatically synchronizes SKS cluster node IPs with DBaaS IP filters.
Monitors one or more SKS clusters and updates IP filters for one or more DBaaS services.

The tool never removes an address it cannot account for. An entry is removed only
on a cycle where every configured cluster reconciled: where the number of addresses
collected matches the number of nodes each nodepool reports. Any error, any
incomplete response and any count mismatch makes that cycle add-only -- verified
addresses are still applied, nothing is taken away -- and a cycle that finds no
nodes at all leaves the filter alone entirely.

It is always safe to leave a stale filter in place; it is never safe to write a
truncated one.

Usage:
  - Standalone: export the environment variables below, then run:
      python3 exo-dbaas-filter.py
  - Kubernetes: see deployment.yaml
"""

import os
import sys
import time
import logging
import ipaddress
from typing import List, Set, Dict, Optional, Iterable, NoReturn, NamedTuple

try:
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.util.retry import Retry
    from exoscale_auth import ExoscaleV2Auth
except ImportError:
    print("Error: Required dependencies not installed.")
    print("Install with: pip install requests requests-exoscale-auth")
    sys.exit(1)

# Configure logging
log_level = os.getenv('LOG_LEVEL', 'INFO').upper()
logging.basicConfig(
    level=getattr(logging, log_level, logging.INFO),
    format='[%(asctime)s UTC] %(levelname)s %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logging.Formatter.converter = time.gmtime  # Use UTC
logger = logging.getLogger(__name__)

# Short DBaaS type -> API endpoint type
DBAAS_TYPES = {
    'pg': 'postgres',
    'mysql': 'mysql',
    'kafka': 'kafka',
    'opensearch': 'opensearch',
    'valkey': 'valkey',
    'grafana': 'grafana',
}

RETRY_STATUSES = (429, 500, 502, 503, 504)


class Inventory(NamedTuple):
    """The node addresses gathered in one pass over the configured clusters.

    `complete` is True only when every configured cluster reconciled. When it is
    False, `node_ips` still holds the addresses of the clusters that did
    reconcile: those are safe to add, but nothing may be removed, because the
    missing clusters' nodes cannot be distinguished from nodes that are gone.
    """
    node_ips: Set[str]
    complete: bool


# ============================================================================
# Configuration
# ============================================================================

def _fail(message: str) -> NoReturn:
    """Abort startup with a clear message.

    Misconfiguration is fatal on purpose. Entries that are silently dropped can
    leave zero clusters to query, which would look like a valid empty inventory.
    """
    logger.error(message)
    sys.exit(1)


def _split(value: str) -> List[str]:
    return [item.strip() for item in value.split(',') if item.strip()]


def _int_env(name: str, default: str, minimum: int) -> int:
    raw = os.getenv(name, default).strip()
    try:
        value = int(raw)
    except ValueError:
        _fail(f"{name} must be an integer, got '{raw}'")
    if value < minimum:
        _fail(f"{name} must be at least {minimum}, got {value}")
    return value


def get_config() -> Dict:
    """Read and validate configuration from the environment."""

    api_key = os.getenv('EXOSCALE_API_KEY')
    api_secret = os.getenv('EXOSCALE_API_SECRET')
    if not api_key or not api_secret:
        _fail("EXOSCALE_API_KEY and EXOSCALE_API_SECRET must be set")

    # SKS clusters to monitor (format: "cluster-name:zone,cluster-name:zone")
    sks_clusters = []
    for entry in _split(os.getenv('SKS_CLUSTERS', '')):
        parts = [part.strip() for part in entry.split(':')]
        if len(parts) != 2 or not all(parts):
            _fail(f"Invalid SKS_CLUSTERS entry '{entry}', expected 'name:zone'")
        sks_clusters.append({'name': parts[0], 'zone': parts[1]})
    if not sks_clusters:
        _fail("SKS_CLUSTERS must contain at least one 'name:zone' entry")

    # DBaaS services to update (format: "db-name:zone:type,db-name:zone:type")
    dbaas_services = []
    for entry in _split(os.getenv('DBAAS_SERVICES', '')):
        parts = [part.strip() for part in entry.split(':')]
        if len(parts) != 3 or not all(parts):
            _fail(
                f"Invalid DBAAS_SERVICES entry '{entry}', expected 'name:zone:type'")
        if parts[2] not in DBAAS_TYPES:
            _fail(f"Unknown DBaaS type '{parts[2]}' in '{entry}'. "
                  f"Supported types: {', '.join(sorted(DBAAS_TYPES))}")
        dbaas_services.append(
            {'name': parts[0], 'zone': parts[1], 'type': parts[2]})
    if not dbaas_services:
        _fail("DBAAS_SERVICES must contain at least one 'name:zone:type' entry")

    # Optional static IPs (format: "192.168.1.1/32,10.0.0.0/24").
    # Validated here because a single malformed entry makes every update fail
    # with HTTP 400, which would stop all updates without an obvious cause.
    static_ips = []
    for entry in _split(os.getenv('STATIC_IPS', '')):
        try:
            ipaddress.ip_network(entry, strict=False)
        except ValueError as exc:
            _fail(f"Invalid STATIC_IPS entry '{entry}': {exc}")
        static_ips.append(entry)

    dry_run = os.getenv('DRY_RUN', 'false').strip().lower() in (
        '1', 'true', 'yes', 'on')

    return {
        'api_key': api_key,
        'api_secret': api_secret,
        'sks_clusters': sks_clusters,
        'dbaas_services': dbaas_services,
        'static_ips': static_ips,
        'check_interval': _int_env('CHECK_INTERVAL', '10', minimum=1),
        'max_retries': _int_env('MAX_RETRIES', '3', minimum=0),
        'request_timeout': _int_env('REQUEST_TIMEOUT', '30', minimum=1),
        'dry_run': dry_run,
    }


def normalise_cidrs(values: Iterable[str]) -> Set[str]:
    """Normalise CIDR strings so equivalent forms compare equal.

    The API is not required to echo entries verbatim; without this, a filter
    returned as '1.2.3.4' would never match one written as '1.2.3.4/32' and the
    tool would rewrite it on every cycle.
    """
    return {str(ipaddress.ip_network(str(value).strip(), strict=False))
            for value in values}


# ============================================================================
# Exoscale API Client
# ============================================================================

class ExoscaleAPI:
    """Simple Exoscale API v2 client."""

    def __init__(self, api_key: str, api_secret: str,
                 max_retries: int = 3, timeout: int = 30):
        self.auth = ExoscaleV2Auth(api_key, api_secret)
        self.timeout = timeout

        # A shared session gives connection reuse and bounded retries on the
        # transient failures that are common during an API incident. Every
        # operation here is idempotent, so PUT is retried as well.
        self.session = requests.Session()
        adapter = HTTPAdapter(max_retries=Retry(
            total=max_retries,
            connect=max_retries,
            read=max_retries,
            status=max_retries,
            backoff_factor=1,
            status_forcelist=RETRY_STATUSES,
            allowed_methods=frozenset(['GET', 'PUT']),
        ))
        self.session.mount('https://', adapter)

    @staticmethod
    def _endpoint(zone: str) -> str:
        """Zone API endpoint.

        The OpenAPI description defines 'https://api-{zone}.exoscale.com/v2' as
        the server template, so the endpoint is derived rather than looked up.
        Querying a single zone for the zone list would make every zone depend on
        that one zone being reachable.
        """
        return f'https://api-{zone}.exoscale.com/v2'

    def _get(self, zone: str, path: str) -> Dict:
        resp = self.session.get(
            f'{self._endpoint(zone)}{path}', auth=self.auth, timeout=self.timeout)
        resp.raise_for_status()
        return resp.json()

    def get_sks_clusters(self, zone: str) -> Optional[List[Dict]]:
        """List SKS clusters in a zone, including their nodepools.

        Returns whatever the API sent, including None for a missing key, so the
        caller can tell an empty list apart from a malformed response.
        """
        return self._get(zone, '/sks-cluster').get('sks-clusters')

    def get_instance_pool(self, pool_id: str, zone: str) -> Dict:
        """Get instance pool details."""
        return self._get(zone, f'/instance-pool/{pool_id}')

    def get_instance(self, instance_id: str, zone: str) -> Dict:
        """Get instance details."""
        return self._get(zone, f'/instance/{instance_id}')

    def get_dbaas_ip_filter(self, db_name: str, db_type: str,
                            zone: str) -> Optional[List[str]]:
        """Return the IP filter currently set on a DBaaS service."""
        api_type = DBAAS_TYPES[db_type]
        return self._get(zone, f'/dbaas-{api_type}/{db_name}').get('ip-filter')

    def update_dbaas_ip_filter(self, db_name: str, db_type: str, zone: str,
                               ip_filter: List[str]) -> None:
        """Replace the IP filter of a DBaaS service."""
        api_type = DBAAS_TYPES[db_type]
        resp = self.session.put(
            f'{self._endpoint(zone)}/dbaas-{api_type}/{db_name}',
            auth=self.auth,
            json={'ip-filter': ip_filter},
            timeout=self.timeout
        )
        resp.raise_for_status()


# ============================================================================
# Inventory
# ============================================================================

def _nodepool_ips(api: ExoscaleAPI, nodepool: Dict,
                  zone: str) -> Optional[Set[str]]:
    """Collect the public IPs of one nodepool, or None if the answer is incomplete.

    A successful HTTP response is not evidence of a complete answer. Each
    nodepool reports how many instances it has, so the collected addresses are
    reconciled against that count and anything short is rejected.
    """
    name = nodepool.get('name', 'unknown')

    size = nodepool.get('size')
    if not isinstance(size, int) or isinstance(size, bool):
        logger.error(f"    Nodepool {name}: missing or invalid 'size'")
        return None

    instance_pool = nodepool.get('instance-pool')
    pool_id = instance_pool.get('id') if isinstance(instance_pool, dict) else None
    if not pool_id:
        if size == 0:
            logger.debug(
                f"    Nodepool {name}: size 0 and no instance pool, no nodes")
            return set()
        logger.error(
            f"    Nodepool {name}: size {size} but no instance-pool reference")
        return None

    # A size of 0 is still confirmed against the instance pool rather than
    # trusted: a stale nodepool object reporting 0 while the pool still runs
    # instances would otherwise silently drop every node in it.

    pool = api.get_instance_pool(pool_id, zone)
    if pool.get('id') != pool_id:
        logger.error(f"    Nodepool {name}: requested instance-pool {pool_id} "
                     f"but received {pool.get('id')}")
        return None

    pool_size = pool.get('size')
    if pool_size is not None and pool_size != size:
        logger.error(f"    Nodepool {name}: nodepool size {size} disagrees with "
                     f"instance-pool size {pool_size}")
        return None

    instances = pool.get('instances')
    if instances is None:
        logger.error(
            f"    Nodepool {name}: instance-pool {pool_id} returned no "
            f"'instances' field")
        return None

    if len(instances) != size:
        logger.error(f"    Nodepool {name}: expected {size} instance(s), "
                     f"instance-pool listed {len(instances)}")
        return None

    ips = set()
    for instance_ref in instances:
        instance_id = instance_ref.get('id')
        if not instance_id:
            logger.error(f"    Nodepool {name}: instance reference without an id")
            return None

        instance = api.get_instance(instance_id, zone)
        if instance.get('id') != instance_id:
            logger.error(f"    Nodepool {name}: requested instance {instance_id} "
                         f"but received {instance.get('id')}")
            return None

        ip_address = instance.get('public-ip')
        if not ip_address:
            logger.error(f"    Nodepool {name}: instance "
                         f"{instance.get('name', instance_id)} has no public-ip")
            return None

        try:
            parsed = ipaddress.IPv4Address(str(ip_address).strip())
        except ValueError:
            logger.error(f"    Nodepool {name}: instance "
                         f"{instance.get('name', instance_id)} reported an "
                         f"unusable public-ip '{ip_address}'")
            return None

        ips.add(f"{parsed}/32")
        logger.info(f"    Found IP: {parsed} "
                    f"(instance: {instance.get('name', instance_id)})")

    if len(ips) != size:
        logger.error(f"    Nodepool {name}: {len(ips)} unique IP(s) for "
                     f"{size} node(s)")
        return None

    return ips


def get_cluster_ips(api: ExoscaleAPI, cluster_name: str,
                    zone: str) -> Optional[Set[str]]:
    """Get all node IPs from an SKS cluster, or None if the inventory is incomplete.

    Returning None means "do not touch the IP filter". Every failure path leads
    here: transport errors, malformed payloads, and responses that are
    well-formed but describe fewer nodes than the cluster says it has.
    """
    try:
        clusters = api.get_sks_clusters(zone)
        if not isinstance(clusters, list):
            logger.error(f"  Unexpected cluster list payload in zone {zone}")
            return None

        matches = [c for c in clusters if c.get('name') == cluster_name]
        if not matches:
            logger.error(f"  Cluster '{cluster_name}' not found in zone {zone}")
            return None
        if len(matches) > 1:
            logger.error(f"  Cluster name '{cluster_name}' is ambiguous in zone "
                         f"{zone}: {len(matches)} clusters share it")
            return None
        cluster = matches[0]

        if not cluster.get('id'):
            logger.error(f"  Cluster '{cluster_name}' returned without an id")
            return None

        # The cluster list already carries full nodepool details, so no
        # additional per-cluster request is needed.
        nodepools = cluster.get('nodepools')
        if nodepools is None:
            logger.error(
                f"  Cluster '{cluster_name}' returned no 'nodepools' field")
            return None

        ips: Set[str] = set()
        expected = 0
        for nodepool in nodepools:
            nodepool_ips = _nodepool_ips(api, nodepool, zone)
            if nodepool_ips is None:
                logger.error(
                    f"  Incomplete inventory for cluster '{cluster_name}'")
                return None
            expected += nodepool['size']
            ips |= nodepool_ips

        if len(ips) != expected:
            logger.error(f"  Cluster '{cluster_name}': collected {len(ips)} "
                         f"unique IP(s) for {expected} expected node(s)")
            return None

        return ips

    except Exception as exc:
        # Deliberately broad: a malformed body raises ValueError and a missing
        # field raises KeyError, neither of which is a RequestException. Any
        # unexpected failure must fail closed rather than escape as a partial
        # result.
        logger.error(f"  Error querying cluster {cluster_name}: {exc}")
        return None


def gather_inventory(api: ExoscaleAPI, clusters: List[Dict]) -> Inventory:
    """Collect node IPs from every configured cluster.

    A cluster whose inventory cannot be established does not discard the others:
    its failure is recorded in `complete` so the caller can still apply the
    addresses it did verify, without removing anything.
    """
    node_ips: Set[str] = set()
    complete = True

    logger.info("Gathering IPs from all clusters...")

    for cluster in clusters:
        cluster_name = cluster['name']
        zone = cluster['zone']
        logger.info(f"  Querying cluster: {cluster_name} (zone: {zone})")

        cluster_ips = get_cluster_ips(api, cluster_name, zone)
        if cluster_ips is None:
            logger.error(f"  Inventory for cluster '{cluster_name}' is "
                         f"incomplete; no entry will be removed this cycle")
            complete = False
            continue

        node_ips |= cluster_ips

    return Inventory(node_ips=node_ips, complete=complete)


# ============================================================================
# Applier
# ============================================================================

def apply_ip_filter(api: ExoscaleAPI, services: List[Dict],
                    wanted: Iterable[str], dry_run: bool = False,
                    additive: bool = False) -> bool:
    """Bring every service's IP filter to the wanted set. True only if all succeeded.

    With `additive`, the wanted addresses are merged into whatever each service
    already has instead of replacing it. That is the mode used when some cluster
    could not be inventoried: the verified addresses are still applied, but no
    entry is removed on the strength of an incomplete picture.
    """
    logger.info("Updating DBaaS IP filters...")
    wanted = normalise_cidrs(wanted)
    all_succeeded = True

    for service in services:
        db_name = service['name']
        db_type = service['type']
        zone = service['zone']
        label = f"{db_name} ({db_type}, {zone})"

        # An absent or empty ip-filter allows nothing; it is a known state, not
        # an unknown one, so it reads as an empty set. Only a failed request --
        # including a response carrying an entry that cannot be parsed, which is
        # part of reading it -- leaves the current filter genuinely unknown.
        try:
            current = api.get_dbaas_ip_filter(db_name, db_type, zone)
            current_set = normalise_cidrs(current or [])
        except Exception as exc:
            logger.warning(f"  {label}: could not read the current IP filter ({exc})")
            current_set = None

        if additive:
            # The union cannot be computed without knowing what is already
            # there, and writing the wanted set alone would drop everything
            # else. Skipping is the only safe option.
            if current_set is None:
                logger.error(f"  {label}: skipped, an additive update needs the "
                             f"current filter and it could not be read")
                all_succeeded = False
                continue
            desired = current_set | wanted
        else:
            # A comparison that cannot be made is not a reason to skip: the
            # wanted set is complete by construction, so fall through and write.
            desired = wanted

        if current_set is not None and current_set == desired:
            logger.info(f"  {label}: already up to date")
            continue

        ip_list = sorted(desired)
        added = sorted(desired - current_set) if current_set is not None else ip_list
        detail = f"{len(ip_list)} entr(ies): {', '.join(ip_list)}"
        if additive:
            detail += f" (adding {', '.join(added)})"

        try:
            if dry_run:
                logger.info(f"  {label}: DRY_RUN, would set {detail}")
                continue

            logger.info(f"  Updating {label}: {detail}")
            api.update_dbaas_ip_filter(db_name, db_type, zone, ip_list)
        except Exception as exc:
            logger.error(f"  Failed to update {db_name}: {exc}")
            all_succeeded = False

    return all_succeeded


# ============================================================================
# Main Logic
# ============================================================================

def run_cycle(api: ExoscaleAPI, config: Dict) -> bool:
    """Run one reconciliation cycle.

    Returns True only when the inventory was complete and every configured
    service ends the cycle holding exactly the desired filter. A cycle that
    could not inventory every cluster returns False even when its additions were
    applied, because the filter is not in its intended state and removals are
    still outstanding.

    The desired state is compared against what each service actually reports
    rather than against a remembered previous result: an update accepted with
    HTTP 200 is applied asynchronously and can still fail, and a filter can be
    changed by other means. Re-reading it each time makes the tool converge on
    its own instead of trusting that an earlier write stuck.
    """
    logger.info("Checking for IP changes...")

    inventory = gather_inventory(api, config['sks_clusters'])
    static_ips = set(config['static_ips'])

    if not inventory.complete:
        # Some cluster could not be inventoried. Its nodes are indistinguishable
        # from nodes that are gone, so nothing may be removed -- but the
        # addresses that were verified are still safe to add, and withholding
        # them would deny database access to healthy, newly added nodes for as
        # long as the other cluster stays broken.
        verified = inventory.node_ips | static_ips
        logger.error("Inventory incomplete for at least one cluster. Applying "
                     "verified addresses only; no entry will be removed.")
        if verified:
            logger.info(f"Verified addresses ({len(verified)}): "
                        f"{', '.join(sorted(normalise_cidrs(verified)))}")

        if apply_ip_filter(api, config['dbaas_services'], verified,
                           config['dry_run'], additive=True):
            logger.warning("Verified additions applied. Removals stay suspended "
                           "until every cluster can be inventoried again.")
        else:
            logger.error("One or more services could not be updated. "
                         "Retrying on the next cycle.")
        return False

    if not inventory.node_ips:
        # Every cluster answered, and between them they have no nodes. That is
        # indistinguishable from an inventory that came back empty by accident,
        # and merging static IPs would turn it into a plausible-looking result.
        logger.error("No node IPs found in any cluster. "
                     "Keeping the existing DBaaS IP filter.")
        return False

    desired = inventory.node_ips | static_ips
    logger.info(f"Desired IP filter ({len(desired)} entries): "
                f"{', '.join(sorted(normalise_cidrs(desired)))}")

    if apply_ip_filter(api, config['dbaas_services'], desired, config['dry_run']):
        logger.info("All DBaaS services are up to date.")
        return True

    logger.error("One or more updates failed. Retrying on the next cycle.")
    return False


def main():
    """Main automation loop."""
    config = get_config()

    logger.info("Starting DBaaS IP filter automation")
    logger.info(f"Monitoring {len(config['sks_clusters'])} SKS cluster(s)")
    logger.info(
        f"Managing IP filters for {len(config['dbaas_services'])} DBaaS service(s)")
    if config['dry_run']:
        logger.info("DRY_RUN is enabled: no IP filter will be modified")

    api = ExoscaleAPI(
        config['api_key'],
        config['api_secret'],
        max_retries=config['max_retries'],
        timeout=config['request_timeout'],
    )

    while True:
        try:
            run_cycle(api, config)
        except Exception as exc:
            logger.error(f"Error in main loop: {exc}")

        # Wait before next check
        time.sleep(config['check_interval'])


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        sys.exit(0)

"""Tests for exo-dbaas-filter.

Runs without any third-party dependency: `requests`, `urllib3` and `exoscale_auth`
are stubbed before the module under test is imported.
"""

import importlib.util
import logging
import os
import sys
import types
import unittest
from pathlib import Path
from unittest import mock


class RequestException(Exception):
    pass


class ExoscaleV2Auth:
    def __init__(self, *args, **kwargs):
        pass


def _stub_dependencies():
    requests_stub = types.ModuleType("requests")
    requests_stub.exceptions = types.SimpleNamespace(
        RequestException=RequestException)
    requests_stub.Session = object

    adapters_stub = types.ModuleType("requests.adapters")
    adapters_stub.HTTPAdapter = object
    requests_stub.adapters = adapters_stub

    retry_stub = types.ModuleType("urllib3.util.retry")
    retry_stub.Retry = object
    util_stub = types.ModuleType("urllib3.util")
    util_stub.retry = retry_stub
    urllib3_stub = types.ModuleType("urllib3")
    urllib3_stub.util = util_stub

    sys.modules["requests"] = requests_stub
    sys.modules["requests.adapters"] = adapters_stub
    sys.modules["urllib3"] = urllib3_stub
    sys.modules["urllib3.util"] = util_stub
    sys.modules["urllib3.util.retry"] = retry_stub
    sys.modules["exoscale_auth"] = types.SimpleNamespace(
        ExoscaleV2Auth=ExoscaleV2Auth)


_stub_dependencies()

module_path = Path(__file__).resolve().with_name("exo-dbaas-filter.py")
spec = importlib.util.spec_from_file_location("exo_dbaas_filter", module_path)
dbaas_filter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = dbaas_filter
spec.loader.exec_module(dbaas_filter)

# The module under test logs every decision; keep the test output readable.
logging.disable(logging.CRITICAL)


ZONE = "at-vie-1"
CLUSTER = "prod"


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------

class FakeAPI:
    """Duck-typed stand-in for ExoscaleAPI."""

    def __init__(self, clusters=None, pools=None, instances=None):
        self.clusters = [] if clusters is None else clusters
        self.pools = pools or {}
        self.instances = instances or {}

    def get_sks_clusters(self, zone):
        if isinstance(self.clusters, Exception):
            raise self.clusters
        return self.clusters

    def get_instance_pool(self, pool_id, zone):
        value = self.pools[pool_id]
        if isinstance(value, Exception):
            raise value
        return value

    def get_instance(self, instance_id, zone):
        value = self.instances[instance_id]
        if isinstance(value, Exception):
            raise value
        return value


def healthy(node_count=2, pool_id="pool-1", name=None,
            first_octet=10, id_prefix="i"):
    """Build a consistent single-nodepool cluster with `node_count` nodes."""
    name = CLUSTER if name is None else name
    instance_ids = [f"{id_prefix}-{n}" for n in range(node_count)]
    instances = {
        iid: {"id": iid, "name": iid,
              "public-ip": f"198.51.100.{first_octet + n}"}
        for n, iid in enumerate(instance_ids)
    }
    clusters = [{
        "id": f"id-{name}",
        "name": name,
        "nodepools": [{
            "name": "np-1",
            "size": node_count,
            "instance-pool": {"id": pool_id},
        }],
    }]
    pools = {pool_id: {
        "id": pool_id,
        "size": node_count,
        "instances": [{"id": iid} for iid in instance_ids],
    }}
    return FakeAPI(clusters=clusters, pools=pools, instances=instances)


def expected_ips(node_count=2, first_octet=10):
    return {f"198.51.100.{first_octet + n}/32" for n in range(node_count)}


def inventory(api, clusters=None):
    return dbaas_filter.gather_inventory(
        api, clusters or [{"name": CLUSTER, "zone": ZONE}])


# ---------------------------------------------------------------------------
# Inventory: the happy path still works
# ---------------------------------------------------------------------------

class InventoryHappyPathTest(unittest.TestCase):

    def test_reconciled_cluster_returns_node_ips(self):
        result = inventory(healthy(2))

        self.assertTrue(result.complete)
        self.assertEqual(result.node_ips, expected_ips(2))

    def test_zero_sized_nodepool_contributes_nothing(self):
        api = healthy(1)
        api.clusters[0]["nodepools"].append({
            "name": "np-empty", "size": 0, "instance-pool": {"id": "pool-2"}})
        api.pools["pool-2"] = {"id": "pool-2", "size": 0, "instances": []}

        self.assertEqual(inventory(api).node_ips, expected_ips(1))

    def test_multiple_nodepools_are_summed(self):
        api = healthy(1)
        api.clusters[0]["nodepools"].append({
            "name": "np-2", "size": 1, "instance-pool": {"id": "pool-2"}})
        api.pools["pool-2"] = {
            "id": "pool-2", "size": 1, "instances": [{"id": "i-b"}]}
        api.instances["i-b"] = {"id": "i-b", "public-ip": "198.51.100.99"}

        self.assertEqual(inventory(api).node_ips,
                         expected_ips(1) | {"198.51.100.99/32"})


# ---------------------------------------------------------------------------
# Inventory: degenerate but successful payloads must fail closed
# ---------------------------------------------------------------------------

class DegeneratePayloadTest(unittest.TestCase):
    """HTTP 200 responses that are missing data must never yield a partial set."""

    def test_missing_instances_key_holds(self):
        """The reported defect: pool.get('instances', []) silently returned []."""
        api = healthy(2)
        del api.pools["pool-1"]["instances"]

        self.assertFalse(inventory(api).complete)

    def test_missing_nodepools_key_holds(self):
        api = healthy(2)
        del api.clusters[0]["nodepools"]

        self.assertFalse(inventory(api).complete)

    def test_nodepool_without_size_holds(self):
        api = healthy(2)
        del api.clusters[0]["nodepools"][0]["size"]

        self.assertFalse(inventory(api).complete)

    def test_nodepool_with_non_integer_size_holds(self):
        api = healthy(2)
        api.clusters[0]["nodepools"][0]["size"] = "2"

        self.assertFalse(inventory(api).complete)

    def test_short_instance_list_holds(self):
        """size says 3, the pool returns 2 — an incomplete answer."""
        api = healthy(3)
        api.pools["pool-1"]["instances"].pop()

        self.assertFalse(inventory(api).complete)

    def test_instance_pool_size_disagreeing_with_nodepool_size_holds(self):
        api = healthy(2)
        api.pools["pool-1"]["size"] = 5

        self.assertFalse(inventory(api).complete)

    def test_missing_instance_pool_reference_holds(self):
        api = healthy(2)
        del api.clusters[0]["nodepools"][0]["instance-pool"]

        self.assertFalse(inventory(api).complete)

    def test_instance_without_public_ip_holds(self):
        api = healthy(2)
        del api.instances["i-1"]["public-ip"]

        self.assertFalse(inventory(api).complete)

    def test_instance_with_unparseable_public_ip_holds(self):
        api = healthy(2)
        api.instances["i-1"]["public-ip"] = "not-an-ip"

        self.assertFalse(inventory(api).complete)

    def test_duplicate_public_ips_hold(self):
        """Deduplication must not be mistaken for a complete inventory."""
        api = healthy(2)
        api.instances["i-1"]["public-ip"] = api.instances["i-0"]["public-ip"]

        self.assertFalse(inventory(api).complete)

    def test_pool_returning_a_different_object_holds(self):
        api = healthy(2)
        api.pools["pool-1"]["id"] = "some-other-pool"

        self.assertFalse(inventory(api).complete)

    def test_instance_returning_a_different_object_holds(self):
        api = healthy(2)
        api.instances["i-1"]["id"] = "some-other-instance"

        self.assertFalse(inventory(api).complete)

    def test_empty_cluster_list_holds(self):
        self.assertFalse(inventory(FakeAPI(clusters=[])).complete)

    def test_cluster_not_found_holds(self):
        api = healthy(2)
        api.clusters[0]["name"] = "a-different-cluster"

        self.assertFalse(inventory(api).complete)

    def test_non_list_cluster_payload_holds(self):
        self.assertFalse(inventory(FakeAPI(clusters={"unexpected": "shape"})).complete)


# ---------------------------------------------------------------------------
# Inventory: exceptions
# ---------------------------------------------------------------------------

class ExceptionHandlingTest(unittest.TestCase):

    def test_request_exception_holds(self):
        """Regression guard for the fail-closed behaviour added in PR #3."""
        self.assertFalse(inventory(
            FakeAPI(clusters=RequestException("api unavailable"))).complete)

    def test_value_error_from_non_json_body_holds(self):
        """resp.json() on a non-JSON 200 raises ValueError, not RequestException."""
        self.assertFalse(inventory(
            FakeAPI(clusters=ValueError("Expecting value"))).complete)

    def test_cluster_without_id_holds(self):
        api = healthy(2)
        del api.clusters[0]["id"]

        self.assertFalse(inventory(api).complete)

    def test_key_error_holds(self):
        """A KeyError is not a RequestException; it must still fail closed."""
        self.assertFalse(inventory(FakeAPI(clusters=KeyError("id"))).complete)

    def test_one_failing_cluster_marks_the_inventory_incomplete(self):
        api = healthy(2)
        clusters = [{"name": CLUSTER, "zone": ZONE},
                    {"name": "missing", "zone": ZONE}]
        result = dbaas_filter.gather_inventory(api, clusters)

        self.assertFalse(result.complete)
        self.assertEqual(result.node_ips, expected_ips(2),
                         "the healthy cluster's addresses must survive")


# ---------------------------------------------------------------------------
# CIDR normalisation
# ---------------------------------------------------------------------------

class NormalisationTest(unittest.TestCase):

    def test_bare_address_normalises_to_host_prefix(self):
        self.assertEqual(
            dbaas_filter.normalise_cidrs(["198.51.100.10"]),
            {"198.51.100.10/32"},
        )

    def test_equivalent_forms_compare_equal(self):
        self.assertEqual(
            dbaas_filter.normalise_cidrs(["198.51.100.10/32", "10.0.0.0/24"]),
            dbaas_filter.normalise_cidrs(["198.51.100.10", " 10.0.0.0/24 "]),
        )


# ---------------------------------------------------------------------------
# Applier
# ---------------------------------------------------------------------------

class FakeDbaasAPI:
    def __init__(self, current=None, fail=(), unreadable=False):
        self.current = {} if current is None else current
        self.fail = set(fail)
        self.unreadable = unreadable
        self.writes = []

    def get_dbaas_ip_filter(self, name, db_type, zone):
        if self.unreadable:
            raise RequestException("read refused")
        return self.current.get(name)

    def update_dbaas_ip_filter(self, name, db_type, zone, ip_filter):
        if name in self.fail:
            raise RequestException("update refused")
        self.writes.append((name, tuple(ip_filter)))


SERVICES = [
    {"name": "db-a", "zone": ZONE, "type": "pg"},
    {"name": "db-b", "zone": ZONE, "type": "pg"},
]


class ApplierTest(unittest.TestCase):

    def test_all_updates_succeed(self):
        api = FakeDbaasAPI()

        ok = dbaas_filter.apply_ip_filter(api, SERVICES, ["198.51.100.10/32"])

        self.assertTrue(ok)
        self.assertEqual(len(api.writes), 2)

    def test_single_failure_reports_failure(self):
        """A failed update must not be reported as success, or it is never retried."""
        api = FakeDbaasAPI(fail=["db-b"])

        ok = dbaas_filter.apply_ip_filter(api, SERVICES, ["198.51.100.10/32"])

        self.assertFalse(ok)
        self.assertEqual(len(api.writes), 1)

    def test_matching_filter_is_not_rewritten(self):
        api = FakeDbaasAPI(current={
            "db-a": ["198.51.100.10/32"], "db-b": ["198.51.100.10/32"]})

        ok = dbaas_filter.apply_ip_filter(api, SERVICES, ["198.51.100.10/32"])

        self.assertTrue(ok)
        self.assertEqual(api.writes, [])

    def test_non_canonical_echo_is_treated_as_matching(self):
        api = FakeDbaasAPI(current={
            "db-a": ["198.51.100.10"], "db-b": ["198.51.100.10"]})

        dbaas_filter.apply_ip_filter(api, SERVICES, ["198.51.100.10/32"])

        self.assertEqual(api.writes, [])

    def test_differing_filter_is_rewritten(self):
        api = FakeDbaasAPI(current={"db-a": ["203.0.113.1/32"]})

        dbaas_filter.apply_ip_filter(api, SERVICES, ["198.51.100.10/32"])

        self.assertEqual(len(api.writes), 2)

    def test_dry_run_writes_nothing(self):
        api = FakeDbaasAPI()

        ok = dbaas_filter.apply_ip_filter(
            api, SERVICES, ["198.51.100.10/32"], dry_run=True)

        self.assertTrue(ok)
        self.assertEqual(api.writes, [])


# ---------------------------------------------------------------------------
# Configuration validation
# ---------------------------------------------------------------------------

BASE_ENV = {
    "EXOSCALE_API_KEY": "key",
    "EXOSCALE_API_SECRET": "secret",
    "SKS_CLUSTERS": f"{CLUSTER}:{ZONE}",
    "DBAAS_SERVICES": f"db-a:{ZONE}:pg",
}


def config_with(**overrides):
    env = dict(BASE_ENV)
    env.update(overrides)
    with mock.patch.dict(os.environ, env, clear=True):
        return dbaas_filter.get_config()


class ConfigValidationTest(unittest.TestCase):

    def test_valid_configuration_parses(self):
        config = config_with(STATIC_IPS="203.0.113.0/24")

        self.assertEqual(config["sks_clusters"],
                         [{"name": CLUSTER, "zone": ZONE}])
        self.assertEqual(config["static_ips"], ["203.0.113.0/24"])

    def test_malformed_cluster_entry_exits(self):
        """Silently dropping this leaves zero clusters and a static-only write."""
        with self.assertRaises(SystemExit):
            config_with(SKS_CLUSTERS="missing-zone")

    def test_empty_cluster_list_exits(self):
        with self.assertRaises(SystemExit):
            config_with(SKS_CLUSTERS="")

    def test_malformed_service_entry_exits(self):
        with self.assertRaises(SystemExit):
            config_with(DBAAS_SERVICES=f"db-a:{ZONE}")

    def test_unknown_database_type_exits(self):
        with self.assertRaises(SystemExit):
            config_with(DBAAS_SERVICES=f"db-a:{ZONE}:oracle")

    def test_malformed_static_ip_exits(self):
        """One bad CIDR makes every PUT fail with 400 and updates stop silently."""
        with self.assertRaises(SystemExit):
            config_with(STATIC_IPS="not-a-cidr")

    def test_non_integer_check_interval_exits(self):
        with self.assertRaises(SystemExit):
            config_with(CHECK_INTERVAL="soon")

    def test_missing_credentials_exit(self):
        with self.assertRaises(SystemExit):
            config_with(EXOSCALE_API_KEY="")


# ---------------------------------------------------------------------------
# Inventory: a well-formed but node-free answer must not become a static-only write
# ---------------------------------------------------------------------------

class EmptyInventoryTest(unittest.TestCase):
    """The mechanism behind the reported outage: nothing here is malformed, yet
    the node set is empty. Merging STATIC_IPS would make it look like a valid
    result and replace the filter with the static entries alone."""

    def test_empty_nodepool_list_yields_no_nodes(self):
        api = FakeAPI(clusters=[{"id": "c1", "name": CLUSTER, "nodepools": []}])
        result = inventory(api)

        self.assertTrue(result.complete)
        self.assertEqual(result.node_ips, set())

    def test_all_nodepools_reporting_zero_yields_no_nodes(self):
        api = healthy(2)
        api.clusters[0]["nodepools"][0]["size"] = 0
        api.pools["pool-1"]["size"] = 0
        api.pools["pool-1"]["instances"] = []
        result = inventory(api)

        self.assertTrue(result.complete)
        self.assertEqual(result.node_ips, set())

    def test_zero_size_is_verified_against_the_instance_pool(self):
        """A stale 'size: 0' must not silently drop a pool that still runs nodes."""
        api = healthy(2)
        api.clusters[0]["nodepools"][0]["size"] = 0  # pool still lists 2 instances

        self.assertFalse(inventory(api).complete)

    def test_missing_sks_clusters_key_holds(self):
        self.assertFalse(inventory(FakeAPI(clusters=None)).complete)

    def test_ambiguous_cluster_name_holds(self):
        api = healthy(2)
        api.clusters.insert(0, {"id": "c0", "name": CLUSTER, "nodepools": []})

        self.assertFalse(inventory(api).complete)


# ---------------------------------------------------------------------------
# API client wiring
# ---------------------------------------------------------------------------

class ApiClientTest(unittest.TestCase):

    def test_endpoint_follows_the_documented_zone_template(self):
        self.assertEqual(
            dbaas_filter.ExoscaleAPI._endpoint("de-fra-1"),
            "https://api-de-fra-1.exoscale.com/v2",
        )

    def test_session_is_configured_with_bounded_retries(self):
        """Constructed nowhere else in the suite; a bad kwarg would only surface
        at container start."""
        recorded = {}

        class RecordingRetry:
            def __init__(self, **kwargs):
                recorded.update(kwargs)

        class RecordingAdapter:
            def __init__(self, max_retries=None):
                self.max_retries = max_retries

        class RecordingSession:
            def __init__(self):
                self.mounts = {}

            def mount(self, prefix, adapter):
                self.mounts[prefix] = adapter

        with mock.patch.object(dbaas_filter, "Retry", RecordingRetry), \
                mock.patch.object(dbaas_filter, "HTTPAdapter", RecordingAdapter), \
                mock.patch.object(dbaas_filter.requests, "Session",
                                  RecordingSession):
            api = dbaas_filter.ExoscaleAPI("key", "secret",
                                           max_retries=5, timeout=7)

        self.assertEqual(recorded["total"], 5)
        self.assertEqual(recorded["status_forcelist"],
                         dbaas_filter.RETRY_STATUSES)
        self.assertEqual(sorted(recorded["allowed_methods"]), ["GET", "PUT"])
        self.assertEqual(api.timeout, 7)
        self.assertIn("https://", api.session.mounts)


# ---------------------------------------------------------------------------
# One full cycle
# ---------------------------------------------------------------------------

class CycleAPI(FakeAPI):
    """Inventory and DBaaS behaviour in one object, as ExoscaleAPI provides."""

    def __init__(self, inventory, dbaas):
        super().__init__(clusters=inventory.clusters, pools=inventory.pools,
                         instances=inventory.instances)
        self.dbaas = dbaas

    def get_dbaas_ip_filter(self, name, db_type, zone):
        return self.dbaas.get_dbaas_ip_filter(name, db_type, zone)

    def update_dbaas_ip_filter(self, name, db_type, zone, ip_filter):
        return self.dbaas.update_dbaas_ip_filter(name, db_type, zone, ip_filter)


def cycle_config(clusters=None, **overrides):
    config = {
        "sks_clusters": clusters or [{"name": CLUSTER, "zone": ZONE}],
        "dbaas_services": SERVICES,
        "static_ips": [],
        "dry_run": False,
    }
    config.update(overrides)
    return config


class RunCycleTest(unittest.TestCase):

    def test_incomplete_inventory_removes_nothing(self):
        source = healthy(2)
        del source.pools["pool-1"]["instances"]
        dbaas = FakeDbaasAPI(current={"db-a": ["203.0.113.1/32"],
                                      "db-b": ["203.0.113.1/32"]})

        ok = dbaas_filter.run_cycle(
            CycleAPI(source, dbaas),
            cycle_config(static_ips=["203.0.113.10/32"]))

        self.assertFalse(ok, "an incomplete cycle must not report success")
        self.assertEqual(len(dbaas.writes), 2)
        for _, written in dbaas.writes:
            # the node addresses already there survive, the static IP is added,
            # and nothing from the unverifiable cluster is invented
            self.assertEqual(set(written),
                             {"203.0.113.1/32", "203.0.113.10/32"})

    def test_empty_inventory_with_static_ips_writes_nothing(self):
        source = FakeAPI(
            clusters=[{"id": "c1", "name": CLUSTER, "nodepools": []}])
        dbaas = FakeDbaasAPI()

        ok = dbaas_filter.run_cycle(
            CycleAPI(source, dbaas),
            cycle_config(static_ips=["203.0.113.10/32"]))

        self.assertFalse(ok)
        self.assertEqual(dbaas.writes, [])

    def test_complete_inventory_updates_every_service(self):
        dbaas = FakeDbaasAPI()

        ok = dbaas_filter.run_cycle(
            CycleAPI(healthy(2), dbaas), cycle_config())

        self.assertTrue(ok)
        self.assertEqual(len(dbaas.writes), 2)
        self.assertEqual(set(dbaas.writes[0][1]), expected_ips(2))

    def test_failed_update_is_reported(self):
        dbaas = FakeDbaasAPI(fail=["db-b"])

        ok = dbaas_filter.run_cycle(
            CycleAPI(healthy(2), dbaas), cycle_config())

        self.assertFalse(ok)

    def test_static_ips_are_written_in_canonical_form(self):
        """'10.0.0.5/24' must not be sent verbatim: the API may reject host bits,
        and it would never compare equal to what is read back."""
        dbaas = FakeDbaasAPI()

        dbaas_filter.run_cycle(
            CycleAPI(healthy(1), dbaas),
            cycle_config(static_ips=["10.0.0.5/24"]))

        self.assertIn("10.0.0.0/24", dbaas.writes[0][1])
        self.assertNotIn("10.0.0.5/24", dbaas.writes[0][1])

    def test_unreadable_current_filter_does_not_block_the_update(self):
        """A failing comparison must not starve updates; the list is complete."""
        dbaas = FakeDbaasAPI(unreadable=True)
        ok = dbaas_filter.run_cycle(
            CycleAPI(healthy(2), dbaas), cycle_config())

        self.assertTrue(ok)
        self.assertEqual(len(dbaas.writes), 2)

    def test_dry_run_writes_nothing(self):
        dbaas = FakeDbaasAPI()

        ok = dbaas_filter.run_cycle(
            CycleAPI(healthy(2), dbaas), cycle_config(dry_run=True))

        self.assertTrue(ok)
        self.assertEqual(dbaas.writes, [])


# ---------------------------------------------------------------------------
# Inventory across several clusters
# ---------------------------------------------------------------------------

OTHER = "staging"
BOTH = [{"name": CLUSTER, "zone": ZONE}, {"name": OTHER, "zone": ZONE}]


def two_clusters(broken=None):
    """Two healthy clusters; `broken` names the one with a short instance list."""
    a = healthy(2, pool_id="pool-a", name=CLUSTER, first_octet=10, id_prefix="a")
    b = healthy(2, pool_id="pool-b", name=OTHER, first_octet=20, id_prefix="b")
    api = FakeAPI(
        clusters=a.clusters + b.clusters,
        pools={**a.pools, **b.pools},
        instances={**a.instances, **b.instances},
    )
    if broken:
        api.pools["pool-a" if broken == CLUSTER else "pool-b"]["instances"].pop()
    return api


class MultiClusterInventoryTest(unittest.TestCase):

    def test_all_clusters_healthy(self):
        result = inventory(two_clusters(), BOTH)

        self.assertTrue(result.complete)
        self.assertEqual(result.node_ips,
                         expected_ips(2, 10) | expected_ips(2, 20))

    def test_one_broken_cluster_marks_the_inventory_incomplete(self):
        self.assertFalse(inventory(two_clusters(broken=OTHER), BOTH).complete)

    def test_a_broken_cluster_does_not_discard_the_healthy_one(self):
        """Its addresses stay usable as additions."""
        result = inventory(two_clusters(broken=OTHER), BOTH)

        self.assertEqual(result.node_ips, expected_ips(2, 10))

    def test_a_broken_first_cluster_does_not_stop_the_scan(self):
        result = inventory(two_clusters(broken=CLUSTER), BOTH)

        self.assertFalse(result.complete)
        self.assertEqual(result.node_ips, expected_ips(2, 20))


# ---------------------------------------------------------------------------
# Applier: additive mode
# ---------------------------------------------------------------------------

class AdditiveApplierTest(unittest.TestCase):
    """Used when a cluster could not be inventoried: add, never remove."""

    def test_existing_entries_are_kept(self):
        api = FakeDbaasAPI(current={"db-a": ["203.0.113.1/32"],
                                    "db-b": ["203.0.113.1/32"]})

        ok = dbaas_filter.apply_ip_filter(
            api, SERVICES, ["198.51.100.10/32"], additive=True)

        self.assertTrue(ok)
        self.assertEqual(len(api.writes), 2)
        for _, written in api.writes:
            self.assertEqual(set(written),
                             {"203.0.113.1/32", "198.51.100.10/32"})

    def test_nothing_new_issues_no_write(self):
        api = FakeDbaasAPI(current={"db-a": ["198.51.100.10/32"],
                                    "db-b": ["198.51.100.10/32"]})

        ok = dbaas_filter.apply_ip_filter(
            api, SERVICES, ["198.51.100.10/32"], additive=True)

        self.assertTrue(ok)
        self.assertEqual(api.writes, [])

    def test_unreadable_filter_skips_rather_than_replaces(self):
        """Without the current filter the union is unknowable, and writing the
        wanted set alone would remove everything else."""
        api = FakeDbaasAPI(unreadable=True)

        ok = dbaas_filter.apply_ip_filter(
            api, SERVICES, ["198.51.100.10/32"], additive=True)

        self.assertFalse(ok)
        self.assertEqual(api.writes, [])

    def test_empty_current_filter_is_populated(self):
        """An empty filter allows nothing, so writing into it only grants access."""
        api = FakeDbaasAPI(current={"db-a": [], "db-b": []})

        ok = dbaas_filter.apply_ip_filter(
            api, SERVICES, ["198.51.100.10/32"], additive=True)

        self.assertTrue(ok)
        self.assertEqual([set(w) for _, w in api.writes],
                         [{"198.51.100.10/32"}] * 2)

    def test_absent_current_filter_is_populated(self):
        """A missing ip-filter key is an empty filter, not an unknown one."""
        api = FakeDbaasAPI()

        ok = dbaas_filter.apply_ip_filter(
            api, SERVICES, ["198.51.100.10/32"], additive=True)

        self.assertTrue(ok)
        self.assertEqual(len(api.writes), 2)

    def test_superset_filter_is_left_alone(self):
        """The steady state while a cluster stays broken: no rewrite every cycle."""
        api = FakeDbaasAPI(current={
            "db-a": ["198.51.100.10/32", "203.0.113.1/32"],
            "db-b": ["198.51.100.10/32", "203.0.113.1/32"]})

        ok = dbaas_filter.apply_ip_filter(
            api, SERVICES, ["198.51.100.10/32"], additive=True)

        self.assertTrue(ok)
        self.assertEqual(api.writes, [])

    def test_dry_run_writes_nothing(self):
        api = FakeDbaasAPI(current={"db-a": ["203.0.113.1/32"],
                                    "db-b": ["203.0.113.1/32"]})

        ok = dbaas_filter.apply_ip_filter(
            api, SERVICES, ["198.51.100.10/32"], dry_run=True, additive=True)

        self.assertTrue(ok)
        self.assertEqual(api.writes, [])


# ---------------------------------------------------------------------------
# One cycle across several clusters
# ---------------------------------------------------------------------------

class RunCycleMultiClusterTest(unittest.TestCase):
    """A broken cluster must not freeze updates for the healthy ones."""

    EXISTING = ["198.51.100.20/32", "198.51.100.21/32"]   # staging's nodes

    def dbaas(self):
        return FakeDbaasAPI(current={"db-a": list(self.EXISTING),
                                     "db-b": list(self.EXISTING)})

    def test_healthy_cluster_additions_are_applied(self):
        dbaas = self.dbaas()

        ok = dbaas_filter.run_cycle(
            CycleAPI(two_clusters(broken=OTHER), dbaas),
            cycle_config(clusters=BOTH))

        self.assertFalse(ok, "an incomplete cycle must not report success")
        self.assertEqual(len(dbaas.writes), 2)
        for _, written in dbaas.writes:
            self.assertEqual(set(written),
                             set(self.EXISTING) | expected_ips(2, 10))

    def test_uninventoried_cluster_entries_are_not_removed(self):
        dbaas = self.dbaas()

        dbaas_filter.run_cycle(
            CycleAPI(two_clusters(broken=OTHER), dbaas),
            cycle_config(clusters=BOTH))

        self.assertEqual(len(dbaas.writes), 2, "no write was issued at all")
        for _, written in dbaas.writes:
            self.assertTrue(set(self.EXISTING) <= set(written),
                            "entries of the uninventoried cluster were removed")

    def test_complete_inventory_still_applies_removals(self):
        """With a full picture, stale entries are replaced rather than merged."""
        dbaas = FakeDbaasAPI(current={"db-a": ["203.0.113.99/32"],
                                      "db-b": ["203.0.113.99/32"]})

        ok = dbaas_filter.run_cycle(
            CycleAPI(two_clusters(), dbaas), cycle_config(clusters=BOTH))

        self.assertTrue(ok)
        self.assertEqual(len(dbaas.writes), 2, "no write was issued at all")
        for _, written in dbaas.writes:
            self.assertNotIn("203.0.113.99/32", written)
            self.assertEqual(set(written),
                             expected_ips(2, 10) | expected_ips(2, 20))


    def test_every_cluster_failing_removes_nothing(self):
        dbaas = self.dbaas()
        source = FakeAPI(clusters=RequestException("api down"))

        ok = dbaas_filter.run_cycle(
            CycleAPI(source, dbaas),
            cycle_config(clusters=BOTH, static_ips=["203.0.113.10/32"]))

        self.assertFalse(ok)
        self.assertEqual(len(dbaas.writes), 2)
        for _, written in dbaas.writes:
            self.assertEqual(set(written),
                             set(self.EXISTING) | {"203.0.113.10/32"})

    def test_recovery_removes_what_the_broken_cycles_accumulated(self):
        """Entries kept while a cluster was unreachable are cleared by the first
        fully reconciled cycle."""
        dbaas = self.dbaas()

        # While staging is broken, prod's nodes are added and nothing is removed.
        dbaas_filter.run_cycle(CycleAPI(two_clusters(broken=OTHER), dbaas),
                               cycle_config(clusters=BOTH))
        accumulated = set(dbaas.writes[-1][1])
        self.assertTrue(set(self.EXISTING) <= accumulated)

        # staging recovers: the picture is complete, so the filter is replaced.
        dbaas.current = {name: list(accumulated) for name in ("db-a", "db-b")}
        ok = dbaas_filter.run_cycle(CycleAPI(two_clusters(), dbaas),
                                    cycle_config(clusters=BOTH))

        self.assertTrue(ok)
        self.assertEqual(set(dbaas.writes[-1][1]),
                         expected_ips(2, 10) | expected_ips(2, 20))

    def test_partial_inventory_with_unreadable_filter_writes_nothing(self):
        dbaas = FakeDbaasAPI(unreadable=True)

        ok = dbaas_filter.run_cycle(
            CycleAPI(two_clusters(broken=OTHER), dbaas),
            cycle_config(clusters=BOTH))

        self.assertFalse(ok)
        self.assertEqual(dbaas.writes, [])


if __name__ == "__main__":
    unittest.main()

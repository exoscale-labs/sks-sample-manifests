import importlib.util
import sys
import types
import unittest
from pathlib import Path


class RequestException(Exception):
    pass


class ExoscaleV2Auth:
    def __init__(self, *args, **kwargs):
        pass


sys.modules["requests"] = types.SimpleNamespace(
    exceptions=types.SimpleNamespace(RequestException=RequestException)
)
sys.modules["exoscale_auth"] = types.SimpleNamespace(ExoscaleV2Auth=ExoscaleV2Auth)

module_path = Path(__file__).resolve().with_name("exo-dbaas-filter.py")
spec = importlib.util.spec_from_file_location("exo_dbaas_filter", module_path)
dbaas_filter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = dbaas_filter
spec.loader.exec_module(dbaas_filter)


class FailingAPI:
    def get_sks_clusters(self, zone):
        raise RequestException("api unavailable")


class WorkingAPI:
    def get_sks_clusters(self, zone):
        return [{"name": "prod", "id": "cluster-id"}]

    def get_sks_cluster(self, cluster_id, zone):
        return {"nodepools": [{"instance-pool": {"id": "pool-id"}}]}

    def get_instance_pool(self, pool_id, zone):
        return {"instances": [{"id": "instance-id"}]}

    def get_instance(self, instance_id, zone):
        return {"name": "node-1", "public-ip": "198.51.100.10"}


class DbaasFilterTest(unittest.TestCase):
    def test_cluster_lookup_failure_skips_static_only_update(self):
        ips = dbaas_filter.gather_all_ips(
            FailingAPI(),
            [{"name": "prod", "zone": "at-vie-1"}],
            ["203.0.113.10/32"],
        )

        self.assertIsNone(ips)

    def test_successful_lookup_includes_node_and_static_ips(self):
        ips = dbaas_filter.gather_all_ips(
            WorkingAPI(),
            [{"name": "prod", "zone": "at-vie-1"}],
            ["203.0.113.10/32"],
        )

        self.assertEqual(ips, {"198.51.100.10/32", "203.0.113.10/32"})


if __name__ == "__main__":
    unittest.main()

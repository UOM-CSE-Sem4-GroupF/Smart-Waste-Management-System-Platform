"""
Component tests for gateway/kong/kong-config.yaml.
Validates the Kong DB-less declarative config structure without a running cluster.
"""
import os
import pytest
import yaml

KONG_CONFIG_PATH = os.path.join(
    os.path.dirname(__file__), '..', '..', '..', 'gateway', 'kong', 'kong-config.yaml'
)


@pytest.fixture(scope="module")
def kong_config():
    with open(KONG_CONFIG_PATH) as f:
        configmap = yaml.safe_load(f)
    raw = configmap['data']['kong.yaml']
    return yaml.safe_load(raw)


@pytest.fixture(scope="module")
def services(kong_config):
    return kong_config.get('services', [])


@pytest.fixture(scope="module")
def service_names(services):
    return {s['name'] for s in services}


@pytest.fixture(scope="module")
def all_routes(services):
    routes = []
    for svc in services:
        for route in svc.get('routes', []):
            routes.append({'service': svc['name'], 'route': route})
    return routes


@pytest.mark.component
def test_config_uses_format_version_3(kong_config):
    assert kong_config['_format_version'] == '3.0'


@pytest.mark.component
def test_all_services_have_url(services):
    for svc in services:
        assert 'url' in svc, f"Service '{svc['name']}' missing url"
        assert svc['url'].startswith('http://'), \
            f"Service '{svc['name']}' url should be http:// cluster-internal"


@pytest.mark.component
def test_all_routes_have_at_least_one_path(all_routes):
    for entry in all_routes:
        route = entry['route']
        assert route.get('paths'), \
            f"Route '{route.get('name')}' on service '{entry['service']}' has no paths"


@pytest.mark.component
def test_cors_plugin_on_all_api_routes(all_routes):
    for entry in all_routes:
        route = entry['route']
        plugin_names = [p['name'] for p in route.get('plugins', [])]
        assert 'cors' in plugin_names, \
            f"Route '{route.get('name')}' on '{entry['service']}' missing cors plugin"


@pytest.mark.component
def test_rate_limiting_on_all_routes(all_routes):
    for entry in all_routes:
        route = entry['route']
        plugin_names = [p['name'] for p in route.get('plugins', [])]
        assert 'rate-limiting' in plugin_names, \
            f"Route '{route.get('name')}' on '{entry['service']}' missing rate-limiting plugin"


@pytest.mark.component
def test_expected_services_present(service_names):
    expected = {
        'bin-status', 'orchestrator', 'scheduler', 'core-api',
        'ml-service', 'route-optimizer', 'notification',
    }
    for name in expected:
        assert name in service_names, f"Expected service '{name}' not found in kong config"


@pytest.mark.component
def test_bin_status_exposes_bins_and_zones_routes(services):
    bin_status = next(s for s in services if s['name'] == 'bin-status')
    route_paths = [p for r in bin_status['routes'] for p in r['paths']]
    assert '/api/v1/bins' in route_paths
    assert '/api/v1/zones' in route_paths


@pytest.mark.component
def test_no_internal_paths_exposed(all_routes):
    for entry in all_routes:
        for path in entry['route'].get('paths', []):
            assert not path.startswith('/internal'), \
                f"Internal path '{path}' exposed on route '{entry['route'].get('name')}'"


@pytest.mark.component
def test_notification_service_has_socket_io_route(services):
    notif = next((s for s in services if s['name'] == 'notification'), None)
    assert notif is not None
    paths = [p for r in notif['routes'] for p in r['paths']]
    assert '/socket.io' in paths


@pytest.mark.component
def test_global_plugins_include_correlation_id(kong_config):
    global_plugin_names = [p['name'] for p in kong_config.get('plugins', [])]
    assert 'correlation-id' in global_plugin_names


@pytest.mark.component
def test_global_plugins_include_file_log(kong_config):
    global_plugin_names = [p['name'] for p in kong_config.get('plugins', [])]
    assert 'file-log' in global_plugin_names


@pytest.mark.component
def test_all_services_use_cluster_internal_dns(services):
    for svc in services:
        assert 'svc.cluster.local' in svc['url'], \
            f"Service '{svc['name']}' url '{svc['url']}' not using cluster-internal DNS"

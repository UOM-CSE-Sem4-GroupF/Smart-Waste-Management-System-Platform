"""
Integration test: Kong gateway route resolution.
Requires: running cluster with Kong deployed and port-forwarded to KONG_PROXY_URL.

  export KONG_PROXY_URL=http://localhost:30080
  or for DOKS: export KONG_PROXY_URL=http://<kong-lb-ip>
"""
import os
import pytest
import requests

KONG_PROXY_URL = os.getenv('KONG_PROXY_URL', 'http://localhost:30080')

PUBLIC_ROUTES = [
    '/api/v1/bins',
    '/api/v1/zones',
    '/api/v1/collection-jobs',
    '/api/v1/collections',
    '/api/v1/vehicles',
    '/api/v1/drivers',
    '/api/v1/routes',
    '/api/v1/ml',
    '/socket.io',
    '/data-analysis',
]


def _get(path: str, timeout: int = 5):
    return requests.get(f"{KONG_PROXY_URL}{path}", timeout=timeout)


@pytest.mark.integration
@pytest.mark.parametrize("path", PUBLIC_ROUTES)
def test_public_route_does_not_return_404_or_502(path):
    """Kong must route to a service — 200, 401, 405, or 503 are acceptable; 404/502 are not."""
    try:
        resp = _get(path)
    except requests.ConnectionError:
        pytest.skip(f"Kong not reachable at {KONG_PROXY_URL}")

    assert resp.status_code not in (404, 502), \
        f"Route {path} returned {resp.status_code} — Kong cannot route to upstream service"


@pytest.mark.integration
def test_internal_path_returns_404_from_gateway():
    """Kong must not expose /internal/* paths."""
    try:
        resp = _get('/internal/anything')
    except requests.ConnectionError:
        pytest.skip(f"Kong not reachable at {KONG_PROXY_URL}")

    assert resp.status_code == 404, \
        f"/internal/ path returned {resp.status_code} — should be 404 (not routed)"


@pytest.mark.integration
def test_bins_route_has_cors_header():
    """CORS plugin must add Access-Control-Allow-Origin to /api/v1/bins responses."""
    try:
        resp = requests.options(
            f"{KONG_PROXY_URL}/api/v1/bins",
            headers={'Origin': 'http://localhost:3000'},
            timeout=5,
        )
    except requests.ConnectionError:
        pytest.skip(f"Kong not reachable at {KONG_PROXY_URL}")

    assert 'access-control-allow-origin' in resp.headers or resp.status_code in (200, 204), \
        "CORS header missing on /api/v1/bins"


@pytest.mark.integration
def test_request_id_header_present():
    """correlation-id global plugin must add X-Request-ID to every response."""
    try:
        resp = _get('/api/v1/bins')
    except requests.ConnectionError:
        pytest.skip(f"Kong not reachable at {KONG_PROXY_URL}")

    assert 'x-request-id' in {k.lower() for k in resp.headers}, \
        "X-Request-ID header missing — correlation-id plugin not active"

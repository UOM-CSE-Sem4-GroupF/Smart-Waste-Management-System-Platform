"""
Integration test: health checks for all deployed services.
Requires: running cluster with services deployed, kubectl in PATH.

Uses kubectl port-forward to reach each service then calls GET /health.
"""
import os
import subprocess
import time
import threading
import pytest
import requests

SERVICES = [
    {'name': 'bin-status',      'namespace': 'waste-dev', 'port': 3002, 'path': '/health'},
    {'name': 'orchestrator',    'namespace': 'waste-dev', 'port': 3001, 'path': '/health'},
    {'name': 'scheduler',       'namespace': 'waste-dev', 'port': 3003, 'path': '/health'},
    {'name': 'notification',    'namespace': 'waste-dev', 'port': 3004, 'path': '/health'},
    {'name': 'core-api',        'namespace': 'waste-dev', 'port': 8001, 'path': '/health'},
    {'name': 'ml-service',      'namespace': 'waste-dev', 'port': 8000, 'path': '/health'},
    {'name': 'route-optimizer', 'namespace': 'waste-dev', 'port': 8083, 'path': '/health'},
]

LOCAL_BASE_PORT = 19000


def _port_forward(svc_name: str, namespace: str, remote_port: int, local_port: int):
    """Start kubectl port-forward in background. Returns (proc, stop_event)."""
    cmd = [
        'kubectl', 'port-forward',
        f'svc/{svc_name}', f'{local_port}:{remote_port}',
        '-n', namespace,
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)
    return proc


@pytest.mark.integration
@pytest.mark.parametrize("svc", SERVICES, ids=lambda s: s['name'])
def test_service_health_endpoint(svc):
    import shutil
    if not shutil.which('kubectl'):
        pytest.skip("kubectl not in PATH")

    local_port = LOCAL_BASE_PORT + SERVICES.index(svc)
    proc = _port_forward(svc['name'], svc['namespace'], svc['port'], local_port)

    try:
        url = f"http://localhost:{local_port}{svc['path']}"
        resp = requests.get(url, timeout=5)
        assert resp.status_code == 200, \
            f"{svc['name']} health check returned {resp.status_code}"
    finally:
        proc.terminate()


@pytest.mark.integration
@pytest.mark.parametrize("svc", SERVICES, ids=lambda s: s['name'])
def test_service_health_response_is_json(svc):
    import shutil
    if not shutil.which('kubectl'):
        pytest.skip("kubectl not in PATH")

    local_port = LOCAL_BASE_PORT + 100 + SERVICES.index(svc)
    proc = _port_forward(svc['name'], svc['namespace'], svc['port'], local_port)

    try:
        url = f"http://localhost:{local_port}{svc['path']}"
        resp = requests.get(url, timeout=5)
        assert resp.status_code == 200
        body = resp.json()
        assert 'status' in body, f"{svc['name']} health response missing 'status' field"
    finally:
        proc.terminate()

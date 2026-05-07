"""
Component tests for rendered Kubernetes manifests.
Renders each service chart with helm template and checks security invariants.
Uses conftest/OPA policies if conftest CLI is installed; otherwise falls back
to inline Python assertions.

Requirements: helm, helm dependency update run for all apps/
Optional: conftest CLI (https://www.conftest.dev/) for OPA policy enforcement
"""
import os
import re
import subprocess
import shutil
import pytest
import yaml

REPO_ROOT = os.path.join(os.path.dirname(__file__), '..', '..', '..')

APPS = [
    'bin-status', 'core-api', 'frontend', 'orchestrator', 'scheduler',
    'notification', 'ml-service', 'route-optimizer',
    'flink-deviation', 'flink-sensor', 'flink-telemetry', 'flink-vehicle', 'flink-zone',
]

# Flink apps intentionally run as root (PyFlink requirement)
FLINK_APPS = {'flink-deviation', 'flink-sensor', 'flink-telemetry', 'flink-vehicle', 'flink-zone'}


def render_chart(app_name):
    """Run helm template and return list of parsed YAML documents."""
    chart_path = os.path.join(REPO_ROOT, 'apps', app_name)
    values_path = os.path.join(chart_path, 'values-dev.yaml')
    subprocess.run(
        ['helm', 'dependency', 'build', chart_path],
        capture_output=True, check=False
    )
    result = subprocess.run(
        ['helm', 'template', app_name, chart_path, '-f', values_path],
        capture_output=True, text=True, check=True
    )
    docs = list(yaml.safe_load_all(result.stdout))
    return [d for d in docs if d is not None]


def get_deployments(docs):
    return [d for d in docs if d.get('kind') == 'Deployment']


@pytest.mark.component
@pytest.mark.parametrize("app", [a for a in APPS if a not in FLINK_APPS])
def test_deployment_has_resource_requests(app):
    if not shutil.which('helm'):
        pytest.skip("helm not installed")
    docs = render_chart(app)
    deployments = get_deployments(docs)
    assert deployments, f"No Deployment rendered for {app}"
    for dep in deployments:
        for container in dep['spec']['template']['spec']['containers']:
            assert container.get('resources', {}).get('requests'), \
                f"{app}: container '{container['name']}' missing resource requests"


@pytest.mark.component
@pytest.mark.parametrize("app", [a for a in APPS if a not in FLINK_APPS])
def test_deployment_has_resource_limits(app):
    if not shutil.which('helm'):
        pytest.skip("helm not installed")
    docs = render_chart(app)
    for dep in get_deployments(docs):
        for container in dep['spec']['template']['spec']['containers']:
            assert container.get('resources', {}).get('limits'), \
                f"{app}: container '{container['name']}' missing resource limits"


@pytest.mark.component
@pytest.mark.parametrize("app", [a for a in APPS if a not in FLINK_APPS])
def test_non_flink_deployment_runs_as_non_root(app):
    if not shutil.which('helm'):
        pytest.skip("helm not installed")
    docs = render_chart(app)
    for dep in get_deployments(docs):
        pod_sec = dep['spec']['template']['spec'].get('securityContext', {})
        assert pod_sec.get('runAsNonRoot') is True, \
            f"{app}: podSecurityContext.runAsNonRoot must be true"


@pytest.mark.component
@pytest.mark.parametrize("app", [a for a in APPS if a not in FLINK_APPS])
def test_containers_disallow_privilege_escalation(app):
    if not shutil.which('helm'):
        pytest.skip("helm not installed")
    docs = render_chart(app)
    for dep in get_deployments(docs):
        for container in dep['spec']['template']['spec']['containers']:
            ctx = container.get('securityContext', {})
            assert ctx.get('allowPrivilegeEscalation') is False, \
                f"{app}: '{container['name']}' allowPrivilegeEscalation must be false"


@pytest.mark.component
@pytest.mark.parametrize("app", APPS)
def test_opa_policies_via_conftest(app, tmp_path):
    """Run OPA policies using conftest CLI if available."""
    if not shutil.which('conftest') or not shutil.which('helm'):
        pytest.skip("conftest or helm not installed")

    chart_path = os.path.join(REPO_ROOT, 'apps', app)
    values_path = os.path.join(chart_path, 'values-dev.yaml')
    manifest_file = tmp_path / f"{app}.yaml"

    render = subprocess.run(
        ['helm', 'template', app, chart_path, '-f', values_path],
        capture_output=True, text=True, check=True
    )
    manifest_file.write_text(render.stdout)

    policy_dir = os.path.join(os.path.dirname(__file__), 'policies')
    result = subprocess.run(
        ['conftest', 'test', str(manifest_file), '--policy', policy_dir,
         '--namespace', 'swms.resources'],
        capture_output=True, text=True
    )
    assert result.returncode == 0, \
        f"OPA policy violations for {app}:\n{result.stdout}\n{result.stderr}"

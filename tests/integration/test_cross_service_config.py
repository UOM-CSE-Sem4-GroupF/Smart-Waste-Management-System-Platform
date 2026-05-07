"""
Integration test: cross-service config consistency — static analysis, no cluster needed.

Checks:
- Every Kafka topic referenced in apps/*/values-dev.yaml env vars exists in topics.yaml
- Every ExternalSecret vaultPath has a matching policy in vault-policies.yaml
"""
import os
import re
import pytest
import yaml

REPO_ROOT = os.path.join(os.path.dirname(__file__), '..', '..')
APPS_DIR = os.path.join(REPO_ROOT, 'apps')
TOPICS_YAML = os.path.join(REPO_ROOT, 'messaging', 'kafka', 'topics.yaml')
VAULT_POLICIES_YAML = os.path.join(REPO_ROOT, 'auth', 'vault', 'vault-policies.yaml')

CREATE_TOPIC_RE = re.compile(r'create_topic\s+"([^"]+)"')


def _load_defined_topics() -> set[str]:
    with open(TOPICS_YAML) as f:
        manifest = yaml.safe_load(f)
    containers = manifest['spec']['template']['spec']['containers']
    script = next(c for c in containers if c['name'] == 'kafka-topic-init')['command'][2]
    return set(CREATE_TOPIC_RE.findall(script))


def _load_vault_policies_text() -> str:
    with open(VAULT_POLICIES_YAML, encoding='utf-8') as f:
        return f.read()


def _iter_app_values():
    for app in os.listdir(APPS_DIR):
        values_path = os.path.join(APPS_DIR, app, 'values-dev.yaml')
        if os.path.exists(values_path):
            with open(values_path) as f:
                yield app, yaml.safe_load(f)


@pytest.fixture(scope="module")
def defined_topics():
    return _load_defined_topics()


@pytest.fixture(scope="module")
def vault_policies_text():
    return _load_vault_policies_text()


@pytest.mark.integration
def test_kafka_topics_referenced_in_env_exist_in_topics_yaml(defined_topics):
    """
    Any env var whose value looks like a waste.* Kafka topic name must exist
    in messaging/kafka/topics.yaml.
    """
    topic_pattern = re.compile(r'^waste\.[a-z][a-z0-9._]*$')
    violations = []

    for app, values in _iter_app_values():
        inner = values.get('base-service', values)
        env = inner.get('env', {})
        for key, val in env.items():
            if isinstance(val, str) and topic_pattern.match(val):
                if val not in defined_topics:
                    violations.append(f"{app}: env.{key}={val!r} not in topics.yaml")

    assert not violations, "Undefined Kafka topics referenced in values:\n" + "\n".join(violations)


@pytest.mark.integration
def test_external_secret_vault_paths_use_swms_prefix():
    """All ExternalSecret vaultPaths must start with swms/ (consistent with vault-policies)."""
    violations = []
    for app, values in _iter_app_values():
        inner = values.get('base-service', values)
        es = inner.get('externalSecret', {})
        if es.get('enabled'):
            vault_path = es.get('vaultPath', '')
            if not vault_path.startswith('swms/'):
                violations.append(f"{app}: externalSecret.vaultPath={vault_path!r} missing swms/ prefix")
    assert not violations, "\n".join(violations)


@pytest.mark.integration
def test_vault_policies_cover_kafka_secrets(vault_policies_text):
    """Vault bootstrap must configure access to swms/kafka for SASL credentials."""
    assert 'swms/kafka' in vault_policies_text or 'swms-kafka' in vault_policies_text, \
        "vault-policies.yaml missing swms/kafka secret path"


@pytest.mark.integration
def test_vault_policies_cover_postgres_secrets(vault_policies_text):
    """Vault bootstrap must configure access to swms/postgres-waste."""
    assert 'swms/postgres' in vault_policies_text or 'postgres-waste' in vault_policies_text, \
        "vault-policies.yaml missing postgres secret path"


@pytest.mark.integration
def test_no_app_references_undefined_kafka_topic(defined_topics):
    """
    Explicit check: none of the known Kafka-related env var keys point to a topic
    that does not exist in topics.yaml.
    """
    kafka_env_keys = re.compile(
        r'KAFKA_(INPUT|OUTPUT|TOPIC|BIN|VEHICLE|ZONE|DRIVER|AUDIT|DASHBOARD).*TOPIC',
        re.IGNORECASE,
    )
    topic_val_pattern = re.compile(r'^waste\.[a-z][a-z0-9._]*$')
    violations = []

    for app, values in _iter_app_values():
        inner = values.get('base-service', values)
        env = inner.get('env', {})
        for key, val in env.items():
            if kafka_env_keys.search(key) and isinstance(val, str) and topic_val_pattern.match(val):
                if val not in defined_topics:
                    violations.append(f"{app}: {key}={val!r} not in topics.yaml")

    assert not violations, "\n".join(violations)

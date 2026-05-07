"""
Component tests for messaging/kafka/topics.yaml.
Parses the Kubernetes Job manifest and validates topic definitions
extracted from the embedded shell script.
"""
import os
import re
import pytest
import yaml

TOPICS_PATH = os.path.join(
    os.path.dirname(__file__), '..', '..', '..', 'messaging', 'kafka', 'topics.yaml'
)

EXPECTED_TOPICS = {
    'waste.bin.telemetry',
    'waste.vehicle.location',
    'waste.bin.processed',
    'waste.routine.schedule.trigger',
    'waste.zone.statistics',
    'waste.bin.dashboard.updates',
    'waste.vehicle.dashboard.updates',
    'waste.driver.responses',
    'waste.vehicle.deviation',
    'waste.job.completed',
    'waste.audit.events',
    'waste.model.retrained',
}

TOPIC_PATTERN = re.compile(r'waste\.[a-z]+\.[a-z._]+')
CREATE_TOPIC_RE = re.compile(
    r'create_topic\s+"([^"]+)"\s+(\d+)\s+(\d+)\s+(\d+)'
)


@pytest.fixture(scope="module")
def topics_manifest():
    with open(TOPICS_PATH) as f:
        return yaml.safe_load(f)


@pytest.fixture(scope="module")
def shell_script(topics_manifest):
    """Extract the bash script string from the Job container command."""
    containers = topics_manifest['spec']['template']['spec']['containers']
    main_container = next(c for c in containers if c['name'] == 'kafka-topic-init')
    # command is ['/bin/bash', '-c', '<script>']
    return main_container['command'][2]


@pytest.fixture(scope="module")
def parsed_topics(shell_script):
    """Return list of (name, partitions, replication, retention_ms) tuples."""
    return CREATE_TOPIC_RE.findall(shell_script)


@pytest.mark.component
def test_manifest_is_a_job(topics_manifest):
    assert topics_manifest['kind'] == 'Job'


@pytest.mark.component
def test_job_in_messaging_namespace(topics_manifest):
    assert topics_manifest['metadata']['namespace'] == 'messaging'


@pytest.mark.component
def test_all_expected_topics_defined(parsed_topics):
    defined = {t[0] for t in parsed_topics}
    missing = EXPECTED_TOPICS - defined
    assert not missing, f"Missing topics: {missing}"


@pytest.mark.component
def test_no_duplicate_topic_names(parsed_topics):
    names = [t[0] for t in parsed_topics]
    assert len(names) == len(set(names)), \
        f"Duplicate topics: {[n for n in names if names.count(n) > 1]}"


@pytest.mark.component
def test_topic_naming_convention(parsed_topics):
    """All topics must follow waste.<entity>.<event> pattern."""
    for name, *_ in parsed_topics:
        parts = name.split('.')
        assert parts[0] == 'waste', f"Topic '{name}' must start with 'waste.'"
        assert len(parts) >= 3, f"Topic '{name}' must have at least 3 segments"
        for part in parts:
            assert re.match(r'^[a-z][a-z0-9_]*$', part), \
                f"Topic segment '{part}' in '{name}' has invalid characters"


@pytest.mark.component
def test_partition_count_at_least_one(parsed_topics):
    for name, partitions, *_ in parsed_topics:
        assert int(partitions) >= 1, f"Topic '{name}' has {partitions} partitions"


@pytest.mark.component
def test_retention_values_are_positive_integers(parsed_topics):
    for name, _, _, retention_ms in parsed_topics:
        assert int(retention_ms) > 0, f"Topic '{name}' has non-positive retention_ms"


@pytest.mark.component
def test_high_throughput_topics_have_6_partitions(parsed_topics):
    """Ingestion-layer and dashboard topics should have 6 partitions for throughput."""
    high_throughput = {
        'waste.bin.telemetry',
        'waste.vehicle.location',
        'waste.bin.dashboard.updates',
        'waste.vehicle.dashboard.updates',
        'waste.bin.processed',
    }
    topic_map = {t[0]: int(t[1]) for t in parsed_topics}
    for name in high_throughput:
        if name in topic_map:
            assert topic_map[name] == 6, \
                f"Expected 6 partitions for '{name}', got {topic_map[name]}"


@pytest.mark.component
def test_audit_topic_has_long_retention(parsed_topics):
    """waste.audit.events should retain for at least 30 days (2592000000 ms)."""
    topic_map = {t[0]: int(t[3]) for t in parsed_topics}
    assert topic_map['waste.audit.events'] >= 2_592_000_000

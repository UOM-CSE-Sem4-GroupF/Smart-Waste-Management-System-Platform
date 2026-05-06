"""
Integration test: Kafka produce → consume round-trip.
Extends verify_external_kafka.py with structured pytest assertions.

Requires: running Kafka cluster accessible via KAFKA_BROKER env var.
  export KAFKA_BROKER=<host>:9092
  export KAFKA_USER=user1
  export KAFKA_PASS=<password>
"""
import json
import os
import time
import pytest

try:
    from kafka import KafkaProducer, KafkaConsumer, TopicPartition
    from kafka.errors import KafkaError
    KAFKA_AVAILABLE = True
except ImportError:
    KAFKA_AVAILABLE = False

KAFKA_BROKER = os.getenv('KAFKA_BROKER', 'kafka.messaging.svc.cluster.local:9092')
KAFKA_USER = os.getenv('KAFKA_USER', 'user1')
KAFKA_PASS = os.getenv('KAFKA_PASS', '')
TEST_TOPIC = 'waste.bin.telemetry'

SASL_CONFIG = dict(
    security_protocol='SASL_PLAINTEXT',
    sasl_mechanism='SCRAM-SHA-256',
    sasl_plain_username=KAFKA_USER,
    sasl_plain_password=KAFKA_PASS,
)


@pytest.fixture(scope="module")
def producer():
    if not KAFKA_AVAILABLE:
        pytest.skip("kafka-python not installed")
    if not KAFKA_PASS:
        pytest.skip("KAFKA_PASS not set")
    p = KafkaProducer(
        bootstrap_servers=[KAFKA_BROKER],
        **SASL_CONFIG,
        value_serializer=lambda v: json.dumps(v).encode('utf-8'),
        request_timeout_ms=15_000,
        acks='all',
    )
    yield p
    p.close()


@pytest.mark.integration
def test_produce_to_bin_telemetry(producer):
    msg = {
        'version': '1.0',
        'source_service': 'pytest-integration',
        'timestamp': int(time.time() * 1000),
        'payload': {'bin_id': 'TEST-001', 'fill_level_pct': 55.0},
    }
    future = producer.send(TEST_TOPIC, value=msg)
    record = future.get(timeout=15)
    producer.flush()
    assert record.topic == TEST_TOPIC
    assert record.partition >= 0
    assert record.offset >= 0


@pytest.mark.integration
def test_roundtrip_message_intact(producer):
    if not KAFKA_AVAILABLE:
        pytest.skip("kafka-python not installed")

    test_payload = {
        'version': '1.0',
        'source_service': 'pytest-roundtrip',
        'timestamp': int(time.time() * 1000),
        'payload': {'bin_id': 'TEST-ROUNDTRIP', 'fill_level_pct': 42.0},
    }

    future = producer.send(TEST_TOPIC, value=test_payload)
    record = future.get(timeout=15)
    producer.flush()

    consumer = KafkaConsumer(
        bootstrap_servers=[KAFKA_BROKER],
        group_id=None,
        **SASL_CONFIG,
        value_deserializer=lambda x: json.loads(x.decode('utf-8')),
        request_timeout_ms=15_000,
        consumer_timeout_ms=10_000,
    )
    tp = TopicPartition(TEST_TOPIC, record.partition)
    consumer.assign([tp])
    consumer.seek(tp, record.offset)

    received = None
    for message in consumer:
        received = message.value
        break
    consumer.close()

    assert received is not None, "Consumer timed out — message not received"
    assert received['source_service'] == 'pytest-roundtrip'
    assert received['payload']['bin_id'] == 'TEST-ROUNDTRIP'


@pytest.mark.integration
def test_message_schema_has_required_fields(producer):
    """Bridge message wrapper schema: version, source_service, timestamp, payload."""
    test_msg = {
        'version': '1.0',
        'source_service': 'pytest-schema',
        'timestamp': int(time.time() * 1000),
        'payload': {'bin_id': 'SCHEMA-001', 'status': 'ok'},
    }
    future = producer.send(TEST_TOPIC, value=test_msg)
    record = future.get(timeout=15)
    producer.flush()

    consumer = KafkaConsumer(
        bootstrap_servers=[KAFKA_BROKER],
        group_id=None,
        **SASL_CONFIG,
        value_deserializer=lambda x: json.loads(x.decode('utf-8')),
        consumer_timeout_ms=10_000,
    )
    tp = TopicPartition(TEST_TOPIC, record.partition)
    consumer.assign([tp])
    consumer.seek(tp, record.offset)

    received = None
    for message in consumer:
        received = message.value
        break
    consumer.close()

    assert received is not None
    for field in ('version', 'source_service', 'timestamp', 'payload'):
        assert field in received, f"Missing field '{field}' in message schema"


@pytest.mark.integration
def test_sasl_scram_authentication_required():
    """Connecting without credentials must fail."""
    if not KAFKA_AVAILABLE:
        pytest.skip("kafka-python not installed")
    with pytest.raises(Exception):
        p = KafkaProducer(
            bootstrap_servers=[KAFKA_BROKER],
            security_protocol='PLAINTEXT',
            request_timeout_ms=5_000,
        )
        future = p.send(TEST_TOPIC, value=b'unauthorized')
        future.get(timeout=5)
        p.close()

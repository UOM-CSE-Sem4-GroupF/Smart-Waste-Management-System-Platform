"""
System test: full MQTT → Kafka → bin-status end-to-end workflow.
Requires: fully deployed Minikube/DOKS stack with all services running.

Environment variables:
  EMQX_HOST     EMQX MQTT broker host (default: localhost)
  EMQX_PORT     MQTT port (default: 31883 for Minikube NodePort)
  KONG_URL      Kong proxy URL (default: http://localhost:30080)
  KAFKA_BROKER  Kafka broker (default: kafka.messaging.svc.cluster.local:9092)
  KAFKA_USER    Kafka SASL user
  KAFKA_PASS    Kafka SASL password
"""
import json
import os
import threading
import time
import uuid
import pytest

try:
    import paho.mqtt.client as mqtt
    MQTT_AVAILABLE = True
except ImportError:
    MQTT_AVAILABLE = False

try:
    from kafka import KafkaConsumer, TopicPartition
    KAFKA_AVAILABLE = True
except ImportError:
    KAFKA_AVAILABLE = False

try:
    import requests
    REQUESTS_AVAILABLE = True
except ImportError:
    REQUESTS_AVAILABLE = False

EMQX_HOST = os.getenv('EMQX_HOST', 'localhost')
EMQX_PORT = int(os.getenv('EMQX_PORT', 31883))
EMQX_USER = os.getenv('EMQX_USER', 'sensor-device')
EMQX_PASS = os.getenv('EMQX_PASS', 'swms-sensor-dev-2026')
KONG_URL = os.getenv('KONG_URL', 'http://localhost:30080')
KAFKA_BROKER = os.getenv('KAFKA_BROKER', 'kafka.messaging.svc.cluster.local:9092')
KAFKA_USER = os.getenv('KAFKA_USER', 'user1')
KAFKA_PASS = os.getenv('KAFKA_PASS', '')

SASL_CONFIG = dict(
    security_protocol='SASL_PLAINTEXT',
    sasl_mechanism='SCRAM-SHA-256',
    sasl_plain_username=KAFKA_USER,
    sasl_plain_password=KAFKA_PASS,
)


def _skip_if_missing():
    if not MQTT_AVAILABLE:
        pytest.skip("paho-mqtt not installed")
    if not KAFKA_AVAILABLE:
        pytest.skip("kafka-python not installed")
    if not KAFKA_PASS:
        pytest.skip("KAFKA_PASS not set — cluster integration skipped")


@pytest.mark.system
def test_mqtt_publish_reaches_kafka():
    """Publish MQTT message → assert it arrives on waste.bin.telemetry topic."""
    _skip_if_missing()

    bin_id = f"E2E-{uuid.uuid4().hex[:8].upper()}"
    test_payload = json.dumps({'bin_id': bin_id, 'fill_level_pct': 77.0})

    received_offsets = []
    consumer_ready = []

    from kafka import KafkaConsumer, TopicPartition
    consumer = KafkaConsumer(
        bootstrap_servers=[KAFKA_BROKER],
        group_id=None,
        **SASL_CONFIG,
        value_deserializer=lambda x: json.loads(x.decode('utf-8')),
        consumer_timeout_ms=15_000,
    )
    tp = TopicPartition('waste.bin.telemetry', 0)
    consumer.assign([tp])
    end = consumer.end_offsets([tp])
    consumer.seek(tp, end[tp])
    consumer_ready.append(True)

    connected = threading.Event()
    published = threading.Event()

    def publish_mqtt():
        client = mqtt.Client(client_id=f"e2e-test-{bin_id}")
        client.username_pw_set(EMQX_USER, EMQX_PASS)
        client.on_connect = lambda c, u, f, rc: connected.set() if rc == 0 else None
        try:
            client.connect(EMQX_HOST, EMQX_PORT, 10)
            client.loop_start()
            connected.wait(timeout=10)
            if connected.is_set():
                client.publish(f"sensors/e2e/{bin_id}", test_payload, qos=1)
                time.sleep(0.5)
                published.set()
            client.loop_stop()
            client.disconnect()
        except Exception as e:
            pytest.skip(f"EMQX not reachable: {e}")

    t = threading.Thread(target=publish_mqtt, daemon=True)
    t.start()
    t.join(timeout=15)

    if not published.is_set():
        pytest.skip("EMQX not reachable or connection failed")

    time.sleep(3)  # bridge forwarding latency

    found = False
    for message in consumer:
        if message.value.get('payload', {}).get('bin_id') == bin_id:
            found = True
            break
    consumer.close()

    assert found, f"Message for bin_id={bin_id!r} not found on waste.bin.telemetry"


@pytest.mark.system
def test_bins_api_reachable_via_kong():
    """Kong routes GET /api/v1/bins to bin-status service."""
    if not REQUESTS_AVAILABLE:
        pytest.skip("requests not installed")
    try:
        resp = requests.get(f"{KONG_URL}/api/v1/bins", timeout=5)
    except requests.ConnectionError:
        pytest.skip(f"Kong not reachable at {KONG_URL}")

    assert resp.status_code not in (502, 503, 404), \
        f"Kong /api/v1/bins returned {resp.status_code}"


@pytest.mark.system
def test_vehicles_api_reachable_via_kong():
    """Kong routes GET /api/v1/vehicles to scheduler service."""
    if not REQUESTS_AVAILABLE:
        pytest.skip("requests not installed")
    try:
        resp = requests.get(f"{KONG_URL}/api/v1/vehicles", timeout=5)
    except requests.ConnectionError:
        pytest.skip(f"Kong not reachable at {KONG_URL}")

    assert resp.status_code not in (502, 503, 404), \
        f"Kong /api/v1/vehicles returned {resp.status_code}"

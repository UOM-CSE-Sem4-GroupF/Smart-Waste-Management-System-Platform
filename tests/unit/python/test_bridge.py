import json
import os
import sys
import time
import pytest
from unittest.mock import MagicMock, call, patch

# conftest.py pre-mocked kafka and paho — import bridge after
import importlib.util
import importlib

_BRIDGE_PATH = os.path.join(
    os.path.dirname(__file__), '..', '..', '..', 'messaging', 'emqx', 'bridge.py'
)

def _load_bridge():
    spec = importlib.util.spec_from_file_location("bridge", _BRIDGE_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bridge = _load_bridge()


class MockMsg:
    def __init__(self, topic: str, payload: dict):
        self.topic = topic
        self.payload = json.dumps(payload).encode('utf-8')


@pytest.mark.unit
def test_on_message_maps_sensors_topic_to_kafka_bin_telemetry():
    client = MagicMock()
    msg = MockMsg("sensors/zone1/BIN-001", {"fill": 80})
    bridge.producer = MagicMock()

    bridge.on_message(client, None, msg)

    bridge.producer.send.assert_called_once()
    call_kwargs = bridge.producer.send.call_args
    assert call_kwargs[0][0] == "waste.bin.telemetry"


@pytest.mark.unit
def test_on_message_maps_vehicles_topic_to_kafka_vehicle_location():
    client = MagicMock()
    msg = MockMsg("vehicles/route1/VH-007", {"lat": 1.3, "lon": 103.8})
    bridge.producer = MagicMock()

    bridge.on_message(client, None, msg)

    bridge.producer.send.assert_called_once()
    assert bridge.producer.send.call_args[0][0] == "waste.vehicle.location"


@pytest.mark.unit
def test_on_message_unknown_prefix_routes_to_waste_general():
    client = MagicMock()
    msg = MockMsg("unknown/topic/device", {"data": "test"})
    bridge.producer = MagicMock()

    bridge.on_message(client, None, msg)

    assert bridge.producer.send.call_args[0][0] == "waste.general"


@pytest.mark.unit
def test_on_message_wraps_payload_with_metadata():
    client = MagicMock()
    payload = {"fill": 42, "battery": 3.7}
    msg = MockMsg("sensors/z1/BIN-042", payload)
    bridge.producer = MagicMock()

    bridge.on_message(client, None, msg)

    sent_value = bridge.producer.send.call_args[1]["value"]
    assert sent_value["version"] == "1.0-bridge"
    assert sent_value["source_service"] == "emqx-oss-bridge"
    assert "timestamp" in sent_value
    assert sent_value["payload"] == payload


@pytest.mark.unit
def test_on_message_timestamp_is_milliseconds():
    client = MagicMock()
    msg = MockMsg("sensors/z1/BIN-001", {"fill": 50})
    bridge.producer = MagicMock()
    before = int(time.time() * 1000)

    bridge.on_message(client, None, msg)

    after = int(time.time() * 1000)
    ts = bridge.producer.send.call_args[1]["value"]["timestamp"]
    assert before <= ts <= after


@pytest.mark.unit
def test_on_message_uses_device_id_as_kafka_key():
    client = MagicMock()
    msg = MockMsg("sensors/BIN-042/reading", {"fill": 90})
    bridge.producer = MagicMock()

    bridge.on_message(client, None, msg)

    key = bridge.producer.send.call_args[1]["key"]
    assert key == "BIN-042"


@pytest.mark.unit
def test_on_message_handles_json_parse_error_gracefully():
    client = MagicMock()
    bad_msg = MagicMock()
    bad_msg.topic = "sensors/z1/BIN-001"
    bad_msg.payload = b"not-valid-json{"
    bridge.producer = MagicMock()

    bridge.on_message(client, None, bad_msg)

    bridge.producer.send.assert_not_called()


@pytest.mark.unit
def test_environment_variable_defaults():
    assert bridge.MQTT_BROKER == os.getenv("MQTT_BROKER", "emqx.messaging.svc.cluster.local")
    assert bridge.KAFKA_BROKER == os.getenv("KAFKA_BROKER", "kafka.messaging.svc.cluster.local:9092")
    assert bridge.MQTT_PORT == int(os.getenv("MQTT_PORT", 1883))


@pytest.mark.unit
def test_topic_map_covers_sensors_and_vehicles():
    assert "sensors/" in bridge.TOPIC_MAP
    assert "vehicles/" in bridge.TOPIC_MAP
    assert bridge.TOPIC_MAP["sensors/"] == "waste.bin.telemetry"
    assert bridge.TOPIC_MAP["vehicles/"] == "waste.vehicle.location"

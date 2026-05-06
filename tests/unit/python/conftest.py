import sys
import os
from unittest.mock import MagicMock, patch

# Mock kafka and paho before bridge.py is imported so the module-level
# KafkaProducer() call does not attempt a real connection.
kafka_mock = MagicMock()
kafka_producer_instance = MagicMock()
kafka_mock.KafkaProducer.return_value = kafka_producer_instance
sys.modules['kafka'] = kafka_mock
sys.modules['paho'] = MagicMock()
sys.modules['paho.mqtt'] = MagicMock()
sys.modules['paho.mqtt.client'] = MagicMock()

# Ensure messaging/emqx is on the path
repo_root = os.path.join(os.path.dirname(__file__), '..', '..', '..')
sys.path.insert(0, repo_root)

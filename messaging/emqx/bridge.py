import os
import json
import logging
import time
from signal import signal, SIGTERM, SIGINT
import paho.mqtt.client as mqtt
from kafka import KafkaProducer

# Setup logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger("mqtt-kafka-bridge")

# Configuration from Environment
MQTT_BROKER = os.getenv("MQTT_BROKER", "emqx.messaging.svc.cluster.local")
MQTT_PORT = int(os.getenv("MQTT_PORT", 1883))
MQTT_USER = os.getenv("MQTT_USER", "f1-admin")
MQTT_PASS = os.getenv("MQTT_PASS", "swms-f1-admin-2026")

KAFKA_BROKER = os.getenv("KAFKA_BROKER", "kafka.messaging.svc.cluster.local:9092")
KAFKA_USER = os.getenv("KAFKA_USER", "user1")
KAFKA_PASS = os.getenv("KAFKA_PASS", "QA7aKGtPHV")

# Topic Mapping: MQTT -> Kafka
TOPIC_MAP = {
    "sensors/": "waste.bin.telemetry",
    "vehicles/": "waste.vehicle.location"
}

# Kafka Producer Setup
producer = KafkaProducer(
    bootstrap_servers=[KAFKA_BROKER],
    security_protocol="SASL_PLAINTEXT",
    sasl_mechanism="SCRAM-SHA-256",
    sasl_plain_username=KAFKA_USER,
    sasl_plain_password=KAFKA_PASS,
    value_serializer=lambda v: json.dumps(v).encode('utf-8'),
    key_serializer=lambda k: k.encode('utf-8') if k else None
)

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        logger.info("✅ Connected to EMQX Broker")
        # Subscribe to all telemetry and location topics
        client.subscribe("sensors/#")
        client.subscribe("vehicles/#")
        logger.info("✅ Subscribed to sensors/# and vehicles/#")
    else:
        logger.error(f"❌ MQTT Connection failed with code {rc}")

def on_message(client, userdata, msg):
    try:
        topic = msg.topic
        payload = json.loads(msg.payload.decode('utf-8'))
        client_id = topic.split('/')[-2] if '/' in topic else "unknown"
        
        # Determine Kafka target topic
        kafka_topic = "waste.general"
        for mqtt_prefix, target in TOPIC_MAP.items():
            if topic.startswith(mqtt_prefix):
                kafka_topic = target
                break
        
        # Enclose in standard platform wrapper
        wrapped_msg = {
            "version": "1.0-bridge",
            "source_service": "emqx-oss-bridge",
            "timestamp": int(time.time() * 1000),
            "payload": payload
        }
        
        logger.info(f"⚡ Bridging {topic} -> Kafka:{kafka_topic}")
        producer.send(kafka_topic, key=client_id, value=wrapped_msg)
        producer.flush()  # Ensure message is sent immediately
        
    except Exception as e:
        logger.error(f"Failed to bridge message: {e}")

def run_bridge():
    client = mqtt.Client(client_id="swms_oss_bridge")
    client.username_pw_set(MQTT_USER, MQTT_PASS)
    client.on_connect = on_connect
    client.on_message = on_message

    logger.info(f"Starting bridge connecting {MQTT_BROKER} to {KAFKA_BROKER}...")
    
    # Simple retry logic for startup
    connected = False
    while not connected:
        try:
            client.connect(MQTT_BROKER, MQTT_PORT, 60)
            connected = True
        except Exception as e:
            logger.warning(f"Waiting for brokers: {e}")
            time.sleep(5)

    client.loop_forever()

if __name__ == "__main__":
    run_bridge()

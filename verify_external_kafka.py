import os
from kafka import KafkaConsumer
import json
import logging
import time

# --- CONFIGURATION ---
KAFKA_BROKER = "a2124eca3295942ebbecfa3ea783693d-fc2f125c6004ef47.elb.eu-north-1.amazonaws.com:9094"
KAFKA_USER = "user1"
KAFKA_PASS = "Ajkv0XR2Io"
TOPIC = "waste.bin.telemetry"
GROUP_ID = f"verify-external-{int(time.time())}"

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def test_external_connection():
    logging.info(f"🌐 Testing connection to EXTERNAL Kafka: {KAFKA_BROKER}")
    logging.info(f"👤 User: {KAFKA_USER}")
    
    try:
        consumer = KafkaConsumer(
            TOPIC,
            bootstrap_servers=[KAFKA_BROKER],
            group_id=GROUP_ID,
            auto_offset_reset='earliest',
            security_protocol="SASL_PLAINTEXT",
            sasl_mechanism="SCRAM-SHA-256",
            sasl_plain_username=KAFKA_USER,
            sasl_plain_password=KAFKA_PASS,
            value_deserializer=lambda x: json.loads(x.decode('utf-8')),
            request_timeout_ms=30000,
            session_timeout_ms=10000,
            metadata_max_age_ms=30000
        )
        
        logging.info("✅ Connected! Waiting for heartbeats...")
        
        # Poll for a few seconds to see if we get anything
        start_time = time.time()
        timeout = 20  # seconds
        
        while time.time() - start_time < timeout:
            msg_pack = consumer.poll(timeout_ms=1000)
            for tp, messages in msg_pack.items():
                for msg in messages:
                    logging.info(f"🎉 SUCCESS! Received message: {msg.value}")
                    consumer.close()
                    return True
                    
        logging.warning("⚠️ Connected, but no messages received yet. This is expected if the simulator is off.")
        consumer.close()
        return True

    except Exception as e:
        logging.error(f"❌ Failed to connect: {e}")
        return False

if __name__ == "__main__":
    test_external_connection()

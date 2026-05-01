#!/usr/bin/env python3
"""
Group F — Smart Waste Management System
External Kafka connectivity verification (produce + consume round-trip).

Equivalent to the EMQX test:
  mosquitto_pub -h <NLB_DNS> -p 1883 -u sensor-device -P swms-sensor-dev-2026 -t sensors/test -m "hello"

Usage:
  pip install kafka-python
  python verify_external_kafka.py

Exit codes:
  0 — produce + consume round-trip confirmed
  1 — producer could not connect (NLB or auth issue)
  2 — producer OK but consume timed out (Kafka up, possible lag)
"""

import json
import logging
import time
from datetime import datetime, timezone
from kafka import KafkaProducer, KafkaConsumer
from kafka.errors import KafkaError

NLB_HOST = "a2124eca3295942ebbecfa3ea783693d-fc2f125c6004ef47.elb.eu-north-1.amazonaws.com"
KAFKA_BROKER = f"{NLB_HOST}:9094"
KAFKA_USER = "user1"
KAFKA_PASS = "Ajkv0XR2Io"  # actual deployed password (kubectl get secret kafka-user-passwords -n messaging -o jsonpath='{.data.client-passwords}' | base64 -d)
TOPIC = "waste.bin.telemetry"
GROUP_ID = f"verify-external-{int(time.time())}"

SASL_CONFIG = dict(
    security_protocol="SASL_PLAINTEXT",
    sasl_mechanism="SCRAM-SHA-256",
    sasl_plain_username=KAFKA_USER,
    sasl_plain_password=KAFKA_PASS,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)


def make_test_message() -> dict:
    return {
        "version": "1.0",
        "source_service": "verify-external-kafka",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "payload": {
            "bin_id": "BIN-VERIFY-001",
            "fill_level_pct": 42.0,
            "urgency_score": 10,
            "status": "normal",
            "_note": "connectivity verification — safe to ignore",
        },
    }


def test_produce() -> tuple | None:
    log.info(f"Connecting producer to {KAFKA_BROKER} ...")
    try:
        producer = KafkaProducer(
            bootstrap_servers=[KAFKA_BROKER],
            **SASL_CONFIG,
            value_serializer=lambda v: json.dumps(v).encode("utf-8"),
            request_timeout_ms=30_000,
            acks="all",
        )
        msg = make_test_message()
        correlation_key = msg["timestamp"]
        future = producer.send(TOPIC, value=msg)
        record = future.get(timeout=15)
        producer.flush()
        producer.close()
        log.info(
            f"Delivered — topic={record.topic} partition={record.partition} offset={record.offset}"
        )
        return record.partition, record.offset
    except KafkaError as e:
        log.error(f"Producer failed: {e}")
        return None


def test_consume(partition: int, offset: int) -> bool:
    """Seek directly to the offset we just produced — avoids group coordinator lookup
    (which tries controller.internal, not externally resolvable)."""
    log.info(f"Consuming partition={partition} offset={offset} directly (no consumer group) ...")
    from kafka import TopicPartition
    try:
        consumer = KafkaConsumer(
            bootstrap_servers=[KAFKA_BROKER],
            group_id=None,   # no group = no coordinator lookup = no controller.internal DNS
            **SASL_CONFIG,
            value_deserializer=lambda x: json.loads(x.decode("utf-8")),
            request_timeout_ms=30_000,
            consumer_timeout_ms=15_000,
        )
        tp = TopicPartition(TOPIC, partition)
        consumer.assign([tp])
        consumer.seek(tp, offset)
        for message in consumer:
            log.info(f"Round-trip confirmed: partition={message.partition} offset={message.offset}")
            consumer.close()
            return True
        consumer.close()
        log.warning("Consumer timed out after seeking to produced offset.")
        return False
    except KafkaError as e:
        log.error(f"Consumer failed: {e}")
        return False


def main():
    log.info("=" * 60)
    log.info("SWMS — External Kafka Connectivity Test")
    log.info(f"Broker : {KAFKA_BROKER}")
    log.info(f"Topic  : {TOPIC}")
    log.info(f"User   : {KAFKA_USER}")
    log.info("=" * 60)

    result = test_produce()
    if result is None:
        log.error("FAIL — Check NLB DNS reachability and SASL credentials.")
        raise SystemExit(1)

    partition, offset = result
    time.sleep(2)

    if test_consume(partition, offset):
        log.info("ALL CHECKS PASSED — Kafka external access is working.")
        log.info("")
        log.info("Quick-connect commands (parity with MQTT):")
        log.info("  kcat -F terraform/client.properties -L")
        log.info(f"  kcat -F terraform/client.properties -t {TOPIC} -C -o end")
        log.info(f"  kcat -F terraform/client.properties -t {TOPIC} -P -e <<< '{{\"test\":\"hello\"}}'")
    else:
        log.warning("PARTIAL — Producer OK but consume verification timed out.")
        raise SystemExit(2)


if __name__ == "__main__":
    main()

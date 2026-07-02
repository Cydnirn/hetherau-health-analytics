#!/usr/bin/env python3
"""
Hetherau IoT Dummy Device Simulator.
Publishes synthetic citizen health data to AWS IoT Core via MQTT every 60 seconds.

Configuration via environment variables:
    IOT_ENDPOINT   – AWS IoT Core endpoint (e.g., xxxxxxxxxxxxxx-ats.iot.region.amazonaws.com)
    CLIENT_ID      – MQTT client ID (default: hetherau-device-001)
    CERT_PATH      – Path to device certificate PEM file
    KEY_PATH       – Path to device private key PEM file
    ROOT_CA_PATH   – Path to Amazon Root CA PEM file
    TOPIC          – MQTT topic to publish to (default: citizen/health)
    INTERVAL       – Publishing interval in seconds (default: 60)
"""

import json
import logging
import random
import time

from awscrt import mqtt
from awsiot import mqtt_connection_builder

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DEFAULT_CONFIG = "device_config.json"


def load_config(path: str) -> dict:
    """Load and validate device configuration from a JSON file."""
    with open(path, "r", encoding="utf-8") as f:
        config = json.load(f)

    required = [
        "IOT_ENDPOINT",
        "CERT_PATH",
        "KEY_PATH",
        "ROOT_CA_PATH",
        "TOPIC",
    ]

    for key in required:
        if key not in config:
            log.error("Missing required config key: %s", key)
            sys.exit(1)

    return {
        "THING_NAME": config.get("thing_name", "DummyDevice"),
        "CLIENT_ID": config.get("client_id", "dummyDevice"),
        "IOT_ENDPOINT": config["endpoint"],
        "CERT_PATH": config["cert_path"],
        "KEY_PATH": config["private_key_path"],
        "ROOT_CA_PATH": config["root_ca_path"],
        "TOPIC": config["topic"],
        "INTERVAL": int(config.get("interval_seconds", 10)),
        "CITIZEN_ID": config.get("citizen_id", "C001"),
    }


def generate_health_data(citizen_id):
    """Generate a single synthetic citizen health record."""
    return {
        "citizen_id": citizen_id,
        "average_heart_beat_rate": random.randint(55, 150),
        "o2_content": round(random.uniform(0.92, 1.0), 4),
        "sleep_time": round(random.uniform(4, 10), 2),
        "calories_burned": random.randint(200, 800),
        "timestamp": int(time.time() * 1000),
    }


def main():
    # Read configuration from environment
    config = load_config(DEFAULT_CONFIG)
    endpoint = config["IOT_ENDPOINT"]
    client_id = config.get("CLIENT_ID", "hetherau-device-001")
    cert_filepath = config["CERT_PATH"]
    pri_key_filepath = config["KEY_PATH"]
    ca_filepath = config["ROOT_CA_PATH"]
    topic = config.get("TOPIC", "citizen/health")
    interval = int(config.get("INTERVAL", "60"))
    citizen_id = config.get("CITIZEN_ID", "C001")

    if not endpoint:
        logger.error("IOT_ENDPOINT environment variable is required.")
        return

    client = mqtt_connection_builder.mtls_from_path(
        endpoint,
        cert_filepath,
        pri_key_filepath,
        ca_filepath,
        client_id,
        clean_session=False,
        keep_alive_secs=30,
    )

    if cert_filepath and pri_key_filepath and ca_filepath:
        client.configureCredentials(ca_filepath, pri_key_filepath, cert_filepath)
    else:
        logger.warning(
            "Certificate paths not fully configured. "
            "Set CERT_PATH, KEY_PATH, and ROOT_CA_PATH environment variables "
            "for secure MQTT connections."
        )

    logger.info(f"Connecting to IoT Core at {endpoint}...")
    connected = client.connect()
    if not connected:
        logger.error("Failed to connect to IoT Core.")
        return

    logger.info(f"Connected. Publishing to topic '{topic}' every {interval}s.")

    try:
        while True:
            data = generate_health_data(citizen_id)
            message = json.dumps(data)
            success = client.publish(topic, message, qos=mqtt.Qos.AT_LEAST_ONCE)

            if success:
                logger.info(
                    f"Published: citizen_id={data['citizen_id']}, "
                    f"heart_rate={data['average_heart_beat_rate']}, "
                    f"o2={data['o2_content']}, "
                    f"sleep={data['sleep_time']}h, "
                    f"calories={data['calories_burned']}"
                )
            else:
                logger.warning("Publish failed.")

            time.sleep(interval)

    except KeyboardInterrupt:
        logger.info("Shutting down device simulator...")
    finally:
        client.disconnect()
        logger.info("Disconnected.")


if __name__ == "__main__":
    main()

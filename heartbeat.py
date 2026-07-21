"""
Filename: heartbeat.py

Device liveness heartbeat (S37, firmware v1.8+).

A daemon thread POSTs a heartbeat to the backend dashboard API every
HEARTBEAT_INTERVAL_SECONDS (default 300 = 5 minutes). The backend
records only last_seen; the cloud health monitor derives the
OFFLINE/HEALTHY transitions and notifies the owner.

The heartbeat is deliberately independent of the IoT Hub connection:
it answers "is the device up and does it have internet?", which is
exactly the signal the cloud watchdog needs — including while the hub
connection itself is down or reconnecting.

Failures are never fatal: a missed heartbeat is precisely the condition
the backend is designed to detect.
"""
import hashlib
import logging
import os
import threading
import time

import requests

DEFAULT_INTERVAL_SECONDS = 300
REQUEST_TIMEOUT_SECONDS = 10
SECONDS_PER_MINUTE = 60
TOKEN_LENGTH = 16


def generate_minute_token(device_id, timestamp=None):
    """
    Compute the minute-based verification token the backend expects:
    sha256("<device_id>:<current minute>") truncated to 16 hex chars.
    Must match digipay_iot.minute_token.generate_minute_token exactly.
    """
    if timestamp is None:
        timestamp = time.time()
    minute = int(timestamp // SECONDS_PER_MINUTE)
    payload = "%s:%s" % (device_id, minute)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:TOKEN_LENGTH]


def send_heartbeat(url, device_id):
    """Send one heartbeat. Returns True when the backend recorded it."""
    payload = {
        "device_id": device_id,
        "token": generate_minute_token(device_id),
    }
    try:
        response = requests.post(url, json=payload, timeout=REQUEST_TIMEOUT_SECONDS)
    except requests.exceptions.RequestException as e:
        logging.warning("heartbeat: send failed (non-critical): %s", e)
        return False

    if response.status_code == 200:
        logging.info("heartbeat: recorded for %s", device_id)
        return True

    logging.warning(
        "heartbeat: rejected with status %s: %s",
        response.status_code,
        response.text,
    )
    return False


def _heartbeat_loop(url, device_id, interval_seconds):
    while True:
        try:
            send_heartbeat(url, device_id)
        except Exception as e:
            # Belt and braces: the loop must survive anything.
            logging.error("heartbeat: unexpected error: %s", e)
        time.sleep(interval_seconds)


def start_heartbeat_thread(device_id, dashboard_host):
    """
    Start the heartbeat daemon thread and return it.

    :param device_id: IoT device id (rpiPagalava<laundry_id>)
    :param dashboard_host: backend dashboard hostname from determine_environment()
    """
    interval_seconds = int(
        os.getenv("HEARTBEAT_INTERVAL_SECONDS", str(DEFAULT_INTERVAL_SECONDS))
    )
    url = "https://%s/api/laundries/iot/heartbeat" % dashboard_host
    thread = threading.Thread(
        target=_heartbeat_loop,
        args=(url, device_id, interval_seconds),
        daemon=True,
        name="heartbeat",
    )
    thread.start()
    logging.info(
        "heartbeat: thread started (interval %ss, url %s)", interval_seconds, url
    )
    return thread

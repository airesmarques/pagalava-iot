"""
Minute-based verification token for device-originated HTTP requests.

MUST stay byte-identical to the backend's implementation at
libraries/python/digipay-iot/digipay_iot/minute_token.py in the Digipay_v2
repo. The device cannot import that package, so the algorithm is duplicated
here; if the two drift apart, verification fails closed and every request is
rejected with 401 for reasons that are hard to see from either side.
tests/test_minute_token_parity.py pins them together.

Note this token has no shared secret: it is derived only from the device id and
the current minute, both of which are guessable. It is a liveness check, not
authentication. Endpoints that accept it are built so that forging one achieves
nothing useful.
"""
import hashlib
import time

SECONDS_PER_MINUTE = 60
TOKEN_LENGTH = 16


def generate_minute_token(device_id: str, timestamp: int | None = None) -> str:
    """
    Generate this device's verification token for a given time.

    :param device_id: The device identifier (e.g. "rpiPagalava99").
    :param timestamp: Optional epoch seconds; defaults to now.
    :return: Hex token of TOKEN_LENGTH characters.
    """
    if timestamp is None:
        timestamp = int(time.time())
    minute = timestamp // SECONDS_PER_MINUTE
    token_input = f"{device_id}:{minute}"
    return hashlib.sha256(token_input.encode()).hexdigest()[:TOKEN_LENGTH]

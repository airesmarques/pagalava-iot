"""
Pins the firmware's minute token to the backend's implementation.

The two are separate files in separate repos that must produce identical
output. A drift fails closed: the backend rejects every device request with
401, and neither side logs anything that points at the cause. So the algorithm
is re-derived here independently rather than imported, and compared.
"""
import hashlib
import os
import sys
import unittest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from minute_token import generate_minute_token, TOKEN_LENGTH, SECONDS_PER_MINUTE


def backend_algorithm(device_id: str, timestamp: int) -> str:
    """
    The backend's algorithm, written out from
    digipay_iot/minute_token.py: sha256 of "<device_id>:<minute>" truncated
    to 16 hex chars. Independently restated so a copy-paste change to the
    firmware cannot silently satisfy this test.
    """
    minute = timestamp // 60
    return hashlib.sha256(f"{device_id}:{minute}".encode()).hexdigest()[:16]


class TestMinuteTokenParity(unittest.TestCase):

    def test_matches_the_backend_across_many_devices_and_times(self):
        for device in ("rpiPagalava1", "rpiPagalava99", "rpiPagalava12345"):
            for ts in (0, 1_600_000_000, 1_700_000_059, 1_700_000_060, 2_000_000_000):
                self.assertEqual(
                    generate_minute_token(device, ts),
                    backend_algorithm(device, ts),
                    f"drift for {device} at {ts}",
                )

    def test_constants_match_the_backend(self):
        self.assertEqual(TOKEN_LENGTH, 16)
        self.assertEqual(SECONDS_PER_MINUTE, 60)

    def test_token_is_stable_within_a_minute_and_changes_across_one(self):
        base = 1_700_000_000 - (1_700_000_000 % 60)
        self.assertEqual(
            generate_minute_token("rpiPagalava99", base),
            generate_minute_token("rpiPagalava99", base + 59),
        )
        self.assertNotEqual(
            generate_minute_token("rpiPagalava99", base),
            generate_minute_token("rpiPagalava99", base + 60),
        )

    def test_different_devices_get_different_tokens(self):
        ts = 1_700_000_000
        self.assertNotEqual(
            generate_minute_token("rpiPagalava1", ts),
            generate_minute_token("rpiPagalava2", ts),
        )

    def test_defaults_to_now(self):
        import time
        self.assertEqual(
            generate_minute_token("rpiPagalava99"),
            generate_minute_token("rpiPagalava99", int(time.time())),
        )


if __name__ == "__main__":
    unittest.main()

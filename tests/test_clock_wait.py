"""
Waiting for the clock before the first IoT Hub connection.

A Pi has no RTC. Firmware 1.9 seeds the clock with the image build time, which
removed the TLS failure ("certificate is not yet valid") — but the hardware test
showed the device STILL could not connect on its first attempt:

    23:45:59  Connection Refused: not authorised.   <- seeded clock, 1h43m behind
    01:29:41  Connected successfully.               <- after timesyncd fixed it

The IoT Hub SAS token is time-based, so a clock inside certificate validity can
still be outside token validity. Worse, the minute token used for diagnostics
and configuration requests is derived from this same clock, so a skewed device
is rejected 401 and cannot even report that it is skewed.

The device did recover, but only through the generic reconnect backoff, which
multiplies to a 300s cap — so it could sit idle for five minutes after its clock
was already correct.

THE PROPERTY THAT MATTERS MOST: this must never be able to make things worse
than not waiting at all. It runs before the service can do anything useful, so
it must not hang, must not raise, and must give up rather than block forever.
"""
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

CONN = ("HostName=example.azure-devices.net;DeviceId=rpiPagalava99;"
        "SharedAccessKey=Zm9vYmFyYmF6cXV4")


def _import_receive_messages():
    """Import ReceiveMessages with the Pi-only pieces stubbed out."""
    fake_gpio = MagicMock()
    fake_gpio.BCM = "BCM"
    fake_gpio.OUT = "OUT"
    fake_gpio.HIGH = 1
    fake_gpio.LOW = 0
    rpi = types.ModuleType("RPi")
    rpi.GPIO = fake_gpio
    sys.modules["RPi"] = rpi
    sys.modules["RPi.GPIO"] = fake_gpio

    azure = types.ModuleType("azure")
    azure_iot = types.ModuleType("azure.iot")
    azure_iot_device = types.ModuleType("azure.iot.device")
    azure_iot_device.IoTHubDeviceClient = MagicMock()
    azure.iot = azure_iot
    azure_iot.device = azure_iot_device
    sys.modules.setdefault("azure", azure)
    sys.modules.setdefault("azure.iot", azure_iot)
    sys.modules.setdefault("azure.iot.device", azure_iot_device)

    os.environ["IOT_CONNECTION_STRING"] = CONN
    for mod in ("ReceiveMessages", "relay_ops"):
        sys.modules.pop(mod, None)

    import ReceiveMessages
    return ReceiveMessages


rm = _import_receive_messages()


class ASyncedClockCostsNothing(unittest.TestCase):
    """The normal case — a warm reboot — must not delay startup at all."""

    def test_returns_zero_without_sleeping(self):
        with patch.object(rm.diagnostics_report, "time_synced", return_value="yes"):
            with patch.object(rm.time, "sleep") as slept:
                waited = rm.wait_for_clock_sync()
        self.assertEqual(waited, 0)
        slept.assert_not_called()


class AnUnsyncedClockIsWaitedFor(unittest.TestCase):

    def test_it_polls_until_sync_arrives_and_reports_the_duration(self):
        # not synced, not synced, then synced
        answers = ["no", "no", "yes"]
        with patch.object(rm.diagnostics_report, "time_synced",
                          side_effect=answers):
            with patch.object(rm.time, "sleep"):
                waited = rm.wait_for_clock_sync(timeout_seconds=300, poll_seconds=5)
        # two polls of 5s each after the initial check
        self.assertEqual(waited, 10)

    def test_the_wait_is_announced_before_it_starts(self):
        """The journal is the only evidence on a device with no inbound SSH."""
        with patch.object(rm.diagnostics_report, "time_synced",
                          side_effect=["no", "yes"]):
            with patch.object(rm.time, "sleep"):
                with self.assertLogs(level="WARNING") as logs:
                    rm.wait_for_clock_sync(poll_seconds=1)
        self.assertIn("not synchronised", " ".join(logs.output))


class ItGivesUpRatherThanBlockingForever(unittest.TestCase):
    """
    A site where NTP is filtered must not get a device that never starts. On
    timeout we connect anyway and fall back to exactly today's behaviour: the
    hub refuses us and the existing backoff loop retries.
    """

    def test_it_returns_at_the_timeout(self):
        with patch.object(rm.diagnostics_report, "time_synced", return_value="no"):
            with patch.object(rm.time, "sleep"):
                waited = rm.wait_for_clock_sync(timeout_seconds=20, poll_seconds=5)
        self.assertEqual(waited, 20)

    def test_the_timeout_is_logged_as_an_error_naming_the_cause(self):
        with patch.object(rm.diagnostics_report, "time_synced", return_value="no"):
            with patch.object(rm.time, "sleep"):
                with self.assertLogs(level="ERROR") as logs:
                    rm.wait_for_clock_sync(timeout_seconds=10, poll_seconds=5)
        joined = " ".join(logs.output)
        self.assertIn("STILL not synchronised", joined)
        self.assertIn("NTP", joined)


class AnUnanswerableProbeDoesNotHang(unittest.TestCase):
    """
    time_synced() returns None when timedatectl is missing or will not answer.
    Polling a question that cannot be answered would burn the whole timeout on
    every boot of such a device.
    """

    def test_none_returns_immediately(self):
        with patch.object(rm.diagnostics_report, "time_synced", return_value=None):
            with patch.object(rm.time, "sleep") as slept:
                waited = rm.wait_for_clock_sync()
        self.assertEqual(waited, 0)
        slept.assert_not_called()

    def test_none_appearing_mid_wait_stops_the_wait(self):
        with patch.object(rm.diagnostics_report, "time_synced",
                          side_effect=["no", None]):
            with patch.object(rm.time, "sleep"):
                waited = rm.wait_for_clock_sync(timeout_seconds=300, poll_seconds=5)
        self.assertEqual(waited, 5)


class ItCanNeverTakeTheServiceDown(unittest.TestCase):
    """
    This runs before the device can do anything useful. A diagnostics helper
    throwing must not be why a laundromat stops taking payments — the same
    lesson as diagnostics_report itself.
    """

    def test_a_throwing_probe_is_survived(self):
        with patch.object(rm.diagnostics_report, "time_synced",
                          side_effect=RuntimeError("timedatectl exploded")):
            waited = rm.wait_for_clock_sync()
        self.assertEqual(waited, 0)

    def test_a_throwing_sleep_is_survived(self):
        with patch.object(rm.diagnostics_report, "time_synced", return_value="no"):
            with patch.object(rm.time, "sleep", side_effect=OSError("interrupted")):
                waited = rm.wait_for_clock_sync()
        self.assertEqual(waited, 0)


class TheWaitHappensOnlyOnce(unittest.TestCase):
    """
    main() is a retry loop. An unguarded wait would burn the full timeout on
    EVERY reconnect at a site where the clock never syncs, turning a
    self-healing device into one that stalls for five minutes per attempt.
    """

    def test_main_guards_the_call_with_a_flag(self):
        source = open(rm.__file__).read()
        self.assertIn("clock_wait_done = False", source)
        self.assertIn("if not clock_wait_done:", source)
        # and the wait must be inside that guard, not merely near it
        start = source.index("if not clock_wait_done:")
        guarded = source[start:start + 250]
        self.assertIn("wait_for_clock_sync()", guarded)
        self.assertIn("clock_wait_done = True", guarded)

    def test_the_duration_is_handed_to_diagnostics(self):
        """Otherwise a slow-NTP site stays invisible."""
        source = open(rm.__file__).read()
        self.assertIn("set_clock_wait_seconds(wait_for_clock_sync())", source)


class TheConnectionLogDoesNotLie(unittest.TestCase):
    """
    There is no client.connect() in this module; the SDK connects lazily. The
    old line printed "Connected successfully" while the hub was refusing us with
    "not authorised", and reading it as success cost real time during the 1.9
    investigation.
    """

    def test_it_no_longer_claims_a_successful_connection(self):
        source = open(rm.__file__).read()
        self.assertNotIn('logging.info("Connected successfully.', source)


if __name__ == "__main__":
    unittest.main()

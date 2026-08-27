"""
Tests for the bench relay test (C2D 'test_relay').

This is the only path that addresses relays directly rather than through a
machine. It exists because a board is assembled and checked BEFORE it reaches
a laundromat: there are no machines connected, config.json may not exist, and
the installer needs to confirm all sixteen relays operate regardless of how
many machines will eventually use them.

The safety property under test is the pulse duration. A real activation is long
enough to trip a machine's coin input; a wiring check must not be.
"""
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

CONN = ("HostName=digipay2-IoTHub-dev.azure-devices.net;"
        "DeviceId=rpiPagalava99;SharedAccessKey=AAAA==")


def _import():
    fake_gpio = MagicMock()
    fake_gpio.BCM, fake_gpio.OUT, fake_gpio.HIGH, fake_gpio.LOW = "BCM", "OUT", 1, 0
    rpi = types.ModuleType("RPi"); rpi.GPIO = fake_gpio
    sys.modules["RPi"] = rpi; sys.modules["RPi.GPIO"] = fake_gpio
    azure = types.ModuleType("azure")
    aiot = types.ModuleType("azure.iot"); adev = types.ModuleType("azure.iot.device")
    adev.IoTHubDeviceClient = MagicMock(); azure.iot = aiot; aiot.device = adev
    sys.modules.setdefault("azure", azure)
    sys.modules.setdefault("azure.iot", aiot)
    sys.modules.setdefault("azure.iot.device", adev)
    os.environ["IOT_CONNECTION_STRING"] = CONN
    for m in ("ReceiveMessages", "relay_ops"):
        sys.modules.pop(m, None)
    import ReceiveMessages
    return ReceiveMessages


rm = _import()


class TestSingleRelay(unittest.TestCase):

    def test_pulses_the_requested_relay(self):
        with patch.object(rm.relay_ops, "pulse_relay") as p:
            rm.message_handler_payload = None
            rm.message_test_relay({"relay_number": 9})
        p.assert_called_once()
        self.assertEqual(p.call_args[0][0], 9)

    def test_accepts_a_relay_number_sent_as_a_string(self):
        # C2D payloads arrive as JSON; a dashboard could send "9".
        with patch.object(rm.relay_ops, "pulse_relay") as p:
            rm.message_test_relay({"relay_number": "12"})
        self.assertEqual(p.call_args[0][0], 12)

    def test_an_unknown_relay_does_not_crash_the_device(self):
        with patch.object(rm.relay_ops, "pulse_relay",
                          side_effect=KeyError("Unknown relay number: 99")):
            rm.message_test_relay({"relay_number": 99})  # must not raise


class TestModuleSweeps(unittest.TestCase):

    def test_module_1_pulses_only_module_1_relays(self):
        with patch.object(rm.relay_ops, "pulse_relays", return_value=[]) as p:
            rm.message_test_relay({"module": "1"})
        self.assertEqual(list(p.call_args[0][0]), [1, 2, 3, 4, 6, 8])

    def test_module_2_pulses_only_module_2_relays(self):
        with patch.object(rm.relay_ops, "pulse_relays", return_value=[]) as p:
            rm.message_test_relay({"module": "2"})
        self.assertEqual(list(p.call_args[0][0]), [9, 10, 11, 12, 13, 14, 15, 16])

    def test_all_covers_every_MAPPED_relay(self):
        # 14, not 16: relay_to_gpio_map has no entry for 5 or 7. The board is
        # labelled 1-16 but those two positions are not wired to a GPIO, so
        # they cannot be pulsed and must not be offered as testable.
        with patch.object(rm.relay_ops, "pulse_relays", return_value=[]) as p:
            rm.message_test_relay({"module": "all"})
        relays = list(p.call_args[0][0])
        self.assertEqual(len(relays), 14)
        self.assertNotIn(5, relays)
        self.assertNotIn(7, relays)

    def test_the_module_lists_match_the_gpio_map(self):
        # If someone adds a relay to a module list without mapping it to a
        # GPIO, pulse_relay raises KeyError mid-sweep and the rest never fire.
        mapped = set(rm.relay_ops.relay_to_gpio_map)
        self.assertTrue(set(rm.relay_ops.MODULE_1_RELAYS) <= mapped)
        self.assertTrue(set(rm.relay_ops.MODULE_2_RELAYS) <= mapped)

    def test_an_unknown_module_is_ignored_not_guessed(self):
        with patch.object(rm.relay_ops, "pulse_relays") as p:
            rm.message_test_relay({"module": "3"})
        p.assert_not_called()


class TestPulseDurationIsBounded(unittest.TestCase):
    """A wiring check must not start a machine, and must not weld a relay shut."""

    def _duration(self, payload):
        with patch.object(rm.relay_ops, "pulse_relay") as p:
            rm.message_test_relay({"relay_number": 9, **payload})
        return p.call_args[0][1]

    def test_defaults_shorter_than_a_real_activation(self):
        # Real activations use time_relay_ms from config, typically 2000ms.
        self.assertLessEqual(self._duration({}), 1.5)

    def test_an_absurd_duration_is_capped(self):
        # Otherwise a bad payload could energise whatever is wired to the relay
        # for as long as it likes.
        self.assertLessEqual(self._duration({"duration_s": 600}), 3.0)

    def test_a_zero_duration_still_clicks(self):
        self.assertGreaterEqual(self._duration({"duration_s": 0}), 0.1)

    def test_garbage_duration_falls_back_to_the_default(self):
        self.assertLessEqual(self._duration({"duration_s": "abc"}), 1.5)


class TestDispatch(unittest.TestCase):

    def test_the_message_type_is_routed(self):
        with patch.object(rm, "message_test_relay") as h:
            rm.message_handler_dispatch = None
            import json as _json
            msg = MagicMock()
            msg.data = _json.dumps({"msg_type": "test_relay", "relay_number": 9}).encode()
            rm.message_handler(msg)
        h.assert_called_once()

    def test_requires_a_relay_or_a_module(self):
        with patch.object(rm.relay_ops, "pulse_relay") as p1, \
             patch.object(rm.relay_ops, "pulse_relays") as p2:
            rm.message_test_relay({})
        p1.assert_not_called()
        p2.assert_not_called()


if __name__ == "__main__":
    unittest.main()


class TestUpgradeRestartIsHonest(unittest.TestCase):
    """
    message_upgrade used to fire the restart and return True regardless. On a
    device without passwordless sudo the restart failed silently, so the
    dashboard reported a successful upgrade while the device kept running the
    old code — indistinguishable, from the cloud, from the upgrade not having
    happened at all.
    """

    def _run_upgrade(self, sudo_ok):
        import subprocess as sp
        completed = MagicMock()
        completed.returncode = 0 if sudo_ok else 1
        with patch.object(rm.os.path, "exists", return_value=True), \
             patch.object(rm.subprocess, "run", return_value=completed) as run, \
             patch.object(rm.subprocess, "Popen") as popen:
            # The git pull itself is the first subprocess.run call; make both
            # succeed so only the sudo probe decides the outcome.
            rm.message_upgrade()
        return run, popen

    def test_restarts_when_sudo_is_available(self):
        _, popen = self._run_upgrade(sudo_ok=True)
        popen.assert_called_once()
        args = popen.call_args[0][0]
        self.assertIn("restart", args)
        self.assertIn("receive_messages.service", args)

    def test_does_not_pretend_to_restart_without_sudo(self):
        # The important half: no restart attempted, so nothing silently fails.
        _, popen = self._run_upgrade(sudo_ok=False)
        popen.assert_not_called()

    def test_probes_sudo_non_interactively(self):
        # -n matters: without it sudo would wait for a password on a service
        # that has no tty, and hang instead of failing.
        run, _ = self._run_upgrade(sudo_ok=True)
        probes = [c for c in run.call_args_list if "-n" in (c[0][0] if c[0] else [])]
        self.assertTrue(probes, "sudo probe must use -n")
        self.assertIn("timeout", probes[0][1])

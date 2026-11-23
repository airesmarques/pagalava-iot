"""
Tests for the device asking the cloud for its relay configuration.

These import the real ReceiveMessages module rather than re-implementing its
logic, because the bugs worth catching here live in the wiring: whether the
startup check actually fires, whether a failed request is survivable, and
whether a missing config triggers a retry. To do that the test has to stand in
for the hardware — RPi.GPIO does not exist off a Pi, and the module exits at
import time without a connection string.
"""
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

CONN = ("HostName=digipay2-IoTHub-dev.azure-devices.net;"
        "DeviceId=rpiPagalava99;SharedAccessKey=AAAA==")


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

    # The Azure IoT SDK is not installed off-device either. Only the client
    # class is referenced at import time, and these tests never connect.
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


class TestConfigDetection(unittest.TestCase):

    def test_reports_missing_when_there_is_no_config_json(self):
        with patch.object(rm.os.path, "exists", return_value=False):
            self.assertTrue(rm.config_is_missing())

    def test_reports_present_when_config_json_exists(self):
        with patch.object(rm.os.path, "exists", return_value=True):
            self.assertFalse(rm.config_is_missing())


class TestRequestConfiguration(unittest.TestCase):

    def test_posts_device_id_and_a_valid_token_to_the_dev_backend(self):
        with patch.object(rm.requests, "post") as post:
            post.return_value = MagicMock(status_code=202, text="")
            self.assertTrue(rm.request_configuration())

        url = post.call_args[0][0]
        body = post.call_args[1]["json"]
        # The connection string is a dev one, so it must not reach prod.
        self.assertIn("digipay2-dashboard-dev", url)
        self.assertTrue(url.endswith("/api/laundries/iot/request_configuration"))
        self.assertEqual(body["device_id"], "rpiPagalava99")

        from minute_token import generate_minute_token
        self.assertEqual(body["token"], generate_minute_token("rpiPagalava99"))

    def test_429_is_treated_as_success_because_config_is_already_coming(self):
        with patch.object(rm.requests, "post") as post:
            post.return_value = MagicMock(status_code=429, text="")
            self.assertTrue(rm.request_configuration())

    def test_backend_refusal_is_reported_as_failure(self):
        with patch.object(rm.requests, "post") as post:
            post.return_value = MagicMock(status_code=401, text="Invalid token")
            self.assertFalse(rm.request_configuration())

    def test_an_unreachable_backend_does_not_crash_the_device(self):
        # The messaging loop must survive this: a device that dies because the
        # dashboard was briefly down is worse than one with no relay map.
        with patch.object(rm.requests, "post",
                          side_effect=rm.requests.exceptions.ConnectionError("down")):
            self.assertFalse(rm.request_configuration())

    def test_a_timeout_does_not_crash_the_device(self):
        with patch.object(rm.requests, "post",
                          side_effect=rm.requests.exceptions.Timeout("slow")):
            self.assertFalse(rm.request_configuration())

    def test_the_request_has_a_timeout_at_all(self):
        # Without one, a hung dashboard would block the device forever.
        with patch.object(rm.requests, "post") as post:
            post.return_value = MagicMock(status_code=202, text="")
            rm.request_configuration()
        self.assertIn("timeout", post.call_args[1])
        self.assertGreater(post.call_args[1]["timeout"], 0)


class TestStartupHook(unittest.TestCase):

    def test_asks_only_when_config_is_missing(self):
        with patch.object(rm, "config_is_missing", return_value=True), \
             patch.object(rm, "request_configuration") as req:
            rm.request_configuration_if_missing()
        req.assert_called_once()

    def test_stays_quiet_when_config_is_present(self):
        # Every deployed device already has config.json. This file reaches all
        # of them through update_pagalava.sh, so it must do nothing there.
        with patch.object(rm, "config_is_missing", return_value=False), \
             patch.object(rm, "request_configuration") as req:
            rm.request_configuration_if_missing()
        req.assert_not_called()


class TestSelfHealOnActivation(unittest.TestCase):

    def test_a_missing_relay_map_triggers_a_configuration_request(self):
        exc = rm.MachineNotConfiguredException(1)
        with patch.object(rm.relay_ops, "activate_machine_v1_2", side_effect=exc), \
             patch.object(rm, "request_configuration") as req:
            rm.message_activate({"machine_id": 1, "number_of_impulses": 1})
        req.assert_called_once()

    def test_a_successful_activation_asks_for_nothing(self):
        with patch.object(rm.relay_ops, "activate_machine_v1_2"), \
             patch.object(rm, "request_configuration") as req:
            rm.message_activate({"machine_id": 1, "number_of_impulses": 1})
        req.assert_not_called()


if __name__ == "__main__":
    unittest.main()

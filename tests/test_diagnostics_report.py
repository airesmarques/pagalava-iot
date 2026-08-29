"""
Tests for device diagnostics.

The property that matters most is not that the report is correct — it is that a
BROKEN report cannot stop the service starting. Diagnostics run during startup on
devices with no inbound SSH, so if gathering facts could raise, this feature
would be a new way to take a laundromat offline. That is precisely the failure it
exists to prevent, and it would be a poor joke to introduce it here.

Also asserted: the connection string never appears in a report. The point is to
learn WHERE the credential lives, not to copy it to a backend.
"""
import json
import os
import sys
import types
import unittest
import unittest.mock
from unittest.mock import patch

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

import diagnostics_report


class CollectNeverRaises(unittest.TestCase):
    """Every probe is individually guarded; a broken environment yields a
    partial report, not an exception."""

    def test_collect_survives_unreadable_os_release(self):
        with patch("builtins.open", side_effect=PermissionError("nope")):
            report = diagnostics_report.collect()
        self.assertIsInstance(report, dict)  # partial, but a dict

    def test_collect_survives_a_missing_git(self):
        with patch("subprocess.run", side_effect=FileNotFoundError("no git")):
            report = diagnostics_report.collect()
        self.assertIsInstance(report, dict)
        self.assertNotIn("git_commit", report)  # absent, not None, not a crash

    def test_collect_survives_everything_failing_at_once(self):
        with patch("builtins.open", side_effect=OSError), \
             patch("subprocess.run", side_effect=OSError), \
             patch("os.stat", side_effect=OSError), \
             patch("os.statvfs", side_effect=OSError):
            report = diagnostics_report.collect()
        self.assertIsInstance(report, dict)

    def test_a_real_collect_reports_the_basics(self):
        report = diagnostics_report.collect()
        self.assertIn("python_version", report)
        self.assertIn("os_pretty", report)
        # Every value is a string: Table Storage is schemaless and would happily
        # store a mixed type that surprises a reader later.
        for key, value in report.items():
            self.assertIsInstance(value, str, "%s should be a string" % key)


class SendNeverRaises(unittest.TestCase):
    """send() is called while the service starts. It must swallow everything."""

    def test_a_network_failure_is_survived(self):
        fake_requests = types.ModuleType("requests")
        def boom(*a, **k):
            raise OSError("network unreachable")
        fake_requests.post = boom
        with patch.dict(sys.modules, {"requests": fake_requests}):
            result = diagnostics_report.send("rpiPagalava99", "example.test",
                                             lambda d: "token")
        self.assertFalse(result)

    def test_a_backend_500_is_survived(self):
        fake_requests = types.ModuleType("requests")
        fake_requests.post = lambda *a, **k: types.SimpleNamespace(
            status_code=500, text="boom")
        with patch.dict(sys.modules, {"requests": fake_requests}):
            result = diagnostics_report.send("rpiPagalava99", "example.test",
                                             lambda d: "token")
        self.assertFalse(result)

    def test_a_400_is_survived_and_reported_as_such(self):
        """400 means a field was added here but not to the backend allow-list."""
        fake_requests = types.ModuleType("requests")
        fake_requests.post = lambda *a, **k: types.SimpleNamespace(
            status_code=400, text="Disallowed parameter(s): something_new")
        with patch.dict(sys.modules, {"requests": fake_requests}):
            with self.assertLogs(level="WARNING") as logs:
                result = diagnostics_report.send("rpiPagalava99", "example.test",
                                                 lambda d: "token")
        self.assertFalse(result)
        self.assertTrue(any("rejected" in line for line in logs.output))

    def test_a_broken_token_generator_is_survived(self):
        def boom(_):
            raise RuntimeError("token machinery broken")
        result = diagnostics_report.send("rpiPagalava99", "example.test", boom)
        self.assertFalse(result)

    def test_a_successful_report_returns_true(self):
        sent = {}
        fake_requests = types.ModuleType("requests")
        def capture(url, json=None, timeout=None):
            sent["url"] = url
            sent["payload"] = json
            return types.SimpleNamespace(status_code=200, text="ok")
        fake_requests.post = capture
        with patch.dict(sys.modules, {"requests": fake_requests}):
            result = diagnostics_report.send("rpiPagalava99", "example.test",
                                             lambda d: "tok123")
        self.assertTrue(result)
        self.assertIn("/api/laundries/iot/diagnostics_callback", sent["url"])
        self.assertEqual(sent["payload"]["device_id"], "rpiPagalava99")
        self.assertEqual(sent["payload"]["token"], "tok123")


class TheCredentialNeverTravels(unittest.TestCase):
    def test_no_report_field_contains_a_connection_string(self):
        report = diagnostics_report.collect()
        blob = json.dumps(report)
        for marker in ("SharedAccessKey", "HostName=", "azure-devices.net"):
            self.assertNotIn(marker, blob,
                             "a report must never carry the connection string")

    def test_connection_source_reports_location_only(self):
        """The value is one of four words, never the credential."""
        source = diagnostics_report._connection_source()
        self.assertIn(source, ("env_file", "unit_environment", "both", "neither"))


if __name__ == "__main__":
    unittest.main()


class ConfigAndClock(unittest.TestCase):
    """
    The two states that make a device look healthy while it is not.

    A device with no config.json fails every activation silently, and a device
    whose clock is behind cannot complete the IoT Hub TLS handshake at all. Both
    were invisible to the fleet before this, and both were seen on the 1.8.1
    hardware test.
    """

    def test_has_config_reports_no_when_the_file_is_absent(self):
        with patch("os.path.exists", return_value=False):
            self.assertEqual(diagnostics_report._has_config(), "no")

    def test_has_config_reports_yes_when_the_file_is_present(self):
        with patch("os.path.exists", return_value=True):
            self.assertEqual(diagnostics_report._has_config(), "yes")

    def test_config_machines_counts_the_relay_map(self):
        payload = json.dumps({"1": {"relay_number": 4}, "2": {"relay_number": 5}})
        with patch("builtins.open", unittest.mock.mock_open(read_data=payload)):
            self.assertEqual(diagnostics_report._config_machines(), "2")

    def test_config_machines_reports_zero_for_an_empty_map(self):
        """An empty map is a real answer, and the alarming one."""
        with patch("builtins.open", unittest.mock.mock_open(read_data="{}")):
            self.assertEqual(diagnostics_report._config_machines(), "0")

    def test_a_missing_config_leaves_the_count_absent_rather_than_crashing(self):
        with patch("builtins.open", side_effect=FileNotFoundError):
            report = diagnostics_report.collect()
        self.assertNotIn("config_machines", report)

    def test_time_synced_reads_timedatectl(self):
        import types
        with patch("subprocess.run", return_value=types.SimpleNamespace(
                returncode=0, stdout=b"yes\n")):
            self.assertEqual(diagnostics_report._time_synced(), "yes")

    def test_an_unsynced_clock_is_reported_as_no_not_absent(self):
        """The whole point: "behind" must be distinguishable from "unknown"."""
        import types
        with patch("subprocess.run", return_value=types.SimpleNamespace(
                returncode=0, stdout=b"no\n")):
            self.assertEqual(diagnostics_report._time_synced(), "no")

    def test_a_missing_timedatectl_is_survived(self):
        with patch("subprocess.run", side_effect=FileNotFoundError):
            report = diagnostics_report.collect()
        self.assertIsInstance(report, dict)
        self.assertNotIn("time_synced", report)

"""
The firmware version must have exactly two components.

Three-component versions are not cosmetic. `float("1.7.1")` raises ValueError,
and the backend compared device_version with float() in three places. Two of them
swallowed the exception and silently disabled activation callbacks; the third let
it propagate, so NO configuration was ever sent to such a device — a laundromat
that could not be reconfigured at all while every dashboard screen showed it
healthy. It reached production on laundries 1 and 2 before anyone noticed, and
only because those are ours and reachable by SSH.

The backend now compares component-wise and handles 1.7.1 correctly, so this is
belt and braces. It is here because a convention nobody enforces drifts, and the
cost of drifting is invisible breakage in the field.
"""
import json
import os
import re
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TWO_COMPONENT = re.compile(r"^[0-9]+\.[0-9]+$")


class VersionFormat(unittest.TestCase):

    def test_version_json_has_exactly_two_components(self):
        with open(os.path.join(REPO, "version.json"), encoding="utf-8") as handle:
            version = json.load(handle)["version"]
        self.assertRegex(
            version, TWO_COMPONENT,
            "firmware version %r must be MAJOR.MINOR. A third component breaks "
            "float()-based comparisons in the backend and silently stops "
            "configuration reaching the device." % version,
        )

    def test_the_check_would_actually_catch_a_three_component_version(self):
        """A guard that cannot fail is not a guard."""
        for bad in ("1.7.1", "1.8.1", "2.0.0"):
            self.assertNotRegex(bad, TWO_COMPONENT)
        for good in ("1.7", "1.8", "1.9", "1.10", "2.0"):
            self.assertRegex(good, TWO_COMPONENT)


if __name__ == "__main__":
    unittest.main()

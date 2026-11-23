#!/usr/bin/env python3
"""
Does a device's existing config.json still work after a firmware upgrade?

This is the upgrade hazard the file-level checks cannot see. `config.json` is
untracked, so an upgrade leaves it exactly as it was — but the NEW firmware may
read it with a stricter loader than the old one used.

Concretely: activate_machine_v1_2 requires interval_between_impulses_ms and
number_of_impulses_activation. A config written for a pre-1.2 device has
neither. The loader catches the KeyError, logs "Invalid format", and returns
{} — so every activation then raises MachineNotConfiguredException and fails,
with nothing visible from the cloud.

Run before shipping a version bump:
    python3 tests/check_config_compat.py
"""
import json
import os
import sys
import tempfile
import types
from unittest.mock import MagicMock

# relay_ops imports RPi.GPIO at module scope, which does not exist off a Pi.
_fake = MagicMock()
_fake.BCM, _fake.OUT, _fake.HIGH, _fake.LOW = "BCM", "OUT", 1, 0
_rpi = types.ModuleType("RPi")
_rpi.GPIO = _fake
sys.modules.setdefault("RPi", _rpi)
sys.modules.setdefault("RPi.GPIO", _fake)

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
import relay_ops  # noqa: E402

# What the cloud sends, by the device version it believes it is talking to.
# Mirrors the branches in digipay_iot/iot_device_manager.py.
CONFIG_SHAPES = {
    "pre-1.2 (cloud sent the simple shape)": {
        "1": {"machine_id": "1", "relay_number": "9", "time_relay_ms": "2000"},
    },
    "1.2+ (cloud sent the full shape)": {
        "1": {
            "machine_id": "1",
            "relay_number": "9",
            "time_relay_ms": "2000",
            "interval_between_impulses_ms": "1000",
            "number_of_impulses_activation": "1",
        },
    },
}

# The loader each firmware line uses for activation.
LOADERS = {
    "v1.0": relay_ops.load_relay_mapping_v1_0,
    "v1.1": relay_ops.load_relay_mapping_v1_1,
    "v1.2+ (used by 1.2 through 1.8)": relay_ops.load_relay_mapping_v1_2,
}


def _load(loader, config):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(config, fh)
        path = fh.name
    try:
        return loader(path)
    except Exception as exc:                      # noqa: BLE001
        return f"RAISED {type(exc).__name__}: {exc}"
    finally:
        os.unlink(path)


def main() -> int:
    print("Which stored config.json survives which firmware loader?\n")
    failures = []

    for shape_name, config in CONFIG_SHAPES.items():
        print(f"  config on disk: {shape_name}")
        for loader_name, loader in LOADERS.items():
            result = _load(loader, config)
            if isinstance(result, str):
                verdict, detail = "ERROR", result
            elif not result:
                verdict, detail = "BREAKS", "loader returned {} — every activation fails"
            else:
                verdict, detail = "works", f"{len(result)} machine(s) mapped"
            print(f"      {loader_name:<32} {verdict:<7} {detail}")
            if verdict != "works":
                failures.append((shape_name, loader_name))
        print()

    print("Conclusion for a real upgrade:")
    print("  A device's config.json is written by the CLOUD, which chooses the shape")
    print("  from the device_version it has stored. Any device the cloud believed was")
    print("  1.2 or newer already holds the full shape, so upgrading it is safe.")
    print("  A device the cloud believed was older holds the simple shape, and the")
    print("  v1.2+ loader cannot read it.\n")

    broken = [f for f in failures if "1.2+" in f[1] and "pre-1.2" in f[0]]
    if broken:
        print("  ACTION: before upgrading a fleet, confirm no device is recorded below")
        print("  1.2 in IoTConfiguration. For any that are, push configuration from the")
        print("  dashboard AFTER the upgrade — the cloud will then send the full shape.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""
Collect facts about this device, for the fleet diagnostics endpoint.

WHY: we did not know what our own devices were running. Firmware 1.8 used an
annotation that is valid on Python 3.10+ and raises TypeError on 3.9, and the
device crash-looped sixty-three times. It was recovered in minutes only because
that site happens to be reachable by SSH; most are not, and a device that will
not start is a van and an afternoon.

Probing two devices by hand then produced three surprises in a row: the IoT
connection string is world-readable (mode 644, in both the systemd unit and
.env), one device has no .env at all, and neither could restart its own service
after an upgrade. Planning a fleet migration on guesses like that is how the
first incident happened.

WHAT THIS NEVER DOES: send the connection string. It reports where the string
lives and how exposed the file is — never its value. Read `_connection_source`
with that in mind.

EVERY FUNCTION HERE MUST BE UNABLE TO RAISE. This is called while the service
starts, and diagnostics failing to gather must never be the reason a laundromat
stops taking payments. That is the whole lesson. Each probe is individually
guarded and returns None on failure; a missing field is simply absent from the
report.

Python 3.9 compatible: no PEP 604 annotations anywhere in this file, or in
anything the service imports. See tests/test_python39_compat.py.
"""
import json
import logging
import os
import subprocess
import sys

SERVICE_UNIT = "/etc/systemd/system/receive_messages.service"
SUDOERS_RULE = "/etc/sudoers.d/pagalava-restart"


def _safe(fn, default=None):
    """Run a probe, swallowing anything it throws."""
    try:
        return fn()
    except Exception:  # deliberately broad: a probe must never propagate
        return default


def _os_release():
    """PRETTY_NAME and VERSION_ID from /etc/os-release."""
    values = {}
    with open("/etc/os-release", "r", encoding="utf-8") as handle:
        for line in handle:
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip('"')
    return values.get("PRETTY_NAME"), values.get("VERSION_ID")


def _python_version():
    return "%d.%d.%d" % sys.version_info[:3]


def _repo_dir():
    return os.path.dirname(os.path.abspath(__file__))


def _git(*args):
    result = subprocess.run(
        ["/usr/bin/git"] + list(args),
        cwd=_repo_dir(),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=10,
    )
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", "replace").strip() or None


def _firmware_version():
    with open(os.path.join(_repo_dir(), "version.json"), "r", encoding="utf-8") as handle:
        return json.load(handle).get("version")


def _connection_source():
    """
    Where the connection string comes from: env_file, unit_environment, both, or
    neither.

    This is not academic. Of the two devices we could inspect, one had it in both
    places and the other had no .env at all — which means `configurar.py` cannot
    switch that device's environment, and anyone reasoning about .env as the
    source of truth is wrong for part of the fleet.

    Only presence is reported. The value is never read into the report.
    """
    in_env_file = False
    env_path = os.path.join(_repo_dir(), ".env")
    if os.path.exists(env_path):
        with open(env_path, "r", encoding="utf-8", errors="replace") as handle:
            in_env_file = any(
                line.strip().startswith("IOT_CONNECTION_STRING") for line in handle
            )

    in_unit = False
    if os.path.exists(SERVICE_UNIT):
        with open(SERVICE_UNIT, "r", encoding="utf-8", errors="replace") as handle:
            in_unit = any(
                line.startswith("Environment=") and "IOT_CONNECTION_STRING" in line
                for line in handle
            )

    if in_env_file and in_unit:
        return "both"
    if in_env_file:
        return "env_file"
    if in_unit:
        return "unit_environment"
    return "neither"


def _env_file_state():
    """symlink / file / missing. A symlink means first-boot provisioning ran."""
    path = os.path.join(_repo_dir(), ".env")
    if os.path.islink(path):
        return "symlink"
    if os.path.isfile(path):
        return "file"
    return "missing"


def _mode(path):
    """Permission bits as a string, e.g. '644'. Follows symlinks."""
    return oct(os.stat(path).st_mode & 0o777)[2:]


def _unit_field(field):
    """A field from the systemd unit, e.g. User= or WorkingDirectory=."""
    with open(SERVICE_UNIT, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith(field + "="):
                return line.split("=", 1)[1].strip()
    return None


def _install_mode():
    """
    How this device was installed: root, user, or image.

    A device set up with `sudo` runs as root out of /root — functional, but not
    the intended configuration, and we want to count how many exist before
    tidying them up. An image-installed device has .env as a symlink to
    .env.<environment>, which only first-boot provisioning creates.
    """
    if os.geteuid() == 0:
        return "root"
    return "image" if os.path.islink(os.path.join(_repo_dir(), ".env")) else "user"


def _config_path():
    return os.path.join(_repo_dir(), "config.json")


def _has_config():
    """
    Whether this device has a relay map at all.

    A device without one fails EVERY activation with
    MachineNotConfiguredException, and message_activate never reports failures
    home — so the device looks healthy from the dashboard while the laundromat
    opens nothing. Nothing else in the fleet reports this, which is why a
    freshly imaged Pi could sit unconfigured and look fine.
    """
    return "yes" if os.path.exists(_config_path()) else "no"


def _config_machines():
    """How many machines the relay map covers. '0' is a real and alarming answer."""
    with open(_config_path(), "r", encoding="utf-8") as handle:
        return str(len(json.load(handle)))


def _time_synced():
    """
    Whether the clock has been corrected since boot.

    A Pi has no RTC. If the clock is behind, the IoT Hub TLS handshake fails with
    "certificate is not yet valid" and the device cannot connect at all — which
    presents as a dead device with no explanation. Observed on the 1.8.1 image
    test: the Pi booted believing it was four months earlier and only connected
    once NTP corrected it.
    """
    result = subprocess.run(
        ["/usr/bin/timedatectl", "show", "-p", "NTPSynchronized", "--value"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=10,
    )
    if result.returncode != 0:
        return None
    value = result.stdout.decode("utf-8", "replace").strip().lower()
    return "yes" if value == "yes" else "no"


def _disk_free_mb():
    stat = os.statvfs(_repo_dir())
    return int(stat.f_bavail * stat.f_frsize / (1024 * 1024))


def _uptime_seconds():
    with open("/proc/uptime", "r", encoding="utf-8") as handle:
        return int(float(handle.read().split()[0]))


def collect():
    """
    Everything we know about this device, as a flat dict of strings.

    Never raises. A probe that fails is simply absent from the result, so a
    partial report is still useful — better than no report because one file was
    unreadable.

    Keys here must match REPORT_FIELDS on the backend. The endpoint's allow-list
    is built from that tuple and REJECTS unknown fields with 400, so adding a key
    here requires adding it there and deploying the backend first.
    """
    pretty, version_id = _safe(_os_release, (None, None))

    report = {
        "os_pretty": pretty,
        "os_version_id": version_id,
        "python_version": _safe(_python_version),
        "firmware_version": _safe(_firmware_version),
        "git_commit": _safe(lambda: _git("rev-parse", "--short", "HEAD")),
        "git_branch": _safe(lambda: _git("rev-parse", "--abbrev-ref", "HEAD")),
        "connection_string_source": _safe(_connection_source),
        "env_file_state": _safe(_env_file_state),
        "env_file_mode": _safe(lambda: _mode(os.path.join(_repo_dir(), ".env"))),
        "unit_file_mode": _safe(lambda: _mode(SERVICE_UNIT)),
        "service_user": _safe(lambda: _unit_field("User")),
        "working_dir": _safe(lambda: _unit_field("WorkingDirectory")),
        "install_mode": _safe(_install_mode),
        "has_sudoers_rule": _safe(lambda: "yes" if os.path.exists(SUDOERS_RULE) else "no"),
        "has_firstboot": _safe(
            lambda: "yes" if os.path.exists(os.path.join(_repo_dir(), "firstboot.sh")) else "no"
        ),
        "disk_free_mb": _safe(_disk_free_mb),
        "uptime_seconds": _safe(_uptime_seconds),
        "has_config": _safe(_has_config),
        "config_machines": _safe(_config_machines),
        "time_synced": _safe(_time_synced),
    }

    # Drop anything that could not be gathered, so the backend stores facts
    # rather than a scattering of nulls.
    return {key: str(value) for key, value in report.items() if value is not None}


def send(device_id, base_url, generate_token):
    """
    Post the report. Returns True if the backend accepted it.

    Never raises. Called during service startup, and diagnostics must never be
    the reason a device fails to start.

    :param device_id: this device's IoT id
    :param base_url: backend host, from determine_environment()
    :param generate_token: callable producing a minute token for device_id
    """
    try:
        import requests

        payload = collect()
        payload["device_id"] = device_id
        payload["token"] = generate_token(device_id)

        url = "https://%s/api/laundries/iot/diagnostics_callback" % base_url
        response = requests.post(url, json=payload, timeout=15)

        if response.status_code == 200:
            logging.info(
                "diagnostics: reported %s / python %s / connection string from %s",
                payload.get("os_pretty", "?"),
                payload.get("python_version", "?"),
                payload.get("connection_string_source", "?"),
            )
            return True

        # 400 here almost certainly means a field was added to collect() without
        # being added to the backend's allow-list. Say so, because the symptom is
        # otherwise mystifying.
        logging.warning(
            "diagnostics: backend rejected the report (%s): %s",
            response.status_code,
            response.text[:200],
        )
        return False
    except Exception as exc:  # deliberately broad — see the module docstring
        logging.warning("diagnostics: could not report - %s", exc)
        return False

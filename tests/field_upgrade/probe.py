"""Observe subprocesses without replacing the historical handler or update script."""

import importlib
from importlib.metadata import requires
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from types import ModuleType
from unittest.mock import patch

sys.path.insert(0, os.getcwd())


def hardware_stub():
    rpi = ModuleType("RPi")
    gpio = ModuleType("RPi.GPIO")
    for constant in ("BCM", "BOARD", "OUT", "IN", "HIGH", "LOW"):
        setattr(gpio, constant, 0)
    for method in ("setmode", "setwarnings", "setup", "output", "input", "cleanup"):
        setattr(gpio, method, lambda *args, **kwargs: 0)
    rpi.GPIO = gpio
    sys.modules.update({"RPi": rpi, "RPi.GPIO": gpio})


def load_service():
    hardware_stub()
    # Import the actual SDK, including its dependencies, before replacing its
    # client class. The service's __main__ block is never entered.
    from azure.iot import device
    with patch.object(device, "IoTHubDeviceClient"):
        import ReceiveMessages
    return ReceiveMessages


def head():
    return subprocess.check_output(
        ["/usr/bin/git", "rev-parse", "HEAD"], text=True
    ).strip()


def upgrade(revision, source, target, policy, os_version):
    print(f"Unit PATH={os.environ['PATH']} uid={os.getuid()} tty={os.isatty(0)}",
          flush=True)
    import requests
    print(f"Fresh requirements: requests {requests.__version__}", flush=True)
    if revision in ("653acde", "e2c69ea"):
        for package in ("azure-iot-device", "requests-unixsocket2"):
            dependencies = [dep for dep in requires(package) if dep.lower().startswith("requests")]
            print(f"REQUIREMENTS {package}: {dependencies}", flush=True)
    service = load_service()
    assert head() == source
    if revision == "1fefd13":
        commands = ("readlink", "dirname", "mktemp", "mkdir", "cat", "timeout", "rm", "sed")
        missing = [command for command in commands if shutil.which(command) is None]
        print(f"UNIT PATH missing: {', '.join(missing)}", flush=True)
        assert missing == list(commands)
    original_run = subprocess.run
    original_popen = subprocess.Popen
    updates = []
    probes = []
    restarts = []

    def run(argv, *args, **kwargs):
        if argv[0] == "/bin/bash" and argv[1].endswith("/update_pagalava.sh"):
            result = None
            try:
                result = original_run(argv, *args, **kwargs)
            except subprocess.CalledProcessError as error:
                result = error
                raise
            finally:
                if result is not None:
                    print(f"UPDATE rc={result.returncode} argv={argv!r}", flush=True)
                    print(f"UPDATE stdout:\n{result.stdout or ''}", flush=True)
                    print(f"UPDATE stderr:\n{result.stderr or ''}", flush=True)
                    updates.append(result.returncode)
        elif argv[0] == "/usr/bin/sudo" and "-l" in argv:
            # Preserve the discarded output in the observation log.
            kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            result = original_run(argv, *args, **kwargs)
            probes.append(result.returncode)
            print(f"SUDO PROBE rc={result.returncode} argv={argv!r}\n{result.stderr}",
                  flush=True)
        else:
            result = original_run(argv, *args, **kwargs)
        return result

    def popen(argv, *args, **kwargs):
        if argv[0] not in ("sudo", "/usr/bin/sudo") or "-l" in argv:
            return original_popen(argv, *args, **kwargs)
        print(f"RESTART argv={argv!r} sudo_found={shutil.which(argv[0]) is not None}",
              flush=True)
        try:
            process = original_popen(argv, *args, **kwargs)
        except FileNotFoundError:
            restarts.append("missing")
            raise
        # The stand-in exits without killing the service. Reap it for its
        # status and return the same Popen object the handler normally gets.
        _, stderr = process.communicate(timeout=10)
        print(f"RESTART rc={process.returncode}\n{stderr.decode()}", flush=True)
        restarts.append("allowed" if process.returncode == 0 else "denied")
        return process

    with patch.object(subprocess, "run", run), patch.object(subprocess, "Popen", popen):
        result = service.message_upgrade()
    final = head()
    checklog = Path("/tmp/pagalava_upgrade_check.log")
    if checklog.exists():
        print(f"IMPORT CHECK LOG: {checklog.read_text().strip()}", flush=True)
    print(f"RESULT os={os_version} from={revision} target={target[:7]} "
          f"sudo={policy} update={updates} head={final[:7]} handler={result} "
          f"probe={probes} restart={restarts} running={service.VERSION}", flush=True)
    if revision == "1fefd13" and source != target:
        assert (updates, final, probes, restarts, result) == ([1], source, [], [], False)
        assert "timeout: command not found" in checklog.read_text()
    else:
        assert (updates, final) == ([0], target)
        if revision == "653acde":
            assert (probes, restarts, result) == ([], ["missing"], False)
        elif revision in ("613476b", "1fefd13"):
            expected = ([0], ["allowed"]) if policy == "nopasswd" else ([1], [])
            assert (probes, restarts) == expected and result is True
        else:
            expected = "allowed" if policy == "nopasswd" else "denied"
            assert (probes, restarts, result) == ([], [expected], True)


def restart():
    for package in ("requests", "dotenv", "azure.iot.device"):
        try:
            importlib.import_module(package)
        except ImportError as error:
            print(f"RESTART DEPENDENCY {package}: {error}", flush=True)
    service = load_service()
    import ReceiveMessages
    print(f"RESTART IMPORT ok version={ReceiveMessages.VERSION}", flush=True)
    assert service.VERSION == json.loads(Path("version.json").read_text())["version"]


def guard():
    before = head()
    argv = ["/bin/bash", str(Path.cwd() / "update_pagalava.sh")]
    result = subprocess.run(argv, text=True, capture_output=True, check=False)
    print(f"CHANNEL UNIT PATH rc={result.returncode}\n{result.stdout}{result.stderr}")
    assert result.returncode == 0 and head() == before
    assert "dirname: command not found" in result.stderr
    assert "Updating from channel: release/1.9" in result.stdout
    diagnostic_env = dict(os.environ, PATH=os.environ["PATH"] + ":/usr/bin:/bin")
    result = subprocess.run(argv, text=True, capture_output=True, env=diagnostic_env)
    print(f"CHANNEL DIAGNOSTIC PATH rc={result.returncode}\n{result.stdout}{result.stderr}")
    assert result.returncode == 2 and head() == before
    assert "REFUSING TO UPDATE: channel 'main'" in result.stderr


def activation():
    service = load_service()
    with patch.object(service.relay_ops, "activate_machine_v1_1") as relay:
        service.message_activate({"machine_id": 1, "number_of_impulses": 1})
        relay.assert_called_once_with(machine_id=1, number_of_impulses=1)
    print(f"ACTIVATION version={service.VERSION} selected=activate_machine_v1_1")
    assert service.VERSION == "1.10"


if __name__ == "__main__":
    action, *args = sys.argv[1:]
    {"upgrade": upgrade, "guard": guard, "activation": activation}[action](*args)

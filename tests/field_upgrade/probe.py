"""Observe subprocesses without replacing the historical handler or update script."""

import importlib
from importlib.metadata import requires
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from types import ModuleType, SimpleNamespace
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


def upgrade(revision, source, target, policy, os_version, version, expected_outcome):
    print(f"Unit PATH={os.environ['PATH']} uid={os.getuid()} tty={os.isatty(0)}",
          flush=True)
    import requests
    print(f"Fresh requirements: requests {requests.__version__}", flush=True)
    if revision in ("653acde", "e2c69ea"):
        for package in ("azure-iot-device", "requests-unixsocket2"):
            dependencies = [dep for dep in requires(package) if dep.lower().startswith("requests")]
            print(f"REQUIREMENTS {package}: {dependencies}", flush=True)
    service = load_service()
    assert head() == source and service.VERSION == version
    if revision == "1fefd13":
        commands = ("readlink", "dirname", "mktemp", "mkdir", "cat", "timeout", "rm", "sed")
        missing = [command for command in commands if shutil.which(command) is None]
        print(f"UNIT PATH missing: {', '.join(missing)}", flush=True)
        assert missing == list(commands)
    original_run = subprocess.run
    original_popen = subprocess.Popen
    update_stderr = []
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
                    update_stderr.append(result.stderr or "")
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
    target_version = subprocess.check_output(
        ["/usr/bin/git", "show", f"{target}:version.json"], text=True
    )
    if json.loads(target_version)["version"] == "1.10":
        assert any("SCRIPT FD offset=" in stderr for stderr in update_stderr)
    if expected_outcome == "stays":
        assert (updates, final, probes, restarts, result) == ([1], source, [], [], False)
        assert "timeout: command not found" in checklog.read_text()
    else:
        assert (updates, final) == ([0], target)
        if expected_outcome == "restart":
            assert (probes, restarts, result) == ([], ["missing"], False)
        elif revision == "613476b":
            assert expected_outcome == "auto"
            expected = ([0], ["allowed"]) if policy == "nopasswd" else ([1], [])
            assert (probes, restarts) == expected and result is True
        else:
            assert expected_outcome == "auto"
            expected = "allowed" if policy == "nopasswd" else "denied"
            assert (probes, restarts, result) == ([], [expected], True)

    if revision in ("653acde", "e2c69ea"):
        reboot(service, revision, policy)


def restart(expected_version):
    for package in ("requests", "dotenv", "azure.iot.device"):
        try:
            importlib.import_module(package)
        except ImportError as error:
            print(f"RESTART DEPENDENCY {package}: {error}", flush=True)
    service = load_service()
    import ReceiveMessages
    print(f"RESTART IMPORT ok version={ReceiveMessages.VERSION}", flush=True)
    assert service.VERSION == expected_version


def image(version):
    assert not Path(".git").exists()
    assert load_service().VERSION == version
    result = subprocess.run(
        ["/bin/bash", str(Path.cwd() / "update_pagalava.sh")],
        capture_output=True, text=True,
    )
    print(result.stdout + result.stderr)
    assert result.returncode == 2 and "re-flash" in result.stderr
    assert not Path(".git").exists()


def reboot(service, revision, policy):
    original = subprocess.Popen
    commands = []

    def observe(argv, *args, **kwargs):
        process = original(argv, *args, **kwargs)
        process.communicate(timeout=10)
        commands.append((argv, all(shutil.which(command) for command in argv[:2]),
                         process.returncode))
        return process

    with patch.object(subprocess, "Popen", observe):
        service.message_handler(SimpleNamespace(data=b'{"msg_type":"reboot"}'))
    print(f"REBOOT dispatch={revision} calls={commands}")
    if revision == "653acde":
        assert commands == []
    else:
        status = 0 if policy == "nopasswd" else 1
        assert commands == [(["/usr/bin/sudo", "/sbin/reboot"], True, status)]


def second_hop(remote, policy, version, revision):
    service = load_service()
    initial = head()
    assert service.VERSION == version
    argv = ["/bin/bash", str(Path.cwd() / "update_pagalava.sh")]

    def git(*args):
        return subprocess.check_output(
            ["/usr/bin/git", *args], text=True, stderr=subprocess.STDOUT
        ).strip()

    def publish():
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "-qam", "Temporary fixture")
        target = head()
        git(f"--git-dir={remote}", "fetch", "--quiet", "--no-tags", "--force",
            str(Path.cwd()), "HEAD:refs/heads/main")
        git("reset", "--hard", initial)
        return target

    original_run = subprocess.run

    def exercise(case, expected_code, expected_head, expected_restart, expected_runtime):
        events = []

        def observe(command, *args, **kwargs):
            result = original_run(command, *args, **kwargs)
            if command == argv:
                events.append(("update", result.returncode))
            if command[0] == "/usr/bin/sudo":
                assert command == ["/usr/bin/sudo", "-n", "/usr/bin/systemctl",
                                   "restart", "receive_messages.service"]
                events.append(("restart", result.returncode))
            return result

        with patch.object(subprocess, "run", observe):
            accepted = service.message_upgrade()
        expected = [("update", expected_code)]
        if expected_restart is not None:
            expected.append(("restart", expected_restart))
        assert events == expected, events
        assert accepted == (expected_restart == 0 or case == "current")
        if expected_head:
            assert head() == expected_head
        report = service.diagnostics_report.collect()
        assert report["firmware_version"] == version
        assert report["upgrade_runtime_state"] == expected_runtime
        print(f"SECOND HOP {case} events={events} handler={accepted} "
              f"runtime={report['upgrade_runtime_state']} running={service.VERSION}")

    exercise("current", 10, initial, None, "current")
    components = version.split(".")
    components[-1] = str(int(components[-1]) + 1)
    next_version = ".".join(components)
    Path("version.json").write_text(json.dumps({"version": next_version}))
    newer = publish()
    restart_status = 0 if policy == "nopasswd" else 1
    exercise("healthy", 0, newer, restart_status, "restart_pending")
    output = subprocess.check_output(
        [sys.executable, "/rig/probe.py", "restart", next_version], text=True,
    )
    assert f"RESTART IMPORT ok version={next_version}" in output
    print(output.strip())

    print(f"ONWARD {next_version}, restart {'allowed' if restart_status == 0 else 'denied'}")
    if revision != "0d02b65":
        return

    git("reset", "--hard", initial)
    with Path("ReceiveMessages.py").open("a") as handle:
        handle.write('\nraise RuntimeError("deliberate import failure")\n')
    publish()
    exercise("broken", 4, initial, None, "current")

    channel = Path(".update-channel")
    channel.write_text("release/missing\n")
    try:
        exercise("fetch_failed", 3, initial, None, "current")
    finally:
        channel.unlink()

    repository = Path(".git")
    hidden = repository.rename(".git.offline")
    try:
        exercise("no_git", 2, None, None, "unknown")
    finally:
        hidden.rename(repository)


def credential():
    invoke = [sys.executable, "-c", "import probe; print(probe.load_service().IOT_CONNECTION_STRING)"]
    env = dict(os.environ, PYTHONPATH="/rig")
    file = Path(".env")
    symlink_target = Path(".env.fixture")
    try:
        assert subprocess.check_output(invoke, env=env, text=True).strip() == "offline-fixture"
        file.write_text("IOT_CONNECTION_STRING=file-fixture\n")
        assert subprocess.check_output(invoke, env=env, text=True).strip() == "file-fixture"
        file.rename(symlink_target)
        file.symlink_to(symlink_target)
        assert subprocess.check_output(invoke, env=env, text=True).strip() == "file-fixture"
        file.unlink()
        result = subprocess.run(invoke, env={k: v for k, v in env.items() if k != "IOT_CONNECTION_STRING"},
                                capture_output=True, text=True)
        assert result.returncode == 1 and "required in .env or the systemd unit" in result.stderr
    finally:
        file.unlink(missing_ok=True)
        symlink_target.unlink(missing_ok=True)
    print("Credential sources: unit fallback, plain .env and symlink precedence, missing fatal")


def relay(version):
    # The config is opened relative to the service working directory.
    config = Path("config.json")
    config.write_text(json.dumps({"7": {
        "machine_id": "7", "relay_number": "9", "time_relay_ms": "1375",
        "interval_between_impulses_ms": "225", "number_of_impulses_activation": "2",
    }}))
    service = load_service()
    service.VERSION = version
    calls = []
    ops = service.relay_ops
    try:
        with patch.object(ops, "control_relay", side_effect=lambda *args: calls.append(("relay", *args))), \
             patch.object(ops.time, "sleep", side_effect=lambda seconds: calls.append(("sleep", seconds))), \
             patch.object(ops.GPIO, "LOW", 0), patch.object(ops.GPIO, "HIGH", 1):
            data = json.dumps({"msg_type": "activate", "machine_id": "7",
                               "number_of_impulses": 2}).encode()
            service.message_handler(SimpleNamespace(data=data))
    finally:
        config.unlink()
    assert len(calls) == 15, calls
    print("RELAY TRACE " + json.dumps(calls))


if __name__ == "__main__":
    action, *args = sys.argv[1:]
    {
        "upgrade": upgrade, "image": image, "restart": restart,
        "second_hop": second_hop, "credential": credential,
        "relay": relay,
    }[action](*args)

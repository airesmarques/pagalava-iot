# Field upgrade rig

Run one historical upgrade or the full 40-case matrix from the firmware worktree.

```sh
tests/field_upgrade/run.sh --from 1.3 --os 11 --target 0d02b65
tests/field_upgrade/run.sh --from 1.8-plain --os 12 --target 61b7afa --sudo password
tests/field_upgrade/matrix.sh field-upgrade-logs
```

Docker builds an image for each OS on first use. To refresh the cached images,
run `tests/field_upgrade/build.sh 11` and `tests/field_upgrade/build.sh 12`.
The image build downloads Debian packages and builds wheels from each starting
revision's requirements. Debian 11 uses the package snapshot advertised by
its base image. Each case then runs with `--network none`, installing only
the starting revision's requirements and their dependencies from those wheels.
The logs include the resolved package versions since the historical
requirements leave most versions unpinned.

The runner transfers Git objects into a disposable container, creates a local
bare origin, and clones it as the service user. It renders the service unit
from the chosen revision's setup script and uses its working directory,
interpreter and exact PATH. It calls the imported historical
`message_upgrade()` with no TTY and observes the actual child processes.
The checkout starts on local `main` and only local `origin/main` is advanced
to the target. The starting script therefore drives the first upgrade even if
the target contains a different updater.

The command stand-ins record the sudo policy probe and any restart request.
They cover passwordless sudo and a password requirement without a TTY.
A separate fresh-interpreter import gives the version after a simulated
restart, including for cases where the handler could not request a restart.
The running process's version comes from the same module constant the
version response uses. A failed expectation gives a nonzero exit status.
A matrix pass means the observed behavior matches the expectations, which
include historical upgrade and restart failures.

There is no real systemd, Pi OS image, GPIO, IoT Hub, or message transport in
the case. The rig loads the actual Python Azure SDK to preserve its dependency
checks and replaces the client class. GPIO module calls are inert and the
service's main loop never starts. The Debian container uses build tools for
the Python hardware wheels and skips the Pi-only apt and hardware setup.
The stand-ins never elevate or kill a process. Local Git transport and a
fresh checkout model manual installs with Git metadata. The separate 1.9
channel diagnostic repeats the target updater with system tools on PATH
to exercise its explicit `main` guard. The version dispatch diagnostic
uses a synthetic `version.json` inside the disposable checkout.

To add a starting point, add its label and commit in `run.sh`, stage its
requirements in `build.sh`, and verify its unit template and expectations
in `device.sh` and `probe.py`. Rebuild the images and add the label to
`matrix.sh`. Pass any locally available target commit with `--target`;
add it to the target loop in `matrix.sh` to cover both OSes and sudo
policies. Review the assertions when a target is expected to change the
checkout, restart, or import behavior.

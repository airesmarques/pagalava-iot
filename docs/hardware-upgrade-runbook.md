# Firmware upgrade matrix on the bench Pi

Use the Raspberry Pi 4 bench Pi with Debian 12 and Python 3.11. The service
user must have passwordless sudo for the service restart, systemd reload,
and installation and removal of the managed drop-in. Use a dedicated DEV
hub identity, a known test relay and load, and an idle service. Coordinate
with other operators so no one sends messages while switching fixtures. Run
one case at a time. Leave the original checkout, unit, home archive folders
and boot media in place.

The bench helper reads the same [expectations data](../tests/field_upgrade/expectations.tsv)
as CI. Run `bench.sh list` for the case IDs, commits, expected first hops
and manual steps. The helper accepts the stock `.env` format, including an
installer or firstboot symlink, and a stock systemd `IOT_CONNECTION_STRING`.
It checks both identity sources for a DEV hostname containing `-dev` and
requires a live `config.json`. The drop-in is
`/etc/systemd/system/receive_messages.service.d/90-fwtest.conf`. The
helper needs read access to the unit and journal and a unit without other drop-ins or environment-file overrides. It copies the credentials
and config privately into the fixture. Keep `~/fwtest` private and keep any
logs containing real device details off public systems.

## Stage the software

On the operator's machine, use a disposable full checkout with the exact
candidate and its ancestor commits. Select the 1.10 target, then make a local
version-only commit for 1.11. Keep the branch and bundle local.

```sh
git switch -c bench-onward <1.10-commit>
printf '{"version":"1.11"}\n' > version.json
git add version.json
git commit -m 'Set throwaway bench version to 1.11'
git bundle create upgrade.bundle bench-onward
git rev-parse HEAD HEAD^
```

Record the first SHA as `ONWARD` and the second as `TARGET`. Transfer
`upgrade.bundle` and the helper with its adjacent data file using the
approved bench access procedure. On the Pi, place the bundle under
`~/fwtest` and keep the installed kit paths like this:

```text
~/fwtest/kit/tests/hardware/upgrade_matrix/bench.sh
~/fwtest/kit/tests/field_upgrade/expectations.tsv
```

On the Pi, as the service user, initialize the fixture origin once. The
helper reads the starting commits from the imported history and each case
installs its own requirements. The Pi needs access to the dependency index
or a prepared dependency mirror.

```sh
umask 077
mkdir -p "$HOME/fwtest"
git init --bare --initial-branch=main "$HOME/fwtest/origin.git"
git --git-dir="$HOME/fwtest/origin.git" fetch "$HOME/fwtest/upgrade.bundle" \
  refs/heads/bench-onward:refs/heads/fixtures/bench-onward
bench="$HOME/fwtest/kit/tests/hardware/upgrade_matrix/bench.sh"
"$bench" list
"$bench" status
```

## Execute each case

For each row printed by `list`, set `CASE` and `START` to that row's
case and commit, using the table below to track the run. The `--yes`
flag permits a backwards move of fixture `main` between cases. For a
repeat, use `"$bench" --yes prepare "$CASE"` after restoring the original
service. A prepared case that is live cannot be replaced.

```sh
"$bench" restore
"$bench" --yes publish "$START"
"$bench" prepare "$CASE"
"$bench" use "$CASE"
"$bench" status
```

Wait for the active invocation to report the case's version. For Git
installs confirm the starting SHA. For the image case confirm the absence
of Git metadata. Send a version request through the DEV dashboard and
confirm the version response before publishing the target. An active
service or a client-ready log alone does not confirm hub connectivity.

For Git installs, publish 1.10 to local `main`. For the image install,
publish it to the local image channel as well so the requested target
exists even though the image cannot fetch it.

```sh
"$bench" publish "$TARGET"
# Only for CASE=1.9-image
"$bench" publish "$TARGET" release/1.9
```

From the operator's machine send the real message to the confirmed DEV
hub and device, substituting the bracketed placeholders with the actual DEV values. Wait for the handler and then run `"$bench" status`
on the Pi. Compare the checkout, current invocation and running version,
and record the result. The Azure CLI send confirms submission. Observe
delivery and restart on the device before advancing.

```sh
az iot device c2d-message send -n <dev hub> -d <device id> --data '{"msg_type": "request_upgrade"}'
```

Apply the branch below that matches the value from `list`.

- **`auto` (1.7, 1.7.1, 1.8 plain)**. Wait for an automatic restart,
  the target checkout and journal version 1.10. Record failure if you
  have to intervene.
- **`restart` (1.3)**. Confirm the checkout is on the target and the original
  invocation still reports 1.3. Run
  `sudo systemctl restart receive_messages.service` on the Pi and
  verify 1.10 and DEV connectivity. The historical dashboard reboot
  handler does not perform a reboot.
- **`stays` (1.8 rollback)**. Confirm that the old updater reports rollback
  and the commit and running version are still 1.8. As the service user run
  `cd "$HOME/fwtest/run/$CASE"`, `git pull --ff-only origin main`, then
  `sudo systemctl restart receive_messages.service`. Verify 1.10 and DEV
  connectivity.
- **`reflash` (1.9 image)**. The fixture uses a snapshot without Git
  metadata. Expect a reflash message, no restart and a running version
  of 1.9. To capture the updater's exit code directly, run
  `(cd "$HOME/fwtest/run/$CASE" && PATH="$PWD/.venv/bin" /bin/bash "$PWD/update_pagalava.sh")`
  and record exit 2. Restore the original service. Run the physical
  reflash only as a separate operator-approved test on spare media
  with a validated target image. For this Git-free case record the
  onward hop as blocked pending reflash. If the replacement image also
  lacks Git metadata, an onward self-upgrade remains unavailable.

Once 1.10 is active, confirm DEV delivery and check the known safe bench
relay. For example, substitute the configured relay number in this
message, then observe and record the physical pulse. A paid test
activation is also valid if the setup calls for it.

```sh
az iot device c2d-message send -n <dev hub> -d <device id> --data '{"msg_type":"test_relay","relay_number":9}'
```

Publish `"$bench" publish "$ONWARD"` on the Pi, send the same upgrade
message from the operator's machine, wait, then run `"$bench" status`.
Verify the onward SHA, a new service invocation and version 1.11, and
confirm a DEV response. Restore before proceeding to the next case.

```sh
"$bench" restore
"$bench" status
```

Restore removes the managed drop-in, reloads systemd and restarts the
service in the original checkout. Use it after a failed prepare or use
as well. Confirm the original directory, active state, baseline version
and DEV response. Preserve the original unit and the archive. Prepared
fixtures remain under `~/fwtest/run` for inspection or a confirmed repeat.

## Results sheet

Record date, target and onward SHAs, OS/Python versions, operator and
redacted evidence references.

| Case | Start SHA/version verified | First hop matched table | Manual action | 1.10 relay observed | 1.11/DEV verified | Restore verified |
| --- | --- | --- | --- | --- | --- | --- |
| 1.3 | | | | | | |
| 1.7 | | | | | | |
| 1.7.1 | | | | | | |
| 1.8-plain | | | | | | |
| 1.8-rollback | | | | | | |
| 1.9-image | | | | | | |

The bench can prove real systemd process replacement, DEV hub delivery
and physical GPIO response. The 1.9 snapshot exercises the updater's
Git-free behavior; physical boot and provisioning require a spare card.
The bench Pi cannot reproduce Debian 11 or Python 3.9. Use CI for that
environment and record any inability to run a historical service on
Debian 12 as a bench test result.

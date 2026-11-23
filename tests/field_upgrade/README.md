# Field upgrade rig

[expectations.tsv](expectations.tsv) is the list of production upgrade paths.
Check the dashboard's device list for deployed versions and counts before
changing it. Confirm the install type and source commit with fleet records
where the dashboard cannot distinguish builds. Keep both known 1.8 builds
until the installed commits are known. Keep 1.7.1 while it is the main
installer or the bench Pi baseline. Each row gives the case, commit, reported
version, install type, Debian versions, expected first hop, reason, and manual
step. Debian 11 is the actual 1.8 environment. Debian 11 and 12 cover the
uncertain manual-install OS versions and Debian 13 checks current compatibility.
The Git-free 1.9 image case runs on its production OS, Debian 12.

```sh
tests/field_upgrade/matrix.sh field-upgrade-logs HEAD
tests/field_upgrade/matrix.sh field-upgrade-logs/12 HEAD 12
tests/field_upgrade/run.sh --from 1.8-plain --os 12 --target HEAD --sudo password
```

Full Git history supplies the source and target objects. Docker builds one
image per OS with wheels keyed by the historical requirements blob. Each
case creates a fresh service user's venv using that commit's requirements
and runs offline. Manual cases clone from a local bare origin and use the
historical systemd template's interpreter and restricted PATH. The starting
handler executes its own updater after local `origin/main` advances. The
image fixture extracts the historical tree without Git metadata and checks
that the actual updater exits 2, requests a reflash, and leaves the tree
untouched.

The matrix checks checkout, updater exit, and restart behavior against the
data. A change in either direction fails the case. `auto` expects a restart
request accepted under passwordless sudo. Under the password-required policy,
the handler either skips the request after its permission probe or the
stand-in denies it. `restart` expects 1.3 to move the files but fail to
request a restart through its restricted PATH. `stays` expects rollback;
the rig then applies the table's manual fast-forward. `reflash` ends at the
image updater's refusal.

Every path reaching the target loads it in a fresh interpreter and exercises
the target's own updater to a throwaway next version. The 1.7.1 fixtures also
check target rollback, missing channel, no Git, already-current behavior,
credential sources, and relay parity with 1.9. The rig records per-case logs
and a Markdown summary. The sudo/systemd stand-ins never restart a real
process. GPIO and the Azure client are stubbed, and no hub, image boot, or
physical relay is required. Use the [bench runbook](../../docs/hardware-upgrade-runbook.md)
for physical testing.

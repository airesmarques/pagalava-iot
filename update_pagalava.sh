#!/bin/bash
# Upgrade the PagaLava software, but prove the new version actually runs on THIS
# device before committing to it.
#
# WHY: many devices are on Debian 11 with Python 3.9 and have no inbound SSH. If
# an upgrade leaves one unable to start, recovering it costs a site visit. That
# happened: a PEP 604 annotation (`int | None`) is valid syntax on 3.9 but raises
# TypeError when evaluated at import, so the files downloaded perfectly and then
# nothing could start — systemd crash-looped it 63 times.
#
# So: fetch, then try to import the service. If it does not import, roll back to
# the version that was running and exit non-zero. A device is never left on code
# it cannot execute.
set -u

cd "$(dirname "$(readlink -f "$0")")" || exit 1

# Which line of firmware this device follows.
#
# There is no dev/prod split in this repo, so the branch IS the channel. Devices
# in the field track `main`, which is deliberately held at 1.7 until moving one
# above that is a considered action rather than a button. Devices installed from
# the golden image track the image's own line, because `main` is OLDER than they
# are — pulling it would silently downgrade them, removing first-boot
# provisioning, the relay test and this rollback check.
#
# A device inherits the channel from the branch it was installed from, and
# .update-channel lets it be moved deliberately without editing this script.
#
# The default moved from release/1.8 to release/1.9 when the image line was
# renumbered (1.8.1 became 1.9, so that no version has three components — see
# tests/test_version_format.py for why that matters). A device with no
# .update-channel file follows the default, so release/1.8 is kept alive as a
# mirror of release/1.9 for exactly one migration: a device still pointing at the
# old branch pulls this script, and its NEXT upgrade follows release/1.9 on its
# own. Do not delete release/1.8 until the devices on it have upgraded once.
CHANNEL_FILE="$(dirname "$(readlink -f "$0")")/.update-channel"
if [ -r "$CHANNEL_FILE" ]; then
    CHANNEL="$(tr -d ' \t\r\n' < "$CHANNEL_FILE")"
else
    CHANNEL="release/1.9"
fi
: "${CHANNEL:=release/1.9}"

PREV="$(/usr/bin/git rev-parse HEAD 2>/dev/null)"

echo "Updating from channel: ${CHANNEL}"
/usr/bin/git fetch --all
/usr/bin/git reset --hard "origin/${CHANNEL}"
/usr/bin/git pull origin "${CHANNEL}"

NEW="$(/usr/bin/git rev-parse HEAD 2>/dev/null)"
if [ "$PREV" = "$NEW" ]; then
    echo "Already up to date at ${NEW}."
    exit 0
fi

# Hardware libraries are stubbed for the check. Importing relay_ops calls
# GPIO.setup(), which would reconfigure pins while the current version is still
# running and could interrupt a machine mid-cycle. Stubs keep the check to what
# it is for: does this code load on this interpreter.
STUB="$(mktemp -d)"
mkdir -p "${STUB}/RPi"
: > "${STUB}/RPi/__init__.py"
cat > "${STUB}/RPi/GPIO.py" <<'STUBPY'
BCM = BOARD = OUT = IN = HIGH = LOW = 0
def setmode(*a, **k): pass
def setwarnings(*a, **k): pass
def setup(*a, **k): pass
def output(*a, **k): pass
def input(*a, **k): return 0
def cleanup(*a, **k): pass
STUBPY
cat > "${STUB}/spidev.py" <<'STUBPY'
class SpiDev:
    def open(self, *a, **k): pass
    def xfer2(self, *a, **k): return []
    def close(self, *a, **k): pass
STUBPY

PY=".venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

CHECKLOG=/tmp/pagalava_upgrade_check.log
if PYTHONPATH="${STUB}" timeout 120 "$PY" -c "import ReceiveMessages" >"${CHECKLOG}" 2>&1; then
    rm -rf "${STUB}"
    echo "Upgrade OK: ${PREV} -> ${NEW} (imports cleanly on $("$PY" --version 2>&1))."
    exit 0
fi

rm -rf "${STUB}"
echo "UPGRADE ABORTED: ${NEW} does not import on this device." >&2
sed 's/^/    /' "${CHECKLOG}" >&2
echo "Rolling back to ${PREV}, which was running." >&2
/usr/bin/git reset --hard "${PREV}" >/dev/null 2>&1
echo "Rolled back. The device stays on the version it had." >&2
exit 1

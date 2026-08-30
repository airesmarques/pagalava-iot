#!/bin/bash
# Upgrade a MANUALLY installed PagaLava device, but prove the new version
# actually runs on THIS device before committing to it.
#
# WHY: most devices are Debian 11 with Python 3.9 and have no inbound SSH. If an
# upgrade leaves one unable to start, recovering it costs a site visit. That
# happened: a PEP 604 annotation (`int | None`) is valid syntax on 3.9 but raises
# TypeError when evaluated at import, so the files downloaded perfectly and then
# nothing could start — systemd crash-looped it 63 times.
#
# So: fetch, then try to import the service. If it does not import, roll back to
# the version that was running and exit non-zero. A device is never left on code
# it cannot execute.
#
# THIS LINE IS DELIBERATELY NOT CHANNEL-AWARE. `origin/main` is hardcoded, so a
# manually-installed device is structurally incapable of pulling the image line
# (release/*). That line is NEWER and assumes first-boot provisioning this device
# never had, so following it would not upgrade the device — it would break it.
# Separation by mechanism beats separation by policy: there is no code path here
# that can reach another branch, whatever anyone clicks in the dashboard.
set -u

cd "$(dirname "$(readlink -f "$0")")" || exit 1

# A manual install is always a git clone, so this should never fire here. It is
# kept identical to the image line's guard because the failure it prevents is
# silent and total: with no repository every git command below fails, PREV and
# NEW both end up empty, `[ "$PREV" = "$NEW" ]` is TRUE, and this script would
# report "Already up to date." and exit 0 — success, forever, having done nothing.
if ! /usr/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "CANNOT UPGRADE: $(pwd) is not a git repository." >&2
    echo "A manual install should be a git clone. If this device was installed" >&2
    echo "from a golden image it follows the image line, not this one." >&2
    exit 2
fi

PREV="$(/usr/bin/git rev-parse HEAD 2>/dev/null)"

echo "Updating from origin/main"
/usr/bin/git fetch --all
/usr/bin/git reset --hard origin/main
/usr/bin/git pull origin main

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

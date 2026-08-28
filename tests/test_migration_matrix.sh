#!/bin/bash
# Migrate a device from every version in the field to the current one, on every
# Debian we support, and check the service still starts afterwards.
#
# WHY: an upgrade is `git reset --hard` onto whatever the channel points at. It
# always "succeeds" — the files download fine. What can fail is the code that
# lands, on the interpreter that device happens to have. That is exactly how a
# laundromat went down: 1.8 pulled cleanly onto Debian 11 and then nothing
# could start.
#
# The static checks in check_upgrade_from.sh compare two commits and reason
# about them. This one actually performs the migration and starts the service.
#
#   ./test_migration_matrix.sh [target-ref] [debian-versions...]
#     default target: HEAD
#     default OS:     11 12 13
set -u
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1

TARGET="${1:-HEAD}"; shift 2>/dev/null || true
OSES="${*:-11 12 13}"

# Versions a device in the field could be on. The untagged ones are real: 1.3
# and 1.5 are running in production and were never tagged.
FROM_VERSIONS="
653acde:1.3
05d84ca:1.5
v1.6:1.6
v1.7:1.7
"

declare -A IMG=( [11]=debian:bullseye-slim [12]=debian:bookworm-slim [13]=debian:trixie-slim )

command -v docker >/dev/null 2>&1 || { echo "  skip  docker not available"; exit 0; }

TARGET_SHA="$(git rev-parse "$TARGET")"
TARGET_LABEL="$(git show "${TARGET_SHA}:version.json" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null || echo "$TARGET")"
echo "Target: ${TARGET_LABEL} ($(git rev-parse --short "$TARGET_SHA"))"
echo "Debian versions tested: ${OSES}"
echo "Starting from every version currently in the field."
echo

pass=0; fail=0
# The bare repo MUST live inside the working tree, not in mktemp. A CI job runs
# in its own container whose /tmp is private, so a path there is invisible to
# the Docker daemon and the mount silently arrives empty — every container then
# reported "not a git repository". The workspace is a real host volume, so a
# path under it is visible to both.
BARE="${PWD}/.migration-repo.git"
rm -rf "$BARE"
git clone -q --bare . "$BARE"
trap 'rm -rf "$BARE"' EXIT

# A CI checkout does not necessarily carry tags or the full history, and
# "CHECKOUTFAIL" inside a container is a useless way to discover that. Check
# here, where the message can be clear.
missing=""
for row in $FROM_VERSIONS; do
    [ -n "$row" ] || continue
    r="${row%%:*}"
    git --git-dir="$BARE" rev-parse --verify -q "${r}^{commit}" >/dev/null 2>&1 || missing="${missing} ${r}"
done
if [ -n "$missing" ]; then
    echo "SETUP ERROR: these refs are not in the checkout:${missing}" >&2
    echo "  A CI job needs the full history and tags. In GitLab set" >&2
    echo "  GIT_DEPTH: \"0\" and GIT_FETCH_EXTRA_FLAGS: --tags" >&2
    exit 2
fi

for deb in $OSES; do
  img="${IMG[$deb]:-}"
  [ -n "$img" ] || { echo "  ?? unknown Debian $deb"; continue; }
  for row in $FROM_VERSIONS; do
    [ -n "$row" ] || continue
    ref="${row%%:*}"; label="${row##*:}"
    printf "  Debian %-2s  %-4s -> %-5s : " "$deb" "$label" "$TARGET_LABEL"

    out="$(docker run --rm -v "$BARE:/repo.git:ro" -w /tmp \
      -e IOT_CONNECTION_STRING="HostName=fake.azure-devices.net;DeviceId=rpiCI;SharedAccessKey=Y2ktdGVzdA==" \
      "$img" sh -c "
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq python3 python3-venv git >/dev/null 2>&1
git clone -q /repo.git /device 2>/dev/null || { echo CLONEFAIL; exit 1; }
cd /device
git checkout -q ${ref} 2>/tmp/co.err || { echo CHECKOUTFAIL; sed 's/^/    /' /tmp/co.err | head -3; exit 1; }
echo BEFORE_SHA=\$(git rev-parse --short HEAD)
echo BEFORE_VER=\$(sed -n 's/.*\"version\"[^\"]*\"\([0-9.]*\)\".*/\\1/p' /device/version.json | head -1)
echo BEFORE_HAS_FIRSTBOOT=\$([ -f /device/firstboot.sh ] && echo yes || echo no)
python3 -m venv --system-site-packages /venv >/dev/null 2>&1
/venv/bin/pip install -q azure-iot-device python-dotenv requests >/dev/null 2>&1 || { echo PIPFAIL; exit 1; }
mkdir -p /stub/RPi
printf 'BCM=BOARD=OUT=IN=HIGH=LOW=0\ndef setmode(*a,**k): pass\ndef setwarnings(*a,**k): pass\ndef setup(*a,**k): pass\ndef output(*a,**k): pass\ndef input(*a,**k): return 0\ndef cleanup(*a,**k): pass\n' > /stub/RPi/GPIO.py
: > /stub/RPi/__init__.py
printf 'class SpiDev:\n    def open(self,*a,**k): pass\n    def xfer2(self,*a,**k): return []\n    def close(self,*a,**k): pass\n' > /stub/spidev.py
export PYTHONPATH=/stub:/device
# The migration itself: exactly what update_pagalava.sh does.
git fetch -q origin ${TARGET_SHA} 2>/dev/null
git reset --hard -q ${TARGET_SHA} 2>/dev/null || { echo RESETFAIL; exit 1; }
echo AFTER_SHA=\$(git rev-parse --short HEAD)
echo AFTER_HAS_FIRSTBOOT=\$([ -f /device/firstboot.sh ] && echo yes || echo no)
# Does the service start on this OS after migrating?
echo PYVER=\$(/venv/bin/python -c 'import sys;print(sys.version.split()[0])')
echo GOTVER=\$(sed -n 's/.*\"version\"[^\"]*\"\([0-9.]*\)\".*/\\1/p' /device/version.json | head -1)
timeout 45 /venv/bin/python /device/ReceiveMessages.py > /tmp/run.log 2>&1
grep -q 'Instantiating IoT Hub client' /tmp/run.log && echo STARTED
grep -q Traceback /tmp/run.log && { echo TRACEBACK; grep -A4 Traceback /tmp/run.log | tail -3; }
" 2>&1)"

    # Same rule as the OS matrix: reaching client instantiation is the pass
    # condition; a traceback after it is the MQTT connect, which CI cannot
    # satisfy and is not meant to.
    pyv="$(echo "$out"  | grep -oE 'PYVER=[0-9.]+'        | cut -d= -f2 | head -1)"
    bver="$(echo "$out" | grep -oE 'BEFORE_VER=[0-9.]+'   | cut -d= -f2 | head -1)"
    bsha="$(echo "$out" | grep -oE 'BEFORE_SHA=[0-9a-f]+' | cut -d= -f2 | head -1)"
    asha="$(echo "$out" | grep -oE 'AFTER_SHA=[0-9a-f]+'  | cut -d= -f2 | head -1)"
    aver="$(echo "$out" | grep -oE 'GOTVER=[0-9.]+'       | cut -d= -f2 | head -1)"
    bfb="$(echo "$out"  | grep -oE 'BEFORE_HAS_FIRSTBOOT=[a-z]+' | cut -d= -f2 | head -1)"
    afb="$(echo "$out"  | grep -oE 'AFTER_HAS_FIRSTBOOT=[a-z]+'  | cut -d= -f2 | head -1)"
    if echo "$out" | grep -q "STARTED"; then
        echo "ok"
        printf '      before : version.json=%-5s commit=%-8s firstboot.sh=%s\n' "${bver:-?}" "${bsha:-?}" "${bfb:-?}"
        printf '      after  : version.json=%-5s commit=%-8s firstboot.sh=%s\n' "${aver:-?}" "${asha:-?}" "${afb:-?}"
        printf '      ran on : Debian %s, Python %s -- service started and reached the IoT Hub client\n' "$deb" "${pyv:-?}"
        pass=$((pass+1))
    else
        echo "FAIL — never reached client instantiation"
        echo "$out" | tail -3 | sed 's/^/        /'
        fail=$((fail+1))
    fi
  done
done

echo
echo "migrations — passed: ${pass}  failed: ${fail}"
[ "$fail" -eq 0 ]

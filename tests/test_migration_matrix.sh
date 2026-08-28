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
echo "Migrating to $(git rev-parse --short "$TARGET_SHA") on Debian: ${OSES}"
echo

pass=0; fail=0
BARE="$(mktemp -d)/repo.git"
git clone -q --bare . "$BARE"

for deb in $OSES; do
  img="${IMG[$deb]:-}"
  [ -n "$img" ] || { echo "  ?? unknown Debian $deb"; continue; }
  for row in $FROM_VERSIONS; do
    [ -n "$row" ] || continue
    ref="${row%%:*}"; label="${row##*:}"
    printf "  Debian %-2s  %s -> target : " "$deb" "$label"

    out="$(docker run --rm -v "$BARE:/repo.git:ro" -w /tmp \
      -e IOT_CONNECTION_STRING="HostName=fake.azure-devices.net;DeviceId=rpiCI;SharedAccessKey=Y2ktdGVzdA==" \
      "$img" sh -c "
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq python3 python3-venv git >/dev/null 2>&1
git clone -q /repo.git /dev 2>/dev/null
cd /dev
git checkout -q ${ref} 2>/dev/null || { echo 'CHECKOUTFAIL'; exit 1; }
python3 -m venv --system-site-packages /venv >/dev/null 2>&1
/venv/bin/pip install -q azure-iot-device python-dotenv requests >/dev/null 2>&1 || { echo PIPFAIL; exit 1; }
mkdir -p /stub/RPi
printf 'BCM=BOARD=OUT=IN=HIGH=LOW=0\ndef setmode(*a,**k): pass\ndef setwarnings(*a,**k): pass\ndef setup(*a,**k): pass\ndef output(*a,**k): pass\ndef input(*a,**k): return 0\ndef cleanup(*a,**k): pass\n' > /stub/RPi/GPIO.py
: > /stub/RPi/__init__.py
printf 'class SpiDev:\n    def open(self,*a,**k): pass\n    def xfer2(self,*a,**k): return []\n    def close(self,*a,**k): pass\n' > /stub/spidev.py
export PYTHONPATH=/stub:/dev
# The migration itself: exactly what update_pagalava.sh does.
git fetch -q origin ${TARGET_SHA} 2>/dev/null
git reset --hard -q ${TARGET_SHA} 2>/dev/null || { echo RESETFAIL; exit 1; }
# Does the service start on this OS after migrating?
timeout 45 /venv/bin/python /dev/ReceiveMessages.py > /tmp/run.log 2>&1
grep -q 'Instantiating IoT Hub client' /tmp/run.log && echo STARTED
grep -q Traceback /tmp/run.log && { echo TRACEBACK; grep -A4 Traceback /tmp/run.log | tail -3; }
" 2>&1)"

    # Same rule as the OS matrix: reaching client instantiation is the pass
    # condition; a traceback after it is the MQTT connect, which CI cannot
    # satisfy and is not meant to.
    if echo "$out" | grep -q "STARTED"; then
        echo "ok"
        pass=$((pass+1))
    else
        echo "FAIL — never reached client instantiation"
        echo "$out" | tail -3 | sed 's/^/        /'
        fail=$((fail+1))
    fi
  done
done

rm -rf "$(dirname "$BARE")"
echo
echo "migrations — passed: ${pass}  failed: ${fail}"
[ "$fail" -eq 0 ]

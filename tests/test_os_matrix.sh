#!/bin/bash
# Run the firmware against every Debian version we support, on that version's
# own Python, and check the service actually STARTS — not merely that it parses.
#
# WHY THIS EXISTS
# ---------------
# 1.8 shipped with `int | None` in a module the service imports. That is valid
# syntax on Python 3.10+, so it passed every check on a dev machine and on the
# Bookworm golden image. On Debian 11 (Python 3.9) it raises TypeError while
# the annotation is EVALUATED, at import. The files downloaded perfectly and
# then nothing could start: 63 crash-loops, a laundromat offline, and it was
# only fixed quickly because that site happened to be reachable by SSH. Most
# are not.
#
# So the rule is: if a Debian version has a setup script in this repo, the code
# must start on it, and that is proven here rather than assumed.
#
# WHAT "STARTS" MEANS
# -------------------
# The service is run with a syntactically valid but fake connection string. It
# cannot reach Azure from CI, and it is not expected to — the assertion is that
# it gets as far as instantiating the IoT Hub client, with no traceback. That
# covers imports, annotation evaluation, config parsing, logging setup, GPIO
# initialisation and the whole path through main() up to the network.
set -u

cd "$(dirname "$(readlink -f "$0")")/.." || exit 1

# Debian version -> image. Keep in step with the setup_pagalava_iot_*.sh files:
# a supported OS without a row here is an untested OS.
#
# Takes optional version arguments so CI can run one OS per job, which makes a
# failure name the OS instead of making someone read a combined log:
#   ./test_os_matrix.sh          -> all supported versions
#   ./test_os_matrix.sh 11       -> just Debian 11
ALL_MATRIX="
11:debian:bullseye-slim
12:debian:bookworm-slim
13:debian:trixie-slim
"
if [ "$#" -gt 0 ]; then
    MATRIX=""
    for want in "$@"; do
        row="$(echo "$ALL_MATRIX" | grep "^${want}:" || true)"
        if [ -z "$row" ]; then
            echo "  unknown Debian version: ${want}" >&2
            exit 2
        fi
        MATRIX="${MATRIX}
${row}"
    done
else
    MATRIX="$ALL_MATRIX"
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "  skip  docker not available — cannot run the OS matrix"
    exit 0
fi

FAKE_CS="HostName=fake.azure-devices.net;DeviceId=rpiCI;SharedAccessKey=Y2ktdGVzdC1rZXktbm90LXJlYWw="
pass=0; fail=0

for row in $MATRIX; do
    [ -n "$row" ] || continue
    deb="${row%%:*}"; img="${row#*:}"
    echo "=== Debian ${deb} (${img}) ==="

    out="$(docker run --rm -i -v "$PWD:/src:ro" -w /tmp \
        -e IOT_CONNECTION_STRING="$FAKE_CS" "$img" sh -c '
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq python3 python3-pip python3-venv >/dev/null 2>&1
PY=python3
# Trixie and Bookworm refuse system-wide pip installs (PEP 668); a venv with
# system site packages is what the device setup scripts do anyway.
$PY -m venv --system-site-packages /venv >/dev/null 2>&1
/venv/bin/pip install -q azure-iot-device python-dotenv requests >/dev/null 2>&1 || {
    echo "PIPFAIL"; exit 3; }
# Hardware libraries are stubbed: CI has no GPIO. This is about whether the
# code runs on this interpreter, not about the board.
mkdir -p /stub/RPi
printf "BCM=BOARD=OUT=IN=HIGH=LOW=0\ndef setmode(*a,**k): pass\ndef setwarnings(*a,**k): pass\ndef setup(*a,**k): pass\ndef output(*a,**k): pass\ndef input(*a,**k): return 0\ndef cleanup(*a,**k): pass\n" > /stub/RPi/GPIO.py
: > /stub/RPi/__init__.py
printf "class SpiDev:\n    def open(self,*a,**k): pass\n    def xfer2(self,*a,**k): return []\n    def close(self,*a,**k): pass\n" > /stub/spidev.py
cp /src/*.py /tmp/
export PYTHONPATH=/stub:/tmp
echo "PYVER=$(/venv/bin/python -c "import sys;print(sys.version.split()[0])")"
# 1. every module imports
for f in /src/*.py; do
    b=$(basename "$f"); m="${b%.py}"
    /venv/bin/python -c "import $m" >/dev/null 2>/tmp/e || { echo "IMPORTFAIL:$b"; tail -2 /tmp/e; }
done
# 2. the service actually starts. It cannot reach Azure and is not meant to;
#    reaching the client instantiation proves everything before the network.
timeout 45 /venv/bin/python /tmp/ReceiveMessages.py > /tmp/run.log 2>&1
grep -q "Instantiating IoT Hub client" /tmp/run.log && echo "STARTED"
grep -q "Traceback" /tmp/run.log && { echo "TRACEBACK"; grep -A3 Traceback /tmp/run.log | head -6; }
' 2>&1)"

    pv="$(echo "$out" | grep -oE 'PYVER=[0-9.]+' | cut -d= -f2)"
    echo "  python: ${pv:-unknown}"

    if echo "$out" | grep -q "PIPFAIL"; then
        echo "  FAIL  dependencies would not install"; fail=$((fail+1)); continue
    fi
    if echo "$out" | grep -q "IMPORTFAIL"; then
        echo "  FAIL  a module does not import:"
        echo "$out" | grep -A2 IMPORTFAIL | sed 's/^/        /'
        fail=$((fail+1)); continue
    fi
    echo "  ok    every module imports"
    # Reaching client instantiation is the pass condition. A traceback AFTER
    # that is the MQTT connect failing against a fake hostname — expected, since
    # CI has no Azure. Treating any traceback as failure reported a broken
    # Debian 11 when the code was fine, which is the same class of mistake this
    # file exists to catch.
    if echo "$out" | grep -q "STARTED"; then
        echo "  ok    the service starts and reaches the IoT Hub client"
        pass=$((pass+1))
    else
        echo "  FAIL  the service never reached client instantiation"
        echo "$out" | tail -5 | sed 's/^/        /'
        fail=$((fail+1))
    fi
done

echo
echo "OS matrix — passed: ${pass}  failed: ${fail}"
[ "$fail" -eq 0 ]

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

FAKE_CS=offline-fixture
pass=0; fail=0

for row in $MATRIX; do
    [ -n "$row" ] || continue
    deb="${row%%:*}"; img="${row#*:}"
    echo "=== Debian ${deb} (${img}) ==="

    if ! docker image inspect "pagalava-startup-matrix:$deb" >/dev/null 2>&1 &&
       ! bash tests/matrix-image.sh "$deb"; then
        echo "  FAIL  Debian $deb fixture could not be built"
        fail=$((fail+1)); continue
    fi
    if [ "$deb" = 11 ]; then
        if ! docker run --rm --network none -i -v "$PWD:/src:ro" \
            "pagalava-startup-matrix:$deb" bash -s <<'APT_TEST'
set -eu
mkdir -p /tmp/bin /tmp/install-home
export HOME=/tmp/install-home PATH=/tmp/bin:$PATH
printf '%s\n' 'deb http://deb.debian.org/debian bullseye main' \
    'deb [arch=arm64] https://security.debian.org/debian-security bullseye-security main' \
    'deb http://archive.raspberrypi.org/debian/ bullseye main' > /etc/apt/sources.list
cp /etc/apt/sources.list /tmp/original.list
printf '%s\n' 'Types: deb' 'URIs: http://deb.debian.org/debian' \
    'Suites: bullseye-updates' 'Components: main' > /etc/apt/sources.list.d/debian.sources
cat >/tmp/bin/sudo <<'STUB'
#!/bin/bash
set -eu
[[ $1 == apt-get ]]
[[ $3 == Dir::Etc::sourcelist=* ]]
[[ $5 == Dir::Etc::sourceparts=* ]]
grep -Fxq 'deb http://archive.debian.org/debian/ bullseye main' "${3#*=}"
grep -Fxq 'deb [arch=arm64] http://archive.debian.org/debian-security/ bullseye-security main' "${3#*=}"
grep -Fxq 'deb http://archive.raspberrypi.org/debian/ bullseye main' "${3#*=}"
grep -Fxq 'URIs: http://archive.debian.org/debian/' "${5#*=}/debian.sources"
printf '%s\n' "${3#*=}" >/tmp/apt-source-path
[[ $8 == update || $8 == install ]]
printf '%s\n' "$8" >> /tmp/apt-calls
if [[ $8 == update ]]; then
    [[ $9 == --error-on=any ]]
fi
[[ $8 != "$FAIL_STAGE" ]]
STUB
chmod +x /tmp/bin/sudo
for FAIL_STAGE in update install; do
    export FAIL_STAGE
    : >/tmp/apt-calls
    # Exercise the documented sourced invocation and ensure the caller survives.
    bash -c '. /src/setup_pagalava_iot_debian11.sh </dev/null; test "$?" -eq 1' >/tmp/installer-output 2>&1
    ! grep -q 'IOT_CONNECTION_STRING' /tmp/installer-output || exit 1
    [ ! -e "$HOME/pagalava-iot" ]
    [ ! -e "$(cat /tmp/apt-source-path)" ]
    cmp /tmp/original.list /etc/apt/sources.list
    if [ "$FAIL_STAGE" = update ]; then
        [ "$(cat /tmp/apt-calls)" = update ]
    else
        [ "$(xargs </tmp/apt-calls)" = "update install" ]
    fi
done
echo "  ok    Bullseye installer uses the archive and stops on APT failure"
APT_TEST
        then
            echo "  FAIL  Bullseye installer archive/failure handling"
            fail=$((fail+1)); continue
        fi
    fi

    out="$(docker run --rm --network none -i -v "$PWD:/src:ro" -w /tmp \
        -e IOT_CONNECTION_STRING="$FAKE_CS" "pagalava-startup-matrix:$deb" sh -c '
set -u
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
timeout 45 /venv/bin/python /src/tests/startup_probe.py > /tmp/run.log 2>&1
cat /tmp/run.log
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
    # The startup probe exits at the SDK boundary without network calls.
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

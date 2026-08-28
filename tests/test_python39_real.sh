#!/bin/bash
# Import the service under a REAL Python 3.9, the version the fleet runs.
#
# The static check in test_python39_compat.py catches the one pattern that bit
# us (`int | None`). This catches everything: any 3.10+ syntax or library call
# that only fails when actually executed on the old interpreter.
#
# It matters because a device that cannot import is a device that will not
# start, and many laundromats are Debian 11 with no inbound SSH — recovering one
# costs a site visit. That is not hypothetical: it happened.
#
# Skips (exit 0) when docker is unavailable, so it never blocks a run; the
# static check still applies. Run it before releasing anything to the fleet.
set -u
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1

if ! command -v docker >/dev/null 2>&1; then
    echo "  skip  docker not available — cannot test against a real 3.9"
    exit 0
fi

echo "Importing every device module under Python 3.9"
docker run --rm -v "$PWD:/src:ro" -w /tmp \
  -e IOT_CONNECTION_STRING="HostName=x.azure-devices.net;DeviceId=rpiTest;SharedAccessKey=dGVzdA==" \
  python:3.9-slim sh -c '
set -u
pip install -q azure-iot-device python-dotenv requests >/dev/null 2>&1
# Hardware libraries are stubbed: this is about whether the code loads on this
# interpreter, not about GPIO.
mkdir -p /stub/RPi
printf "BCM=BOARD=OUT=IN=HIGH=LOW=0\ndef setmode(*a,**k): pass\ndef setwarnings(*a,**k): pass\ndef setup(*a,**k): pass\ndef output(*a,**k): pass\ndef input(*a,**k): return 0\ndef cleanup(*a,**k): pass\n" > /stub/RPi/GPIO.py
: > /stub/RPi/__init__.py
printf "class SpiDev:\n    def open(self,*a,**k): pass\n    def xfer2(self,*a,**k): return []\n    def close(self,*a,**k): pass\n" > /stub/spidev.py
cp /src/*.py /tmp/
export PYTHONPATH=/stub:/tmp
fail=0
for f in /src/*.py; do
    b=$(basename "$f"); m="${b%.py}"
    if python -c "import $m" >/dev/null 2>/tmp/err; then
        echo "  ok    $b"
    else
        echo "  FAIL  $b"
        tail -3 /tmp/err | sed "s/^/          /"
        fail=1
    fi
done
echo "  ---"
if [ $fail -eq 0 ]; then
    echo "  all modules import on Python $(python -c "import sys;print(sys.version.split()[0])")"
else
    echo "  SOME MODULES DO NOT IMPORT — do not release this to the fleet"
fi
exit $fail
'

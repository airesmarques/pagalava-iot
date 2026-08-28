#!/bin/bash
# Prove update_pagalava.sh rolls back a version that will not import.
#
# The scenario that cost a laundromat its evening: the pull succeeds, and the
# service then cannot start. On a device with no inbound SSH that is a site
# visit, so the upgrade has to undo itself.
set -u
pass=0; fail=0
ok()  { echo "  ok    $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }

REPO_SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A tiny fake upstream and a device clone of it.
UP="$WORK/upstream"; DEV="$WORK/device"
mkdir -p "$UP" && cd "$UP" && git init -q . && git config user.email t@t && git config user.name t
cat > ReceiveMessages.py <<'PY'
import minute_token
def main(): pass
if __name__ == "__main__":
    main()
PY
echo 'def generate_minute_token(device_id, timestamp=None): return "x"' > minute_token.py
cp "$REPO_SRC/update_pagalava.sh" .
git add -A && git commit -qm "good version"
GOOD="$(git rev-parse HEAD)"

git clone -q "$UP" "$DEV"
cd "$DEV"
# Tests 1 and 2 exercise a device that follows main. The script's built-in
# default is the image's release line, because that is the only branch it ships
# on — so a main-following device is stated explicitly here.
echo "main" > .update-channel

echo "=== 1. a healthy upgrade is accepted ==="
cd "$UP" && echo "# harmless change" >> ReceiveMessages.py && git commit -qam "another good version"
GOOD2="$(git rev-parse HEAD)"
cd "$DEV"
if bash update_pagalava.sh >/dev/null 2>&1; then ok "healthy upgrade exits 0"; else bad "healthy upgrade was rejected"; fi
[ "$(git rev-parse HEAD)" = "$GOOD2" ] && ok "device moved to the new version" || bad "device did not move"

echo "=== 2. a version that cannot import is rolled back ==="
cd "$UP"
# A failure that is a failure on EVERY interpreter. The real bug that broke L2
# (`int | None`) cannot be used here: it is valid syntax on modern Python, so
# this test would pass on a dev machine while proving nothing. That version of
# the test did exactly that. The 3.9-specific pattern is covered separately by
# tests/test_python39_compat.py; this test is about the rollback mechanism.
cat > minute_token.py <<'PYEOF'
import a_module_that_does_not_exist_anywhere
def generate_minute_token(device_id, timestamp=None):
    return "x"
PYEOF
git commit -qam "broken on python 3.9"
BROKEN="$(git rev-parse HEAD)"
cd "$DEV"
out="$(bash update_pagalava.sh 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "broken upgrade exits non-zero" || bad "broken upgrade reported success"
echo "$out" | grep -q "UPGRADE ABORTED" && ok "says clearly that it aborted" || bad "no clear abort message"
if [ "$(git rev-parse HEAD)" = "$GOOD2" ]; then
    ok "device rolled back to the version that was running"
elif [ "$(git rev-parse HEAD)" = "$BROKEN" ]; then
    bad "device was LEFT ON THE BROKEN VERSION - this is the site-visit case"
else
    bad "device ended up somewhere unexpected"
fi
python3 -c "import ast,sys; ast.parse(open('minute_token.py').read())" 2>/dev/null \
  && grep -q "timestamp=None" minute_token.py \
  && ok "the working file is back on disk" || bad "file content not restored"

echo "=== 3. a device follows its channel, not whatever main happens to be ==="
# The case that matters for the image: main is OLDER than the device. Pulling it
# would silently downgrade an image-installed device, removing first-boot
# provisioning and this very rollback check.
cd "$UP"
# Test 2 deliberately left a broken module in the upstream. Start this scenario
# from a working state, or the import check rolls back for the right reason and
# the channel behaviour is never actually exercised — which is what happened.
echo 'def generate_minute_token(device_id, timestamp=None): return "x"' > minute_token.py
git commit -qam "restore a working module"
echo "# newer, only on the release line" >> ReceiveMessages.py
git commit -qam "release-line change"
RELEASE_TIP="$(git rev-parse HEAD)"
git branch -q -f release/test HEAD
# Move main BACKWARDS, as we did when holding the fleet at 1.7.
git checkout -q -B main "$GOOD2"
cd "$DEV"
echo "release/test" > .update-channel
CHOUT="$(bash update_pagalava.sh 2>&1)"; CHRC=$?
[ $CHRC -eq 0 ] && ok "channel upgrade exits 0" || { bad "channel upgrade failed"; echo "$CHOUT" | sed "s/^/        /" | head -6; }
if [ "$(git rev-parse HEAD)" = "$RELEASE_TIP" ]; then
    ok "followed its channel to the newer release-line commit"
elif [ "$(git rev-parse HEAD)" = "$GOOD2" ]; then
    bad "DOWNGRADED to main - an image device would lose first-boot and the rollback check"
else
    bad "ended up somewhere unexpected"
fi
rm -f .update-channel

echo ""
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

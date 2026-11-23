#!/bin/bash
# Prove update_pagalava.sh rolls back a version that will not import.
#
# The scenario that cost a laundromat its evening: the pull succeeds, and the
# service then cannot start. On a device with no inbound SSH that is a site
# visit, so the upgrade has to undo itself.
set -u

# Refuse to run without the tools this needs. Without this guard the script
# still printed "ok" for assertions it could not possibly have checked — git was
# missing in CI and several cases reported success anyway. A test that passes
# when it did not run is worse than no test: it is a false assurance.
for tool in git python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "SETUP ERROR: $tool is required but not installed" >&2
        exit 2
    }
done

pass=0; fail=0
ok()  { echo "  ok    $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }

REPO_SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A tiny fake upstream and a device clone of it.
UP="$WORK/upstream"; DEV="$WORK/device"
# -b main is explicit on purpose. `git init` defaults to `master` unless
# init.defaultBranch is configured, so this test passed on a machine that had
# that set and failed in a clean CI container — the test depended on the
# developer's git config without saying so.
mkdir -p "$UP" && cd "$UP" && git init -q -b main . && git config user.email t@t && git config user.name t
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
# Exercise an explicit release channel for the first three cases.
git branch -q -f release/test HEAD
git clone -q "$UP" "$DEV"
cd "$DEV"
echo "release/test" > .update-channel

echo "=== 1. a healthy upgrade is accepted ==="
cd "$UP" && echo "# harmless change" >> ReceiveMessages.py && git commit -qam "another good version" && git branch -q -f release/test HEAD
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
git commit -qam "broken on python 3.9" && git branch -q -f release/test HEAD
BROKEN="$(git rev-parse HEAD)"
cd "$DEV"
out="$(bash update_pagalava.sh 2>&1)"; rc=$?
[ "$rc" -eq 4 ] && ok "broken upgrade exits 4" || bad "broken upgrade reported success"
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

echo "=== 3. a release override selects a separate branch ==="
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
[ $CHRC -eq 0 ] && ok "upgrade exits 0" || { bad "upgrade failed"; echo "$CHOUT" | sed "s/^/        /" | head -6; }

[ "$(git rev-parse HEAD)" = "$RELEASE_TIP" ] \
    && ok "followed release/test" || bad "did not follow release/test"

echo "=== 4. default and explicit main, invalid override, failed fetch ==="
rm .update-channel
OUT="$(bash update_pagalava.sh 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$GOOD2" ] \
    && ok "missing channel defaults to main" || bad "default main failed: $OUT"

echo main > .update-channel
OUT="$(bash update_pagalava.sh 2>&1)"; RC=$?
[ "$RC" -eq 10 ] && [[ $OUT == *"Already up to date"* ]] \
    && ok "explicit main is accepted and current exits 10" || bad "explicit main failed: $OUT"

echo feature/rpi5 > .update-channel
OUT="$(bash update_pagalava.sh 2>&1)"; RC=$?
[ "$RC" -eq 6 ] && [[ $OUT == *"REFUSING TO UPDATE"* ]] \
    && ok "invalid channel exits 6" || bad "invalid channel was not refused: $OUT"

echo release/missing > .update-channel
OUT="$(bash update_pagalava.sh 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && [ "$(git rev-parse HEAD)" = "$GOOD2" ] \
    && [[ $OUT != *"Already up to date"* && $OUT != *"Upgrade OK"* ]] \
    && ok "failed fetch preserves checkout and exits 3" || bad "fetch failure was mishandled: $OUT"

echo ""
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

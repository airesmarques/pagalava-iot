#!/bin/bash
# Prove update_pagalava.sh refuses, loudly, on a device with no git metadata.
#
# Images built in LOCAL_REPO mode are seeded with `tar --exclude=.git`
# (build_image.sh), so a flashed device has no repository at all. Before this
# guard the failure was silent AND total: every git command failed, PREV and NEW
# both became the empty string, `[ "$PREV" = "$NEW" ]` was therefore true, and
# the script printed "Already up to date." and exited 0.
#
# A device that can never take an upgrade reported success to the dashboard
# every time it was asked. 1.9 ships knowingly unupgradable; the requirement is
# only that it SAYS so.
set -u

for tool in git; do
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

# A device as the golden image leaves it: the files, and no .git anywhere.
DEV="$WORK/device"
mkdir -p "$DEV"
cp "$REPO_SRC/update_pagalava.sh" "$DEV/"
cp "$REPO_SRC/ReceiveMessages.py" "$DEV/" 2>/dev/null || true
[ -d "$DEV/.git" ] && bad "the fixture is a git repo; the test would prove nothing"

echo "An image install (no .git)"
OUT="$(cd "$DEV" && ./update_pagalava.sh 2>&1)"
CODE=$?

[ "$CODE" -ne 0 ] \
    && ok "exits non-zero (got $CODE)" \
    || bad "exited 0 — the dashboard would read this as a successful upgrade"

case "$OUT" in
    *"Already up to date"*)
        bad "still claims 'Already up to date' — the exact false success" ;;
    *) ok "does not claim to be up to date" ;;
esac

case "$OUT" in
    *"not a git repository"*) ok "says what is actually wrong" ;;
    *) bad "does not explain the cause" ;;
esac

case "$OUT" in
    *"re-flash"*|*"Re-flash"*) ok "says what to do instead" ;;
    *) bad "does not tell the operator how to change this device's firmware" ;;
esac

# The guard must not break the normal path: a real repo still gets that far.
echo
echo "A git install still proceeds past the guard"
UP="$WORK/upstream"; GIT="$WORK/gitdev"
git init -q -b main "$UP"
( cd "$UP" && echo x > f && git add f \
  && git -c user.email=t@t -c user.name=t commit -qm init )
git clone -q "$UP" "$GIT" 2>/dev/null
cp "$REPO_SRC/update_pagalava.sh" "$GIT/"
OUT2="$(cd "$GIT" && ./update_pagalava.sh 2>&1)"
case "$OUT2" in
    *"not a git repository"*)
        bad "the guard fires on a real repository" ;;
    *) ok "the guard does not fire on a real repository" ;;
esac

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

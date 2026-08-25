#!/bin/bash
#
# Validate that a device running an OLD firmware version survives an upgrade.
#
# Devices update with update_pagalava.sh, which is only:
#
#     git fetch --all; git reset --hard origin/main; git pull origin main
#
# It does NOT pip install, and it does NOT restart the service. So merging to
# main pushes new CODE to every device in the field without installing anything
# the new code might need. A new third-party import is therefore a silent
# breakage: the device keeps running the old process until it reboots, then
# fails on import with nothing in the dashboard to explain it.
#
# This checks the things that upgrade can break, without needing hardware.
# Run it before every version bump:
#
#     tests/check_upgrade_from.sh v1.5        # or a commit sha
#
# Exit non-zero if the upgrade would break a device on that version.

set -u

OLD="${1:?usage: $0 <old-git-ref> [target-ref, default origin/main]}"
# Devices pull origin/main, so that is the realistic target — not a local branch.
NEW="${2:-origin/main}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); echo "  ok    $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
warn() { WARN=$((WARN+1)); echo "  warn  $*"; }

if ! git rev-parse --verify "$OLD" >/dev/null 2>&1; then
    echo "Unknown git ref: $OLD" >&2
    exit 2
fi

echo "=== upgrade check: $(git rev-parse --short "$OLD") -> ${NEW} ($(git rev-parse --short "$NEW")) ==="
echo

# --- 1. dependencies -------------------------------------------------------
# The service must not gain a third-party import the old device lacks.
echo "Dependencies the messaging service needs"

# Files the messaging service actually loads at runtime.
SERVICE_FILES="ReceiveMessages.py relay_ops.py minute_token.py"

old_reqs="$(git show "${OLD}:requirements.txt" 2>/dev/null \
            | sed 's/[<>=].*//' | tr -d ' \r' | grep -vE '^#|^$' | tr 'A-Z' 'a-z' | sort -u)"

# Third-party top-level imports in the service path, as it is now.
# The same import set as it was at the old version, to tell a new dependency
# apart from one that was already there and already undeclared.
old_service_imports="$(for f in $SERVICE_FILES; do
        git show "${OLD}:${f}" 2>/dev/null \
          | grep -hE '^\s*(import|from) [a-zA-Z0-9_.]+' \
          | sed -E 's/^\s*(import|from) ([a-zA-Z0-9_]+).*/\2/'
    done | sort -u)"

new_imports="$(for f in $SERVICE_FILES; do
        git show "${NEW}:${f}" 2>/dev/null \
          | grep -hE '^\s*(import|from) [a-zA-Z0-9_.]+' \
          | sed -E 's/^\s*(import|from) ([a-zA-Z0-9_]+).*/\2/'
    done | sort -u)"

# Anything resolvable locally or from the stdlib is not a dependency.
LOCAL_MODULES="$(git ls-tree --name-only "$NEW" 2>/dev/null | grep '\.py$' | sed 's/\.py$//' | tr '\n' ' ')"
STDLIB="os sys time json re logging subprocess socket hashlib uuid datetime pathlib typing threading signal random math shutil glob argparse base64 io traceback"

for imp in $new_imports; do
    case " $STDLIB " in *" $imp "*) continue;; esac
    case " $LOCAL_MODULES " in *" $imp "*) continue;; esac

    # map import name -> distribution name where they differ
    dist="$imp"
    case "$imp" in
        RPi)     dist="rpi.gpio" ;;
        dotenv)  dist="python-dotenv" ;;
        azure)   dist="azure-iot-device" ;;
        serial)  dist="pyserial" ;;
    esac
    dist="$(printf '%s' "$dist" | tr 'A-Z' 'a-z')"

    if printf '%s\n' "$old_reqs" | grep -qx "$dist"; then
        ok "'$imp' was already installed at $OLD"
    elif printf '%s\n' "$old_service_imports" | grep -qx "$imp"; then
        # Present before and after, and undeclared in both. The device works
        # today (the module arrives transitively or from system site-packages),
        # so an upgrade does not break it. Still worth knowing about.
        warn "'$imp' is undeclared in requirements, but was already imported at $OLD —"
        echo "        pre-existing, resolved transitively. Not an upgrade regression."
    else
        bad "'$imp' is a NEW import and is not in $OLD's requirements."
        echo "        update_pagalava.sh does not pip install, so the service dies on"
        echo "        import the next time it restarts."
    fi
done

# Non-service tools can gain deps; that degrades a tool, not the device.
echo
echo "Dependencies added since $OLD (tools only — not fatal, but the tool breaks)"
added="$(comm -13 <(printf '%s\n' "$old_reqs") \
                  <(git show "${NEW}:requirements.txt" 2>/dev/null | sed 's/[<>=].*//' | tr -d ' \r' \
                    | grep -vE '^#|^$' | tr 'A-Z' 'a-z' | sort -u))"
if [ -z "$added" ]; then
    ok "none"
else
    for a in $added; do
        users="$(grep -ln "$(printf '%s' "$a" | cut -d- -f1)" *.py 2>/dev/null | tr '\n' ' ')"
        warn "'$a' added; used by: ${users:-nothing}. Not installed by an upgrade."
    done
fi

# --- 2. things an upgrade must not disturb ---------------------------------
echo
echo "What the upgrade must leave alone"

# git reset --hard only touches tracked files. A device's identity and config
# must therefore be untracked, or an upgrade would wipe them.
for f in .env config.json; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        bad "$f is TRACKED — 'git reset --hard' would overwrite it on every device"
    else
        ok "$f is untracked, so the upgrade cannot overwrite it"
    fi
done

# --- 3. the new-unit hazard ------------------------------------------------
echo
echo "New systemd units reaching existing devices"
for unit in $(git ls-tree --name-only "$NEW" 2>/dev/null | grep '\.service$'); do
    if git show "${OLD}:${unit}" >/dev/null 2>&1; then
        ok "$unit already existed at $OLD"
    else
        # It lands on every device. Safe only because nothing enables it.
        if git grep -qE "systemctl +enable +.*${unit%.service}" "$NEW" -- '*.sh' 2>/dev/null; then
            bad "$unit is new AND something in a shell script enables it —"
            echo "        it would start running on every device in the field."
        else
            ok "$unit is new but nothing enables it, so it stays inert on old devices"
        fi
    fi
done

# --- 4. the service must still parse ---------------------------------------
echo
echo "New code is syntactically loadable"
for f in $SERVICE_FILES; do
    git show "${NEW}:${f}" >/dev/null 2>&1 || continue
    if git show "${NEW}:${f}" 2>/dev/null | python3 -c "import ast,sys; ast.parse(sys.stdin.read())" 2>/dev/null; then
        ok "$f parses"
    else
        bad "$f does not parse"
    fi
done

echo
echo "==============================================="
echo "passed: $PASS   failed: $FAIL   warnings: $WARN"
echo "==============================================="
[ "$FAIL" -eq 0 ]

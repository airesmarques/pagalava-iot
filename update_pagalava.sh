#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u

# Exit status: 0 updated, 10 already current, 2 no repository, 3 fetch failed,
# 4 rolled back, 5 local error or rollback failed, 6 invalid channel.
# Parse the function before it resets the worktree, including this script.
update() {
    cd "$(dirname "$(readlink -f "$0")")" || exit 5
    local git=/usr/bin/git root prev next channel=main scratch py lock

    if ! root=$("$git" rev-parse --show-toplevel 2>/dev/null) || [[ $root != "$PWD" ]]; then
        echo "CANNOT UPGRADE: $PWD is not a git repository. Re-flash image installs without git metadata." >&2
        exit 2
    fi
    lock=$("$git" rev-parse --git-path pagalava-update.lock) || exit 5
    exec 9>"$lock" || exit 5
    /usr/bin/flock -n 9 || { echo "Another update is in progress." >&2; exit 5; }

    if [[ -e .update-channel ]]; then
        channel=$(tr -d ' 	
' < .update-channel) || exit 5
        channel=${channel:-main}
    fi
    case "$channel" in
        main|release/*) ;;
        *) echo "REFUSING TO UPDATE: invalid channel '$channel'." >&2; exit 6 ;;
    esac
    "$git" check-ref-format "refs/heads/$channel" || {
        echo "REFUSING TO UPDATE: invalid branch name '$channel'." >&2
        exit 6
    }

    prev=$("$git" rev-parse --verify HEAD) || exit 5
    echo "Updating from channel: $channel"
    if ! "$git" fetch --no-tags origin "refs/heads/$channel"; then
        echo "FETCH FAILED: $channel. Checkout is unchanged." >&2
        exit 3
    fi
    next=$("$git" rev-parse --verify 'FETCH_HEAD^{commit}') || exit 5
    if [[ $prev == "$next" ]]; then
        echo "Already up to date at $next."
        exit 10
    fi

    # Prepare all checks before replacing any files. Stub GPIO to avoid
    # touching relays while the previous service is still running.
    scratch=$(mktemp -d) || exit 5
    trap '/bin/rm -rf -- "$scratch"' EXIT
    local STUB="$scratch/stubs"
    mkdir -p "$STUB/RPi" || exit 5
    : > "$STUB/RPi/__init__.py" || exit 5
    /bin/cat > "${STUB}/RPi/GPIO.py" <<'STUBPY' || exit 5
BCM = BOARD = OUT = IN = HIGH = LOW = 0
def setmode(*a, **k): pass
def setwarnings(*a, **k): pass
def setup(*a, **k): pass
def output(*a, **k): pass
def input(*a, **k): return 0
def cleanup(*a, **k): pass
STUBPY
    /bin/cat > "${STUB}/spidev.py" <<'STUBPY' || exit 5
class SpiDev:
    def open(self, *a, **k): pass
    def xfer2(self, *a, **k): return []
    def close(self, *a, **k): pass
STUBPY

    py=.venv/bin/python
    [[ -x $py ]] || py=/usr/bin/python3
    if "$git" reset --hard "$next"; then
        if PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$STUB" /usr/bin/timeout 120 "$py" -c \
            "import ReceiveMessages" \
            >"$scratch/check.log" 2>&1; then
            echo "Upgrade OK: $prev -> $next (service import passed)."
            exit 0
        fi
        echo "UPGRADE ABORTED: $next failed the service import check." >&2
        sed 's/^/    /' "$scratch/check.log" >&2
    else
        echo "UPGRADE ABORTED: could not check out $next." >&2
    fi

    if "$git" reset --hard "$prev"; then
        echo "Rolled back checkout to $prev." >&2
        exit 4
    fi
    echo "ROLLBACK FAILED: could not restore $prev." >&2
    exit 5
}
update

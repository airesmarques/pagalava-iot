#!/bin/bash
# Shared helpers for hardware tests driven through a PiKVM.
#
# Everything is configured by environment variable so this can run unattended
# from a CI runner. No prompts, no interactive input.
#
#   KVM_HOST      PiKVM address                  (default pikvm-l01.local)
#   TARGET_HOST   the Pi under test              (required)
#   TARGET_USER   ssh user on the target         (default pagalava)
#   TARGET_PASS   ssh password for that user     (required unless keys are set up)
#   LAUNDRY_ID    laundry the device belongs to  (default 99)
#   MSD_DIR       image store on the PiKVM       (default /var/lib/kvmd/msd)
#
# Exit codes are meaningful: 0 pass, 1 assertion failed, 2 setup/environment
# problem. A CI job should treat 2 as "infrastructure broken", not "code bad".

set -uo pipefail

KVM_HOST="${KVM_HOST:-pikvm-l01.local}"
TARGET_USER="${TARGET_USER:-pagalava}"
LAUNDRY_ID="${LAUNDRY_ID:-99}"
MSD_DIR="${MSD_DIR:-/var/lib/kvmd/msd}"

PASS=0; FAIL=0; SKIP=0

ok()   { printf '  ok    %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  skip  %s\n' "$*"; SKIP=$((SKIP+1)); }
info() { printf '        %s\n' "$*"; }
die()  { printf 'SETUP ERROR: %s\n' "$*" >&2; exit 2; }

summary() {
    printf '\npassed: %-3s failed: %-3s skipped: %s\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" -eq 0 ] || return 1
}

# --- talking to the PiKVM -----------------------------------------------------
# Root SSH uses the fleet keys, so no password is needed. If that ever changes,
# this is the single place to fix.
kvm() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 "root@${KVM_HOST}" "$@"; }

kvm_require() {
    kvm true >/dev/null 2>&1 || die "cannot reach ${KVM_HOST} as root over ssh"
    kvm 'systemctl is-active kvmd' >/dev/null 2>&1 || die "kvmd is not running on ${KVM_HOST}"
}

# --- talking to the target ----------------------------------------------------
# Uses sshpass when TARGET_PASS is set, plain ssh otherwise (key-based), so the
# same scripts work with either.
tgt() {
    local common=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
    if [ -n "${TARGET_PASS:-}" ]; then
        command -v sshpass >/dev/null 2>&1 || die "TARGET_PASS is set but sshpass is not installed"
        sshpass -p "$TARGET_PASS" ssh "${common[@]}" "${TARGET_USER}@${TARGET_HOST}" "$@"
    else
        ssh -o BatchMode=yes "${common[@]}" "${TARGET_USER}@${TARGET_HOST}" "$@"
    fi
}

# Run something as root on the target. Prefers passwordless sudo; falls back to
# feeding the password. Deliberately does NOT use `sudo bash -c "$cmd"` with the
# password on the same stdin — the password then becomes the script.
tgt_root() {
    local cmd="$1"
    if tgt 'sudo -n true' >/dev/null 2>&1; then
        tgt "sudo -n bash -c $(printf '%q' "$cmd")"
    elif [ -n "${TARGET_PASS:-}" ]; then
        tgt "echo $(printf '%q' "$TARGET_PASS") | sudo -S bash -c $(printf '%q' "$cmd") 2>/dev/null"
    else
        die "no way to obtain root on the target: no passwordless sudo and no TARGET_PASS"
    fi
}

target_up() {
    local tries="${1:-1}"
    for _ in $(seq 1 "$tries"); do
        if timeout 5 bash -c "</dev/tcp/${TARGET_HOST}/22" 2>/dev/null; then return 0; fi
        sleep 10
    done
    return 1
}

require_env() {
    [ -n "${TARGET_HOST:-}" ] || die "TARGET_HOST is not set"
}

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
#   PROV_FILE     provisioning file to read TARGET_PASS from, if it is not set
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

# --- reading a provisioning file ----------------------------------------------
# Values in a provisioning file may be quoted. firstboot.sh strips the quotes
# (firstboot.sh:193) before setting the password, so anything that reads the file
# by hand and forgets to do the same gets a password that is wrong by exactly two
# characters and a "Permission denied" that looks like a broken install. That
# happened during the 1.9 hardware test and cost a verify run reporting 13
# false failures, every one of them just an SSH refusal.
#
# So parse it in exactly one place, the same way firstboot does.
prov_value() {
    # prov_value <file> <KEY>
    local file="$1" key="$2"
    [ -r "$file" ] || die "cannot read provisioning file: $file"
    grep -m1 "^${key}=" "$file" | cut -d= -f2- | tr -d '"' | tr -d '\r\n'
}

prov_password() { prov_value "$1" PAGALAVA_PASSWORD; }

# The device id is embedded in the connection string rather than given directly.
prov_device_id() {
    prov_value "$1" IOT_CONNECTION_STRING | sed -n 's/.*DeviceId=\([^;]*\).*/\1/p'
}

# If the caller pointed at a provisioning file instead of exporting a password,
# derive it. Keeps the documented workflow copy-pasteable.
if [ -z "${TARGET_PASS:-}" ] && [ -n "${PROV_FILE:-}" ]; then
    TARGET_PASS="$(prov_password "$PROV_FILE")"
    export TARGET_PASS
fi

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
    # Deliberately NOT probing with `sudo -n true`. Our own sudoers rule grants
    # `true` passwordlessly, so that probe reports "I have passwordless sudo"
    # on a device where only a handful of specific commands are permitted — and
    # the real command then fails silently. Same mistake the firmware made.
    # Try the actual command; fall back to the password only if it is refused.
    if tgt "sudo -n bash -c $(printf '%q' "$cmd")" 2>/dev/null; then
        return 0
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

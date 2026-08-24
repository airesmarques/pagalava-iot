#!/bin/bash
#
# Tests for firstboot.sh, run on any Linux box — no Pi required.
#
# First boot is the one install step nobody watches happen: if it writes the
# wrong file, or silently does nothing, the installer only finds out when the
# machine fails to activate. So the file handling is exercised here, and only
# the hardware-specific parts are left for the on-device checks.
#
# Each case runs firstboot.sh against a sandbox: a fake boot partition, a fake
# working directory, and a stub systemctl that records what it was asked to do.

set -u

SCRIPT_UNDER_TEST="$(cd "$(dirname "$0")/.." && pwd)/firstboot.sh"
CONN='HostName=IoTHub-dev.azure-devices.net;DeviceId=rpiPagalava129;SharedAccessKey=abc123='
PASSWORD='lavar-vento-porta-mesa-47'

PASS=0
FAIL=0

setup() {
    SANDBOX="$(mktemp -d)"
    BOOTDIR="${SANDBOX}/boot/firmware"
    HOMEDIR="${SANDBOX}/home/pagalava"
    WORKDIR="${HOMEDIR}/pagalava-iot"
    mkdir -p "$BOOTDIR" "$WORKDIR" "${SANDBOX}/bin"

    # Stub systemctl: record calls instead of touching the real init system.
    cat > "${SANDBOX}/bin/systemctl" <<'STUB'
#!/bin/bash
echo "$@" >> "${SYSTEMCTL_LOG}"
STUB
    chmod +x "${SANDBOX}/bin/systemctl"

    # chown would fail as a non-root user; stub it so the script's own error
    # handling is what we test, not our lack of privileges.
    cat > "${SANDBOX}/bin/chown" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "${SANDBOX}/bin/chown"

    # chpasswd needs root; record the call instead so the script's own logic
    # is what gets tested, not our lack of privileges.
    cat > "${SANDBOX}/bin/chpasswd" <<'STUB'
#!/bin/bash
cat >> "${CHPASSWD_LOG}"
STUB
    chmod +x "${SANDBOX}/bin/chpasswd"

    export CHPASSWD_LOG="${SANDBOX}/chpasswd.log"
    : > "$CHPASSWD_LOG"
    export SYSTEMCTL_LOG="${SANDBOX}/systemctl.log"
    : > "$SYSTEMCTL_LOG"
}

teardown() {
    rm -rf "$SANDBOX"
}

# Runs firstboot.sh with its boot candidates and home pointed into the sandbox.
run_firstboot() {
    sed -e "s#^BOOT_CANDIDATES=.*#BOOT_CANDIDATES=(\"${BOOTDIR}\" \"${SANDBOX}/boot\")#" \
        -e "s#^WORKINGDIR=.*#WORKINGDIR=\"${WORKDIR}\"#" \
        "$SCRIPT_UNDER_TEST" > "${SANDBOX}/firstboot.sh"
    chmod +x "${SANDBOX}/firstboot.sh"
    PATH="${SANDBOX}/bin:${PATH}" CHPASSWD_LOG="$CHPASSWD_LOG" \
        bash "${SANDBOX}/firstboot.sh" > "${SANDBOX}/out.log" 2>&1
    echo $?
}

check() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: ${desc}"
        echo "      expected: ${expected}"
        echo "      actual:   ${actual}"
        [ -f "${SANDBOX}/out.log" ] && sed 's/^/      log: /' "${SANDBOX}/out.log"
    fi
}

# ---------------------------------------------------------------------------

test_happy_path() {
    setup
    printf 'IOT_CONNECTION_STRING="%s"\nPAGALAVA_PASSWORD="%s"\n' "$CONN" "$PASSWORD" \
        > "${BOOTDIR}/pagalava-provisioning-laundry-129.txt"

    local rc; rc="$(run_firstboot)"
    check "happy path exits 0" "$rc" "0"
    check "happy path writes .env" \
        "$(cat "${WORKDIR}/.env" 2>/dev/null)" \
        "IOT_CONNECTION_STRING=\"${CONN}\""
    # .env feeds the messaging service's environment. The SSH password has no
    # business being there, and a wholesale copy of the provisioning file --
    # which is what this used to do -- would have put it there.
    check "happy path keeps the password OUT of .env" \
        "$(grep -c 'PAGALAVA_PASSWORD' "${WORKDIR}/.env" 2>/dev/null | head -1)" "0"
    check "happy path removes the file from the card" \
        "$(ls "${BOOTDIR}"/pagalava-provisioning*.txt 2>/dev/null | wc -l)" "0"
    check "happy path enables the service" \
        "$(grep -c '^enable receive_messages.service$' "$SYSTEMCTL_LOG")" "1"
    # --no-block is load-bearing: without it firstboot deadlocks against the
    # very service it is ordered before, and the device hangs at boot. Pin the
    # exact form so it cannot be dropped as noise.
    check "happy path restarts the service without blocking" \
        "$(grep -c '^restart --no-block receive_messages.service$' "$SYSTEMCTL_LOG")" "1"
    check "happy path locks down .env" \
        "$(stat -c '%a' "${WORKDIR}/.env")" "600"
    check "happy path sets the SSH password" \
        "$(cat "$CHPASSWD_LOG")" "pagalava:${PASSWORD}"
    check "happy path enables ssh" \
        "$(grep -c '^enable ssh$' "$SYSTEMCTL_LOG")" "1"
    teardown
}

test_no_password_leaves_ssh_alone() {
    # A device provisioned by an older dashboard, before passwords existed.
    # It must still come up and work; it just has no shell access.
    setup
    printf 'IOT_CONNECTION_STRING="%s"\n' "$CONN" \
        > "${BOOTDIR}/pagalava-provisioning-laundry-129.txt"

    local rc; rc="$(run_firstboot)"
    check "no-password file still provisions" "$rc" "0"
    check "no-password file still writes .env" \
        "$(cat "${WORKDIR}/.env" 2>/dev/null)" \
        "IOT_CONNECTION_STRING=\"${CONN}\""
    check "no-password file sets no password" \
        "$(wc -c < "$CHPASSWD_LOG")" "0"
    check "no-password file does not enable ssh" \
        "$(grep -c '^enable ssh$' "$SYSTEMCTL_LOG")" "0"
    check "no-password file still starts the messaging service" \
        "$(grep -c '^enable receive_messages.service$' "$SYSTEMCTL_LOG")" "1"
    teardown
}

test_no_file_is_a_silent_success() {
    # This is the case that runs on every already-provisioned device that picks
    # the script up through update_pagalava.sh. It must do nothing at all.
    setup
    local rc; rc="$(run_firstboot)"
    check "absent file exits 0" "$rc" "0"
    check "absent file writes no .env" \
        "$([ -f "${WORKDIR}/.env" ] && echo yes || echo no)" "no"
    check "absent file touches no service" \
        "$(wc -l < "$SYSTEMCTL_LOG")" "0"
    check "absent file still says why it did nothing" \
        "$(grep -c 'nothing to do' "${SANDBOX}/out.log")" "1"
    teardown
}

test_existing_env_is_not_clobbered_silently() {
    setup
    printf 'IOT_CONNECTION_STRING="OLD"\n' > "${WORKDIR}/.env"
    printf 'IOT_CONNECTION_STRING="%s"\n' "$CONN" \
        > "${BOOTDIR}/pagalava-provisioning-laundry-129.txt"

    local rc; rc="$(run_firstboot)"
    check "re-provision exits 0" "$rc" "0"
    check "re-provision overwrites .env" \
        "$(cat "${WORKDIR}/.env")" "IOT_CONNECTION_STRING=\"${CONN}\""
    check "re-provision keeps a backup" \
        "$(cat "${WORKDIR}/.env.previous")" 'IOT_CONNECTION_STRING="OLD"'
    check "re-provision warns in the log" \
        "$(grep -c 'will be overwritten' "${SANDBOX}/out.log")" "1"
    teardown
}

test_two_files_refuses_to_guess() {
    setup
    printf 'IOT_CONNECTION_STRING="A"\n' > "${BOOTDIR}/pagalava-provisioning-laundry-1.txt"
    printf 'IOT_CONNECTION_STRING="B"\n' > "${BOOTDIR}/pagalava-provisioning-laundry-2.txt"

    local rc; rc="$(run_firstboot)"
    check "ambiguous input fails loudly" "$rc" "1"
    check "ambiguous input writes no .env" \
        "$([ -f "${WORKDIR}/.env" ] && echo yes || echo no)" "no"
    check "ambiguous input leaves both files in place" \
        "$(ls "${BOOTDIR}"/pagalava-provisioning*.txt | wc -l)" "2"
    # A silent exit 1 leaves the installer with nothing to go on, so assert the
    # explanation actually reaches the journal rather than just the exit code.
    check "ambiguous input explains itself in the log" \
        "$(grep -c 'refusing to guess' "${SANDBOX}/out.log")" "1"
    teardown
}

test_garbage_file_is_rejected() {
    setup
    echo "this is not a provisioning file" \
        > "${BOOTDIR}/pagalava-provisioning-laundry-129.txt"

    local rc; rc="$(run_firstboot)"
    check "garbage file fails" "$rc" "1"
    check "garbage file writes no .env" \
        "$([ -f "${WORKDIR}/.env" ] && echo yes || echo no)" "no"
    # Kept so the installer can look at what they actually copied.
    check "garbage file is left for inspection" \
        "$(ls "${BOOTDIR}"/pagalava-provisioning*.txt | wc -l)" "1"
    check "garbage file explains itself in the log" \
        "$(grep -c 'no IOT_CONNECTION_STRING line' "${SANDBOX}/out.log")" "1"
    teardown
}

test_renamed_file_still_works() {
    # Browsers append " (1)" and installers rename things.
    setup
    printf 'IOT_CONNECTION_STRING="%s"\n' "$CONN" \
        > "${BOOTDIR}/pagalava-provisioning-laundry-129 (1).txt"

    local rc; rc="$(run_firstboot)"
    check "renamed file exits 0" "$rc" "0"
    check "renamed file writes .env" \
        "$(cat "${WORKDIR}/.env" 2>/dev/null)" \
        "IOT_CONNECTION_STRING=\"${CONN}\""
    teardown
}

test_missing_workdir_fails_loudly() {
    setup
    rm -rf "$WORKDIR"
    printf 'IOT_CONNECTION_STRING="%s"\n' "$CONN" \
        > "${BOOTDIR}/pagalava-provisioning-laundry-129.txt"

    local rc; rc="$(run_firstboot)"
    check "missing workdir fails" "$rc" "1"
    check "missing workdir does not enable the service" \
        "$(wc -l < "$SYSTEMCTL_LOG")" "0"
    check "missing workdir explains itself in the log" \
        "$(grep -c 'does not exist' "${SANDBOX}/out.log")" "1"
    teardown
}

test_happy_path
test_no_password_leaves_ssh_alone
test_no_file_is_a_silent_success
test_existing_env_is_not_clobbered_silently
test_two_files_refuses_to_guess
test_garbage_file_is_rejected
test_renamed_file_still_works
test_missing_workdir_fails_loudly

echo ""
echo "passed: ${PASS}  failed: ${FAIL}"
[ "$FAIL" -eq 0 ]

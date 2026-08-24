#!/bin/bash
#
# Integration test for first-boot provisioning, run INSIDE a throwaway Debian 12
# VM as root. Debian 12 is Raspberry Pi OS Bookworm's base.
#
# tests/test_firstboot.sh already covers the file handling. What it cannot cover
# is systemd itself, and that is where the backward-compatibility guarantee
# lives: firstboot.sh reaches every deployed device through update_pagalava.sh's
# hard reset, and the only thing stopping it running there is that its unit is
# never enabled. "An un-enabled unit is inert" has to be demonstrated, not
# assumed, because getting it wrong reconfigures machines in the field.
#
# Usage (as root, in a disposable VM):  bash vm_integration_firstboot.sh /path/to/repo

set -u

REPO="${1:?usage: $0 <path-to-firmware-repo>}"
WORKINGDIR="/home/pagalava/pagalava-iot"
BOOTDIR="/boot/firmware"
CONN_A='HostName=IoTHub-dev.azure-devices.net;DeviceId=rpiPagalava129;SharedAccessKey=AAAA=='
PASSWORD='lavar-vento-porta-mesa-47'
CONN_B='HostName=IoTHub-dev.azure-devices.net;DeviceId=rpiPagalava777;SharedAccessKey=BBBB=='

PASS=0; FAIL=0
check() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1)); echo "  ok   ${desc}"
    else
        FAIL=$((FAIL+1)); echo "  FAIL ${desc}"
        echo "         expected: ${expected}"
        echo "         actual:   ${actual}"
    fi
}

banner() { echo ""; echo "=== $* ==="; }

# --- a stand-in for ReceiveMessages.py -------------------------------------
# The real script exits 1 when IOT_CONNECTION_STRING is missing; this mimics
# that, because "does a device without a credential crash-loop?" is one of the
# things under test.
install_fake_app() {
    mkdir -p "$WORKINGDIR"
    cat > "${WORKINGDIR}/ReceiveMessages.py" <<'APP'
import os, sys, time
conn = os.environ.get("IOT_CONNECTION_STRING")
if not conn:
    # Mirrors the real script: no credential, no point running.
    sys.exit(1)
with open("/tmp/pagalava-device-identity", "w") as fh:
    fh.write(conn)
while True:
    time.sleep(3600)
APP
    id -u pagalava >/dev/null 2>&1 || useradd -m -s /bin/bash pagalava
    chown -R pagalava:pagalava /home/pagalava
}

# A legacy unit: credential baked into Environment=, exactly as the setup
# scripts have always written it.
install_legacy_unit() {
    local conn="$1"
    cat > /etc/systemd/system/receive_messages.service <<UNIT
[Unit]
Description=Receive Messages Service
After=network-online.target

[Service]
User=pagalava
Group=pagalava
WorkingDirectory=${WORKINGDIR}
Environment="IOT_CONNECTION_STRING=${conn}"
ExecStart=/usr/bin/python3 ${WORKINGDIR}/ReceiveMessages.py
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

# An image unit: no credential at all, .env is the only source.
install_image_unit() {
    cat > /etc/systemd/system/receive_messages.service <<UNIT
[Unit]
Description=Receive Messages Service
After=network-online.target

[Service]
User=pagalava
Group=pagalava
WorkingDirectory=${WORKINGDIR}
EnvironmentFile=${WORKINGDIR}/.env
ExecStart=/usr/bin/python3 ${WORKINGDIR}/ReceiveMessages.py
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

# What update_pagalava.sh effectively does: drop the repo's files onto the
# device. Note it does NOT enable anything.
simulate_git_upgrade() {
    install -m 755 "${REPO}/firstboot.sh" "${WORKINGDIR}/firstboot.sh"
    install -m 644 "${REPO}/pagalava-firstboot.service" \
        /etc/systemd/system/pagalava-firstboot.service
    systemctl daemon-reload
}

reset_world() {
    systemctl stop receive_messages.service pagalava-firstboot.service 2>/dev/null
    systemctl disable receive_messages.service pagalava-firstboot.service 2>/dev/null
    rm -f /etc/systemd/system/receive_messages.service \
          /etc/systemd/system/pagalava-firstboot.service \
          /tmp/pagalava-device-identity
    rm -rf "$WORKINGDIR"
    mkdir -p "$BOOTDIR"
    rm -f "${BOOTDIR}"/pagalava-provisioning*.txt
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null
    install_fake_app
}

# ---------------------------------------------------------------------------
# 1. A legacy device picks up the new files through update_pagalava.sh.
#    Nothing about it may change.
# ---------------------------------------------------------------------------
test_legacy_device_survives_upgrade() {
    banner "legacy device survives the upgrade"
    reset_world
    printf 'IOT_CONNECTION_STRING="%s"\n' "$CONN_A" > "${WORKINGDIR}/.env"
    chmod 600 "${WORKINGDIR}/.env"; chown pagalava:pagalava "${WORKINGDIR}/.env"
    install_legacy_unit "$CONN_A"
    systemctl enable --now receive_messages.service
    sleep 3

    check "legacy service is running before the upgrade" \
        "$(systemctl is-active receive_messages.service)" "active"

    simulate_git_upgrade

    check "firstboot unit is installed" \
        "$([ -f /etc/systemd/system/pagalava-firstboot.service ] && echo yes || echo no)" "yes"
    # The linchpin of the whole backward-compatibility argument.
    check "firstboot unit is NOT enabled" \
        "$(systemctl is-enabled pagalava-firstboot.service 2>&1)" "disabled"
    check "legacy unit keeps its Environment= credential" \
        "$(grep -c 'Environment="IOT_CONNECTION_STRING=' /etc/systemd/system/receive_messages.service)" "1"
    check "legacy service still running after the upgrade" \
        "$(systemctl is-active receive_messages.service)" "active"

    # And it must still be untouched after a reboot's worth of unit activation.
    systemctl restart receive_messages.service; sleep 3
    check "legacy service restarts cleanly" \
        "$(systemctl is-active receive_messages.service)" "active"
    check "legacy device kept its own identity" \
        "$(cat /tmp/pagalava-device-identity 2>/dev/null)" "$CONN_A"
    check "firstboot never ran on the legacy device" \
        "$(systemctl is-active pagalava-firstboot.service 2>&1)" "inactive"
}

# ---------------------------------------------------------------------------
# 2. A golden image booting with a provisioning file.
# ---------------------------------------------------------------------------
test_ssh_password_is_actually_usable() {
    # The unit tests stub chpasswd, so they prove the script CALLS it, not that
    # the account ends up usable. This is the difference between "we ran the
    # command" and "the installer can log in", which is the whole point.
    banner "the SSH password actually works"
    reset_world
    install_image_unit
    simulate_git_upgrade
    systemctl enable pagalava-firstboot.service >/dev/null 2>&1

    printf 'IOT_CONNECTION_STRING="%s"\nPAGALAVA_PASSWORD="%s"\n' "$CONN_A" "$PASSWORD" \
        > "${BOOTDIR}/pagalava-provisioning-laundry-129.txt"
    systemctl start pagalava-firstboot.service
    sleep 4

    check "firstboot succeeded" \
        "$(systemctl show -p Result --value pagalava-firstboot.service)" "success"

    # The account must be unlocked and carry a real hash. A locked account
    # shows '!' or '*' in place of one, which is what useradd leaves behind.
    local hash
    hash="$(getent shadow pagalava | cut -d: -f2)"
    check "account is no longer locked" \
        "$(case "$hash" in ""|"!"*|"*"*) echo locked;; *) echo unlocked;; esac)" "unlocked"

    # Verify the stored hash genuinely matches the password we supplied,
    # rather than trusting that chpasswd was handed the right string.
    check "the stored hash matches the supplied password" \
        "$(python3 -c "
import crypt, sys
h = sys.argv[1]
print('match' if crypt.crypt(sys.argv[2], h) == h else 'MISMATCH')
" "$hash" "$PASSWORD" 2>/dev/null || echo 'could-not-check')" "match"

    check "ssh is enabled" \
        "$(systemctl is-enabled ssh 2>&1)" "enabled"

    # .env feeds the messaging service. The password has no business there.
    check "the password is NOT in .env" \
        "$(grep -c 'PAGALAVA_PASSWORD' ${WORKINGDIR}/.env 2>/dev/null | head -1)" "0"
    check ".env still has the connection string" \
        "$(cat ${WORKINGDIR}/.env 2>/dev/null)" "IOT_CONNECTION_STRING=\"${CONN_A}\""
    # configurar.py manages environments by globbing .env.<suffix> and
    # repointing the .env symlink. A zero-touch device must end up in that
    # shape, or it is unmanageable in exactly the way the bootstrap-migration
    # doc describes for legacy devices.
    check "device is manageable by configurar.py" \
        "$(readlink ${WORKINGDIR}/.env)" ".env.dev"
    check "the environment file exists with the right mode" \
        "$(stat -Lc '%a' ${WORKINGDIR}/.env)" "600"

    # And the credential must be gone from the card.
    check "provisioning file removed from the boot partition" \
        "$(ls ${BOOTDIR}/pagalava-provisioning*.txt 2>/dev/null | wc -l)" "0"
}

test_fresh_image_provisions_itself() {
    banner "fresh image provisions itself from the boot partition"
    reset_world
    install_image_unit
    simulate_git_upgrade
    systemctl enable pagalava-firstboot.service
    # Ships disabled in the image; first boot is what turns it on.
    systemctl disable receive_messages.service 2>/dev/null

    printf 'IOT_CONNECTION_STRING="%s"\n' "$CONN_A" \
        > "${BOOTDIR}/pagalava-provisioning-laundry-129.txt"

    systemctl start pagalava-firstboot.service
    sleep 4

    check "firstboot succeeded" \
        "$(systemctl show -p Result --value pagalava-firstboot.service)" "success"
    check ".env was written" \
        "$(cat ${WORKINGDIR}/.env 2>/dev/null)" "IOT_CONNECTION_STRING=\"${CONN_A}\""
    # -L follows the symlink: .env points at .env.<environment>, and a
    # symlink's own mode is always 777.
    check ".env is mode 600" "$(stat -Lc '%a' ${WORKINGDIR}/.env)" "600"
    check ".env is owned by pagalava" "$(stat -c '%U' ${WORKINGDIR}/.env)" "pagalava"
    check "provisioning file was removed from the card" \
        "$(ls ${BOOTDIR}/pagalava-provisioning*.txt 2>/dev/null | wc -l)" "0"
    check "messaging service is now enabled" \
        "$(systemctl is-enabled receive_messages.service)" "enabled"

    sleep 3
    check "messaging service is running" \
        "$(systemctl is-active receive_messages.service)" "active"
    check "device took the provisioned identity" \
        "$(cat /tmp/pagalava-device-identity 2>/dev/null)" "$CONN_A"
    check "image unit carries no baked credential" \
        "$(grep -c 'Environment="IOT_CONNECTION_STRING=' /etc/systemd/system/receive_messages.service)" "0"
}

# ---------------------------------------------------------------------------
# 3. A golden image booting with NO provisioning file must sit idle, not
#    crash-loop. This is what a customer sees if they flash a card and forget
#    the file.
# ---------------------------------------------------------------------------
test_fresh_image_without_file_sits_idle() {
    banner "fresh image without a provisioning file sits idle"
    reset_world
    install_image_unit
    simulate_git_upgrade
    systemctl enable pagalava-firstboot.service
    systemctl disable receive_messages.service 2>/dev/null

    systemctl start pagalava-firstboot.service
    sleep 4

    check "firstboot exits successfully with nothing to do" \
        "$(systemctl show -p Result --value pagalava-firstboot.service)" "success"
    check "no .env was invented" \
        "$([ -f ${WORKINGDIR}/.env ] && echo yes || echo no)" "no"
    check "messaging service stays disabled" \
        "$(systemctl is-enabled receive_messages.service 2>&1)" "disabled"
    check "messaging service is not running" \
        "$(systemctl is-active receive_messages.service 2>&1)" "inactive"
    check "nothing is in a failed state" \
        "$(systemctl is-failed receive_messages.service 2>&1)" "inactive"
}

# ---------------------------------------------------------------------------
# 4. Ordering: firstboot must win the race against the messaging service on
#    every boot, not only the first.
# ---------------------------------------------------------------------------
test_ordering_is_declared() {
    banner "unit ordering"
    reset_world
    install_image_unit
    simulate_git_upgrade
    check "firstboot is ordered before the messaging service" \
        "$(systemctl show -p Before --value pagalava-firstboot.service | grep -c receive_messages.service)" "1"
    check "firstboot is a oneshot" \
        "$(systemctl show -p Type --value pagalava-firstboot.service)" "oneshot"
}

# ---------------------------------------------------------------------------
# 5. Re-provisioning an already-configured device moves it to another laundry.
# ---------------------------------------------------------------------------
test_reprovision_switches_laundry() {
    banner "re-provisioning switches the device to another laundry"
    reset_world
    install_image_unit
    simulate_git_upgrade
    systemctl enable pagalava-firstboot.service

    printf 'IOT_CONNECTION_STRING="%s"\n' "$CONN_A" \
        > "${BOOTDIR}/pagalava-provisioning-laundry-129.txt"
    systemctl start pagalava-firstboot.service; sleep 4
    check "first provisioning took" \
        "$(cat /tmp/pagalava-device-identity 2>/dev/null)" "$CONN_A"

    printf 'IOT_CONNECTION_STRING="%s"\n' "$CONN_B" \
        > "${BOOTDIR}/pagalava-provisioning-laundry-777.txt"
    systemctl restart pagalava-firstboot.service; sleep 4

    check "second provisioning replaced .env" \
        "$(cat ${WORKINGDIR}/.env 2>/dev/null)" "IOT_CONNECTION_STRING=\"${CONN_B}\""
    check "previous .env was kept as a backup" \
        "$(cat ${WORKINGDIR}/.env.bak 2>/dev/null)" "IOT_CONNECTION_STRING=\"${CONN_A}\""
    # .env.previous would show up in configurar.py as a selectable environment
    # still holding laundry 129's credential; switching to it would make this
    # device impersonate that laundry.
    check "the backup is not offered as a selectable environment" \
        "$([ -e ${WORKINGDIR}/.env.previous ] && echo leaked || echo no)" "no"
    check "device now reports the new identity" \
        "$(cat /tmp/pagalava-device-identity 2>/dev/null)" "$CONN_B"
}

test_legacy_device_survives_upgrade
test_ssh_password_is_actually_usable
test_fresh_image_provisions_itself
test_fresh_image_without_file_sits_idle
test_ordering_is_declared
test_reprovision_switches_laundry

echo ""
echo "==============================="
echo "passed: ${PASS}  failed: ${FAIL}"
echo "==============================="
[ "$FAIL" -eq 0 ]

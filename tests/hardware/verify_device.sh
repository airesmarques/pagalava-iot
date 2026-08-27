#!/bin/bash
# Assert that a provisioned device is correct. Safe to run against either install
# path; checks that only apply to one are skipped rather than failed.
#
#   TARGET_HOST=rpiPagalava99.local TARGET_PASS=... ./verify_device.sh [flashed|manual]
#
# Exit 0 all good, 1 an assertion failed, 2 could not run the checks at all.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"
require_env
MODE="${1:-auto}"

target_up 1 || die "cannot reach ${TARGET_HOST}:22"
echo "Verifying ${TARGET_HOST} (${MODE})"

REPO="/home/${TARGET_USER}/pagalava-iot"

echo
echo "Identity"
HN="$(tgt 'hostname' 2>/dev/null | tr -d '\r')"
DEV="$(tgt "grep -o 'DeviceId=[^;]*' ${REPO}/.env 2>/dev/null | cut -d= -f2" | tr -d '\r')"
if [ "$MODE" = "flashed" ]; then
    # First boot renames the device after its IoT identity, so one name
    # correlates the dashboard, the hub and the network.
    [ -n "$DEV" ] && [ "$HN" = "$DEV" ] \
        && ok "hostname matches the IoT device id ($HN)" \
        || bad "hostname '$HN' does not match device id '$DEV'"
else
    skip "hostname is not renamed by a manual install (is '$HN')"
fi
[ -n "$DEV" ] && ok "device identity present ($DEV)" || bad "no DeviceId in .env"

echo
echo "Credentials"
# The SSH password must never reach the service environment.
CNT="$(tgt "grep -c PAGALAVA_PASSWORD ${REPO}/.env 2>/dev/null" | tr -d '\r')"
[ "${CNT:-1}" = "0" ] && ok ".env does not contain the SSH password" \
                      || bad ".env contains PAGALAVA_PASSWORD — it would leak into the service environment"
MODE_ENV="$(tgt "stat -Lc %a ${REPO}/.env 2>/dev/null" | tr -d '\r')"
[ "$MODE_ENV" = "600" ] && ok ".env is mode 600" || bad ".env is mode ${MODE_ENV:-missing}, expected 600"

if [ "$MODE" = "flashed" ]; then
    LEFT="$(tgt 'ls /boot/firmware/pagalava-provisioning*.txt 2>/dev/null | wc -l' | tr -d '\r')"
    [ "${LEFT:-1}" = "0" ] && ok "provisioning file deleted from the boot partition" \
                           || bad "provisioning file still on the card — the credential persists on every clone of it"
    # configurar.py treats each .env.<name> as a selectable environment, so the
    # symlink shape matters: a stray copy would appear as another environment
    # holding another laundry's credential.
    tgt "test -L ${REPO}/.env" >/dev/null 2>&1 \
        && ok ".env is a symlink to an environment file (configurar.py can manage it)" \
        || bad ".env is not a symlink — configurar.py cannot switch environments"
else
    skip "a manual install does not delete the provisioning file (known gap)"
fi

echo
echo "Privileges the service actually needs"
# A service has no tty, so every one of these must be passwordless or the
# corresponding dashboard action fails silently.
# Read the NOPASSWD grants directly. `sudo -n -l <cmd>` is NOT usable here: it
# answers "is this authorised", and our users are in the sudo group, so it says
# yes for everything — including commands that would demand a password the
# service cannot supply.
NOPASS="$(tgt 'sudo -n -l 2>/dev/null' | tr -d '\r' | grep -i 'NOPASSWD:' || true)"
for c in "/usr/bin/systemctl restart receive_messages.service" "/sbin/reboot"; do
    case "$NOPASS" in
        *"$c"*) ok "permitted without a password: ${c}" ;;
        *)      bad "NOT permitted without a password: ${c} — the matching dashboard action will fail silently" ;;
    esac
done
# Narrowness is only meaningful on the flashed path, where the image controls
# sudoers completely. A manual install inherits `NOPASSWD: ALL` from Raspberry
# Pi OS's own 010_pi-nopasswd, created for the first user by userconf-pi — so
# bash and rm genuinely are permitted there, and that is Pi OS's decision, not
# ours. Asserting otherwise would fail every manual install for no reason.
if [ "$MODE" = "flashed" ]; then
    for c in "/bin/bash" "/bin/rm"; do
        case "$NOPASS" in
            *"$c"*) bad "sudo is broader than it should be: ${c} is passwordless" ;;
            *)      ok "not passwordless: ${c}" ;;
        esac
    done
else
    skip "sudo narrowness (a manual install inherits NOPASSWD:ALL from Pi OS)"
fi

echo
echo "Service"
ACT="$(tgt 'systemctl is-active receive_messages.service' 2>/dev/null | tr -d '\r')"
[ "$ACT" = "active" ] && ok "receive_messages is active" || bad "receive_messages is ${ACT:-unknown}"
VER="$(tgt "python3 -c \"import json;print(json.load(open('${REPO}/version.json'))['version'])\"" 2>/dev/null | tr -d '\r')"
[ -n "$VER" ] && ok "reports version ${VER}" || bad "could not read version.json"
# The device asks the cloud for its config on boot and the reply is asynchronous,
# so a check run immediately after boot can lose the race. Wait rather than
# reporting a failure that fixes itself seconds later.
CONF=1
for _ in $(seq 1 12); do
    if tgt "test -f ${REPO}/config.json" >/dev/null 2>&1; then CONF=0; break; fi
    sleep 5
done
[ "$CONF" = "0" ] && ok "config.json present (the device fetched its relay map)" \
                  || bad "no config.json after 60s — the device never received its configuration"

echo
echo "Connectivity"
if tgt_root "journalctl -u receive_messages.service --no-pager -n 60" 2>/dev/null | grep -q "Connected successfully"; then
    ok "connected to IoT Hub"
else
    bad "no successful IoT Hub connection in the journal"
fi

echo
echo "Diagnosability"
tgt "test -d /var/log/journal" >/dev/null 2>&1 \
    && ok "journal is persistent (first-boot logs survive a reboot)" \
    || bad "journal is volatile — the log explaining a failed install is lost on reboot"

summary

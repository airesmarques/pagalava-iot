#!/bin/bash
#
# PagaLava first-boot provisioning.
#
# Reads a provisioning file dropped on the SD card's boot partition, installs it
# as the device's .env, removes it from the card, and enables the messaging
# service. This replaces the legacy procedure of SSHing into a fresh Pi and
# pasting the IoT connection string at a prompt.
#
# Run by pagalava-firstboot.service, ordered before receive_messages.service.
#
# BACKWARD COMPATIBILITY: this file lands on every deployed device via
# update_pagalava.sh (git reset --hard). It must therefore be harmless on a
# device that was installed the old way. It is, for two reasons: the systemd
# unit ships un-enabled so nothing invokes this, and if something does, the
# absence of a provisioning file makes it exit 0 without touching anything.

set -u

# Where the messaging service lives. The image build creates this user; the
# override exists so the same script works on an image built with another name.
PAGALAVA_USER="${PAGALAVA_USER:-pagalava}"
WORKINGDIR="/home/${PAGALAVA_USER}/pagalava-iot"
ENVFILE="${WORKINGDIR}/.env"
SERVICENAME="receive_messages.service"

# Bookworm mounts the FAT boot partition at /boot/firmware; older releases at
# /boot. On Bookworm /boot still exists as the root filesystem's directory, so
# probe /boot/firmware first or we would write to the wrong place.
BOOT_CANDIDATES=("/boot/firmware" "/boot")

log() {
    # stderr, not stdout: find_provisioning_file returns its result through
    # stdout via command substitution, which would otherwise swallow every
    # message it logs — silently, exactly when something has gone wrong.
    # systemd journals stderr just the same.
    echo "pagalava-firstboot: $*" >&2
}

find_provisioning_file() {
    # Prints the path of the single provisioning file, or nothing.
    local dir
    local -a found=()

    for dir in "${BOOT_CANDIDATES[@]}"; do
        [ -d "$dir" ] || continue
        local f
        # Installers rename downloads, so match the family rather than one name.
        for f in "$dir"/pagalava-provisioning*.txt; do
            [ -f "$f" ] && found+=("$f")
        done
        # Stop at the first partition that has any, so a stale copy under /boot
        # on a Bookworm system cannot shadow the real one.
        [ ${#found[@]} -gt 0 ] && break
    done

    if [ ${#found[@]} -eq 0 ]; then
        return 1
    fi

    if [ ${#found[@]} -gt 1 ]; then
        # Two files means two candidate laundries. Guessing would silently
        # provision the device as the wrong one, which is worse than stopping.
        log "ERROR: ${#found[@]} provisioning files found: ${found[*]}"
        log "ERROR: refusing to guess. Leave exactly one and reboot."
        return 2
    fi

    printf '%s\n' "${found[0]}"
    return 0
}

main() {
    local provfile
    provfile="$(find_provisioning_file)"
    local rc=$?

    if [ $rc -eq 1 ]; then
        log "no provisioning file on the boot partition, nothing to do"
        exit 0
    fi

    if [ $rc -ne 0 ]; then
        # Error already logged. Exit non-zero so the failure is visible in
        # systemctl status rather than looking like a clean run.
        exit 1
    fi

    log "found provisioning file: ${provfile}"

    if [ ! -d "$WORKINGDIR" ]; then
        log "ERROR: ${WORKINGDIR} does not exist. Is this a PagaLava image?"
        exit 1
    fi

    if ! grep -q '^IOT_CONNECTION_STRING=' "$provfile"; then
        log "ERROR: ${provfile} has no IOT_CONNECTION_STRING line, ignoring it"
        log "ERROR: the file is left in place so it can be inspected"
        exit 1
    fi

    if [ -e "$ENVFILE" ] || [ -L "$ENVFILE" ]; then
        # Re-provisioning: dropping a new file on an already-configured device
        # moves it to another laundry. That is the useful behaviour, but it is
        # worth a loud log line because it changes the device's identity.
        #
        # The backup MUST be .env.bak. configurar.py ignores exactly
        # {bak,tmp,sample,example}; anything else — .env.previous, say —
        # becomes a SELECTABLE environment still holding the previous
        # laundry's connection string, and switching to it would make this
        # device impersonate that laundry.
        log "WARNING: ${ENVFILE} already exists and will be repointed"
        cp -pL "$ENVFILE" "${WORKINGDIR}/.env.bak" 2>/dev/null || true
    fi

    # Extract ONLY the connection string. The provisioning file is a transport
    # format, not an env file: it also carries the SSH password, and .env is
    # loaded into the messaging service's environment (load_dotenv), where a
    # password has no business being.
    conn_line="$(grep -m1 '^IOT_CONNECTION_STRING=' "$provfile")"

    # Write it as .env.<environment> with .env symlinked to it, which is the
    # shape configurar.py manages: it lists selectable environments by globbing
    # .env.<suffix> and switches by repointing the .env symlink. A plain .env
    # with no siblings leaves the device with nothing to switch between —
    # exactly the limitation docs/configurar-bootstrap-migration.md describes
    # for legacy devices, which this flow should not be recreating.
    #
    # The name matches determine_environment() in ReceiveMessages.py, which
    # keys on "IoTHub-dev" in the hostname.
    case "$conn_line" in
        *IoTHub-dev*) env_name="dev" ;;
        *)            env_name="prod" ;;
    esac
    env_target="${WORKINGDIR}/.env.${env_name}"

    if ! printf '%s\n' "$conn_line" > "$env_target"; then
        log "ERROR: could not write ${env_target}"
        exit 1
    fi
    chown "${PAGALAVA_USER}:${PAGALAVA_USER}" "$env_target" || true
    chmod 600 "$env_target"

    # Relative target, so the symlink survives the directory being moved.
    ln -sfn ".env.${env_name}" "$ENVFILE"
    chown -h "${PAGALAVA_USER}:${PAGALAVA_USER}" "$ENVFILE" 2>/dev/null || true
    log "wrote ${env_target} (mode 600) and pointed .env at it"

    # Give the device a stable name derived from its laundry, so it can be
    # reached as e.g. pagalava-99.local regardless of what DHCP hands out.
    # Without this every device is "raspberrypi": the address in the dashboard
    # goes stale whenever the lease changes, and two devices on the same bench
    # collide on mDNS. avahi-daemon is enabled in the image, so the .local name
    # works with no further setup.
    # The hostname IS the IoT device id, so a device called rpiPagalava99 in
    # the dashboard answers to rpiPagalava99.local on the network. One name to
    # correlate, rather than two conventions to remember. mDNS is
    # case-insensitive, so the capital P costs nothing.
    device_id="$(printf '%s' "$conn_line" | sed -n 's/.*DeviceId=\([^;"]*\).*/\1/p')"
    # Only accept a name that is valid as a hostname: letters, digits, hyphens.
    valid_host="$(printf '%s' "$device_id" | sed -n 's/^\([A-Za-z0-9-]\{1,63\}\)$/\1/p')"
    if [ -n "$valid_host" ]; then
        new_host="$valid_host"
        if command -v hostnamectl >/dev/null 2>&1; then
            hostnamectl set-hostname "$new_host" 2>/dev/null || true
        else
            printf '%s\n' "$new_host" > /etc/hostname 2>/dev/null || true
        fi
        # 127.0.1.1 must track the hostname or sudo warns and name lookups stall.
        if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${new_host}/" /etc/hosts
        else
            printf '127.0.1.1\t%s\n' "$new_host" >> /etc/hosts
        fi
        log "hostname set to ${new_host} (reachable as ${new_host}.local)"
    else
        log "device id '${device_id}' is not a valid hostname, leaving the hostname alone"
    fi

    # Set the device's SSH password, if the dashboard supplied one.
    #
    # The image is a public download, so it can ship no credential of its own:
    # every device gets a unique password delivered here instead. Without this
    # the pagalava account stays locked and nobody can run test.sh to check the
    # relay wiring, which is a required install step.
    #
    # A file with no password is left exactly as it is — a device provisioned
    # by an older dashboard must not silently gain or lose access.
    password="$(grep -m1 '^PAGALAVA_PASSWORD=' "$provfile" | cut -d= -f2- | tr -d '"')"
    if [ -n "$password" ]; then
        if printf '%s:%s\n' "$PAGALAVA_USER" "$password" | chpasswd; then
            log "set the SSH password for ${PAGALAVA_USER}"
            # ssh is present but not enabled in the image, so that a device
            # provisioned without a password has no listening port at all.
            systemctl enable ssh >/dev/null 2>&1 || true
            systemctl start --no-block ssh >/dev/null 2>&1 || true
            log "enabled ssh"
        else
            # Not fatal: the device should still come up and activate machines
            # even if it ends up unreachable by shell.
            log "WARNING: could not set the password for ${PAGALAVA_USER}"
        fi
    else
        log "no PAGALAVA_PASSWORD in the provisioning file, leaving SSH untouched"
    fi
    unset password

    # Remove the credential from the card. Note this is an ordinary unlink on a
    # FAT partition: it unlinks, it does not wipe. A card that was imaged before
    # first boot still holds the string.
    if rm -f "$provfile"; then
        log "removed ${provfile} from the boot partition"
    else
        log "WARNING: could not remove ${provfile}; the credential remains on the card"
    fi

    log "enabling ${SERVICENAME}"
    systemctl enable "$SERVICENAME"

    # --no-block is REQUIRED, not an optimisation. This script runs as a unit
    # ordered Before=receive_messages.service, so a blocking restart deadlocks:
    # systemctl waits for the service to start, while systemd holds that start
    # job back until this unit finishes. The device hangs at boot and never
    # comes up. With --no-block the job is queued and runs as soon as we exit,
    # which is exactly what the ordering is there to arrange.
    systemctl restart --no-block "$SERVICENAME"

    log "provisioning complete"
}

main "$@"

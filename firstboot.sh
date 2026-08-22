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

    if [ -f "$ENVFILE" ]; then
        # Re-provisioning: dropping a new file on an already-configured device
        # moves it to another laundry. That is the useful behaviour, but it is
        # worth a loud log line because it changes the device's identity.
        log "WARNING: ${ENVFILE} already exists and will be overwritten"
        cp -p "$ENVFILE" "${ENVFILE}.previous" 2>/dev/null || true
    fi

    # The provisioning file is already in .env format (KEY="value"), the same
    # line setup_pagalava_iot.sh writes, so this is a copy and not a parse.
    if ! cp "$provfile" "$ENVFILE"; then
        log "ERROR: could not write ${ENVFILE}"
        exit 1
    fi
    chown "${PAGALAVA_USER}:${PAGALAVA_USER}" "$ENVFILE" || true
    chmod 600 "$ENVFILE"
    log "wrote ${ENVFILE} (mode 600, owner ${PAGALAVA_USER})"

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

#!/bin/bash
# Write into the boot partition of the staged image whatever the real installer
# would put on the SD card, before the target ever boots it.
#
#   ./prepare_boot.sh flashed <provisioning-file>
#       Drops the provisioning file on the boot partition, which is exactly what
#       an installer does after flashing the PagaLava image.
#
#   ./prepare_boot.sh manual <user> <password>
#       Writes `ssh` and `userconf.txt`, the headless equivalent of Raspberry Pi
#       Imager's customisation step. Stock Pi OS Lite ships with no default user
#       and SSH off, so without this it waits on a console wizard nobody can see.
#
# NOTE the two paths are opposites, and it is easy to apply the wrong one:
#   - PagaLava image: the installer must REFUSE Imager customisation, because it
#     conflicts with the image's own user and first-boot configuration.
#   - Manual install: customisation is REQUIRED, or there is no way in.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"

MODE="${1:?usage: prepare_boot.sh flashed <prov-file> | manual <user> <pass>}"
kvm_require

LUN='/sys/kernel/config/usb_gadget/kvmd/functions/mass_storage.usb0/lun.0'
IMG="$(kvm "cat ${LUN}/file" 2>/dev/null)"
[ -n "$IMG" ] || die "no image is attached; run serve_image.sh first"

# The target must not be running from this image while we mount it.
if [ -n "${TARGET_HOST:-}" ] && target_up 1; then
    die "the target is up and running from this image — mounting it now would corrupt it"
fi

# Offset comes from the partition table rather than being hardcoded: it differs
# between Pi OS releases.
OFF="$(kvm "sfdisk -d '${IMG}' 2>/dev/null | awk '/img1|p1/ {for(i=1;i<=NF;i++) if(\$i==\"start=\") print \$(i+1)}' | tr -d ','")"
[ -n "$OFF" ] || OFF=8192
BYTES=$((OFF * 512))
info "boot partition at offset ${BYTES}"

case "$MODE" in
  flashed)
    PROV="${2:?flashed mode needs a provisioning file}"
    [ -f "$PROV" ] || die "no such provisioning file: $PROV"
    NAME="$(basename "$PROV")"
    kvm "mkdir -p /tmp/bp && mount -o loop,offset=${BYTES} '${IMG}' /tmp/bp" || die "could not mount the boot partition"
    kvm "cat > '/tmp/bp/${NAME}'" < "$PROV" || die "could not write the provisioning file"
    kvm "ls -l '/tmp/bp/${NAME}' | sed 's|^|        |'; sync; umount /tmp/bp"
    echo "  provisioning file placed as it would be on a flashed card"
    echo "  (its mode shows 0755 because the boot partition is FAT and has no"
    echo "   Unix permissions — true on a real card too, which is why first boot"
    echo "   deletes the file rather than relying on permissions)"
    ;;
  manual)
    U="${2:?manual mode needs a user}"; P="${3:?manual mode needs a password}"
    HASH="$(openssl passwd -6 "$P")" || die "could not hash the password"
    kvm "mkdir -p /tmp/bp && mount -o loop,offset=${BYTES} '${IMG}' /tmp/bp" || die "could not mount the boot partition"
    kvm "touch /tmp/bp/ssh && printf '%s:%s\n' '${U}' '${HASH}' > /tmp/bp/userconf.txt && ls /tmp/bp | grep -E '^ssh$|userconf' | sed 's|^|        |'; sync; umount /tmp/bp"
    echo "  ssh enabled and user '${U}' configured for a headless first boot"
    ;;
  *) die "unknown mode: $MODE (expected 'flashed' or 'manual')" ;;
esac

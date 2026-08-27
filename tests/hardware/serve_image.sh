#!/bin/bash
# Stage an image on the PiKVM and attach it to the target as a writable USB disk.
#
#   ./serve_image.sh <local-image.img.xz|.img> [--expand-to 12G]
#
# Handles the three things that are easy to get wrong, each of which fails in a
# way that does not point at the cause:
#
#  1. The MSD store is mounted read-only. `kvmd-otgmsd --set-rw 1` then reports
#     success and silently does nothing.
#  2. The gadget's `ro` flag cannot be changed while a backing file is attached,
#     so the file has to be detached first.
#  3. Raspberry Pi OS expands its root filesystem to fill the card on first
#     boot. A virtual disk is exactly the size of its image file, so there is
#     nothing to expand into: the rootfs stays small and fills during `apt`,
#     reporting "No space left on device" long after the boot that caused it.
#     The image is therefore expanded BEFORE it is ever attached.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"

IMG_LOCAL="${1:?usage: serve_image.sh <image> [--expand-to SIZE]}"
EXPAND_TO="12G"
[ "${2:-}" = "--expand-to" ] && EXPAND_TO="${3:?--expand-to needs a size}"

[ -f "$IMG_LOCAL" ] || die "no such image: $IMG_LOCAL"
kvm_require

REMOTE_NAME="$(basename "${IMG_LOCAL%.xz}")"
REMOTE="${MSD_DIR}/${REMOTE_NAME}"

echo "Staging ${REMOTE_NAME} on ${KVM_HOST}"
kvm "kvmd-helper-otgmsd-remount rw" >/dev/null 2>&1 || die "could not make the MSD store writable"

# Detach first: the ro flag is immutable while a file is attached, and we must
# not be writing to an image some target is still running from.
LUN='/sys/kernel/config/usb_gadget/kvmd/functions/mass_storage.usb0/lun.0'
kvm "kvmd-otgconf -e mass_storage.usb0 >/dev/null 2>&1; echo '' > ${LUN}/file" || die "could not detach the current image"

if [ "${IMG_LOCAL##*.}" = "xz" ]; then
    info "decompressing during transfer"
    xz -dc "$IMG_LOCAL" | kvm "cat > '${REMOTE}'" || die "transfer failed"
else
    kvm "cat > '${REMOTE}'" < "$IMG_LOCAL" || die "transfer failed"
fi
kvm "ls -l '${REMOTE}' | awk '{print \"        transferred: \"\$5\" bytes\"}'"

echo "Expanding to ${EXPAND_TO} before first attach"
kvm "bash -s" <<REMOTE_SCRIPT || die "expansion failed"
set -eu
truncate -s ${EXPAND_TO} '${REMOTE}'
echo ', +' | sfdisk -N 2 --no-reread --force '${REMOTE}' >/dev/null 2>&1
LOOP=\$(losetup -f --show -P '${REMOTE}')
e2fsck -fp "\${LOOP}p2" >/dev/null 2>&1 || true
resize2fs "\${LOOP}p2" 2>&1 | tail -1 | sed 's/^/        /'
losetup -d "\$LOOP"
REMOTE_SCRIPT

echo "Attaching as a writable disk"
kvm "bash -s" <<REMOTE_SCRIPT || die "attach failed"
set -eu
echo '' > ${LUN}/file
echo 0 > ${LUN}/ro
echo '${REMOTE}' > ${LUN}/file
REMOTE_SCRIPT

RO="$(kvm "cat ${LUN}/ro")"
FILE="$(kvm "cat ${LUN}/file")"
[ "$RO" = "0" ] || die "image attached read-only; a booting OS will fail to write"
echo "  attached: ${FILE} (writable)"
echo
echo "The target must now be powered on. A Raspberry Pi cannot be woken"
echo "remotely — no standby rail, so Wake-on-LAN and ATX both do nothing."

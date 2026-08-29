#!/bin/bash
#
# Build a PagaLava golden image from Raspberry Pi OS Lite (64-bit).
#
# The result is a .img.xz that an installer flashes with Raspberry Pi Imager,
# drops a provisioning file onto, and boots. Everything the setup scripts do at
# install time — apt upgrade, packages, venv, pip install — is done here once,
# per firmware release, instead of once per device over the installer's tether.
#
# The image contains NO identity: no .env, no connection string, no SSH host
# keys, no WiFi credentials. It is the same file for every customer. First boot
# (firstboot.sh) is what turns it into a specific laundry's device.
#
# Run on a Debian/Ubuntu x86_64 host. ARM binaries in the image are executed
# through binfmt/qemu-user-static, so no Pi is needed to build.
#
# Usage: sudo ./build_image.sh [output-directory]

set -euo pipefail

OUTDIR="${1:-$(pwd)/dist}"
WORKDIR="$(mktemp -d /var/tmp/pagalava-image-XXXXXX)"
MNT="${WORKDIR}/mnt"

# Pinned rather than "latest": a golden image is only useful if it is
# reproducible, and Raspberry Pi OS "latest" moves under you.
RPIOS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.img.xz"
RPIOS_XZ="$(basename "$RPIOS_URL")"
RPIOS_IMG="${RPIOS_XZ%.xz}"

REPO_URL="https://github.com/airesmarques/pagalava-iot"
# Which revision goes into the image. Override to build a release candidate
# before it is on main.
REPO_REF="${REPO_REF:-main}"
# Build from a local working tree instead of cloning. Needed to test a branch
# that has not been pushed, and to build reproducibly while offline.
LOCAL_REPO="${LOCAL_REPO:-}"
PAGALAVA_USER="pagalava"
WORKINGDIR="/home/${PAGALAVA_USER}/pagalava-iot"
VENVDIR="${WORKINGDIR}/.venv"
# Grow the root filesystem by this much to fit apt packages and the venv.
GROW_MB=2048

VERSION="$(python3 -c 'import json;print(json.load(open("version.json"))["version"])' 2>/dev/null || echo "unknown")"
OUTNAME="pagalava-iot-${VERSION}-arm64.img"

log()  { echo ""; echo "=== $* ==="; }
fail() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
    set +e
    # Order matters: nested mounts first, or the umounts fail and the loop
    # device stays attached, leaving the host with stale mounts.
    for m in dev/pts dev proc sys boot/firmware ""; do
        mountpoint -q "${MNT}/${m}" && umount -l "${MNT}/${m}"
    done
    [ -n "${LOOPDEV:-}" ] && losetup -d "$LOOPDEV" 2>/dev/null
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || fail "must run as root (needs losetup and mount)"

log "checking host tooling"
for t in wget xz losetup parted resize2fs e2fsck qemu-aarch64-static; do
    command -v "$t" >/dev/null || fail "missing '$t'. Install: apt-get install -y wget xz-utils parted e2fsprogs qemu-user-static binfmt-support"
done
# Without binfmt registration, every command in the chroot dies with ENOEXEC.
[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || fail "qemu-aarch64 binfmt not registered. Try: apt-get install -y binfmt-support qemu-user-static && systemctl restart systemd-binfmt"

mkdir -p "$OUTDIR" "$MNT"

log "fetching Raspberry Pi OS Lite"
if [ ! -f "${OUTDIR}/${RPIOS_XZ}" ]; then
    wget -q --show-progress -O "${OUTDIR}/${RPIOS_XZ}" "$RPIOS_URL"
fi
cp "${OUTDIR}/${RPIOS_XZ}" "${WORKDIR}/${RPIOS_XZ}"
xz -d "${WORKDIR}/${RPIOS_XZ}"

log "growing the image by ${GROW_MB}MB"
# The stock Lite image has almost no slack; apt plus the venv will not fit.
dd if=/dev/zero bs=1M count="$GROW_MB" >> "${WORKDIR}/${RPIOS_IMG}" 2>/dev/null
parted -s "${WORKDIR}/${RPIOS_IMG}" resizepart 2 100%

LOOPDEV="$(losetup -f --show -P "${WORKDIR}/${RPIOS_IMG}")"
e2fsck -fp "${LOOPDEV}p2" >/dev/null 2>&1 || true
resize2fs "${LOOPDEV}p2" >/dev/null

log "mounting"
mount "${LOOPDEV}p2" "$MNT"
mkdir -p "${MNT}/boot/firmware"
mount "${LOOPDEV}p1" "${MNT}/boot/firmware"
mount --bind /dev  "${MNT}/dev"
mount --bind /dev/pts "${MNT}/dev/pts"
mount -t proc proc "${MNT}/proc"
mount -t sysfs sys "${MNT}/sys"
cp /etc/resolv.conf "${MNT}/etc/resolv.conf"

log "provisioning the image (chroot)"
# QUOTED heredoc: the host must not expand anything in here. Configuration
# reaches the script through the environment on the chroot call below, so a
# stray backtick or $(...) in a comment cannot execute at write time.
cat > "${MNT}/tmp/build-inside.sh" <<'INSIDE'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Supplied by the chroot call. ${VAR:?} aborts with a clear message rather than
# letting an empty value produce an image with nonsense paths in it.
: "${PAGALAVA_USER:?not set by the caller}"
: "${WORKINGDIR:?not set by the caller}"
: "${VENVDIR:?not set by the caller}"
: "${REPO_URL:?not set by the caller}"
: "${REPO_REF:?not set by the caller}"

# The default user does not exist in a stock image; normally the Imager creates
# one. The image ships with a fixed unprivileged account instead, because the
# systemd unit and firstboot.sh both need a known home directory.
id -u ${PAGALAVA_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${PAGALAVA_USER}
usermod -aG gpio,spi,i2c,dialout,sudo ${PAGALAVA_USER} 2>/dev/null || true

# Daemons must not start inside the chroot — there is no init here and their
# start scripts hang or fail.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# initramfs-tools and raspi-firmware cannot run their maintainer scripts under
# emulation: they look for a real boot device and an initramfs to rebuild, and
# fail the whole apt transaction when they do not find one. Observed as:
#   Errors were encountered while processing:
#    initramfs-tools-core / initramfs-tools / raspi-firmware
#   E: Sub-process /usr/bin/dpkg returned an error code (1)
# Hold them. The stock image's kernel and firmware are already the ones we
# want to ship; nothing here needs a newer boot chain, and upgrading it is the
# one thing most likely to produce an image that will not boot.
apt-mark hold raspi-firmware initramfs-tools initramfs-tools-core >/dev/null

apt-get update
apt-get -y upgrade
apt-get -y install git python3 python3-venv python3-pip python3-dev build-essential

# SPI is needed by the relay boards.
raspi-config nonint do_spi 0 || true

# Raspberry Pi OS soft-blocks the WiFi radio until a regulatory country is
# set — rfkill reports "Soft blocked: yes" and nmcli cannot connect at all.
# Setting a country is a regulatory requirement, not a Pi quirk. PT because
# that is where these devices are installed; change it here if that changes.
# Ethernet is unaffected either way.
raspi-config nonint do_wifi_country PT || true

# Pi OS's first-user wizard. It is still armed on a stock image and does not
# recognise the pagalava user we created above, so it prints "SSH may not work
# until a valid user has been set up" on every login and can launch a setup
# wizard on an attached console. We have a user; disable it.
systemctl disable userconfig.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/userconfig.service
# Disabling the service is NOT enough: the "SSH may not work until a valid user
# has been set up" text is an sshd Banner, configured separately in
# sshd_config.d/rename_user.conf. It kept appearing on every login after the
# service was disabled, which is alarming on a device that is working fine.
rm -f /etc/ssh/sshd_config.d/rename_user.conf
# The same package also gates a getty override for the wizard.
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf 2>/dev/null || true

# Keep the journal across reboots. The first-boot log is the one thing that
# explains a failed install, and on a volatile journal it is gone the moment
# anyone reboots to try again — which is exactly what an installer does.
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true
sed -i 's/^#\?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf
# Bounded so logs cannot fill a small card.
grep -q '^SystemMaxUse=' /etc/systemd/journald.conf \
  || echo 'SystemMaxUse=100M' >> /etc/systemd/journald.conf

if [ -d /tmp/pagalava-src ]; then
    # Seeded from LOCAL_REPO by the host before the chroot ran.
    mkdir -p ${WORKINGDIR}
    cp -a /tmp/pagalava-src/. ${WORKINGDIR}/
    rm -rf /tmp/pagalava-src
else
    git clone --branch ${REPO_REF} --depth 1 ${REPO_URL} ${WORKINGDIR}
fi
chown -R ${PAGALAVA_USER}:${PAGALAVA_USER} ${WORKINGDIR}

sudo -u ${PAGALAVA_USER} python3 -m venv ${VENVDIR}
sudo -u ${PAGALAVA_USER} ${VENVDIR}/bin/pip install --no-cache-dir -q -r ${WORKINGDIR}/requirements.txt

# The messaging unit. Note there is deliberately NO
# Environment="IOT_CONNECTION_STRING=..." line: the image has no credential to
# bake, and .env must be the single source of truth. The legacy setup scripts
# still write that line on devices they install, and those devices are left
# alone — this applies to the image only.
cat > /etc/systemd/system/receive_messages.service <<UNIT
[Unit]
Description=Receive Messages Service
After=network-online.target
Wants=network-online.target

[Service]
User=${PAGALAVA_USER}
Group=${PAGALAVA_USER}
WorkingDirectory=${WORKINGDIR}
Environment="PATH=${VENVDIR}/bin"
ExecStart=${VENVDIR}/bin/python ${WORKINGDIR}/ReceiveMessages.py

Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=300
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
UNIT

chmod 755 ${WORKINGDIR}/firstboot.sh
install -m 644 ${WORKINGDIR}/pagalava-firstboot.service /etc/systemd/system/pagalava-firstboot.service

# Let the service restart itself after an upgrade, and nothing else.
#
# message_upgrade() pulls new code then restarts the unit so it takes effect.
# That needs root, and the service does not run as root; sudo from a service
# has no tty, so without this the restart fails silently and the device keeps
# running the old code until someone reboots it.
#
# Deliberately ONE command, not blanket NOPASSWD. Validated before being put
# in place: a malformed file in /etc/sudoers.d breaks sudo for every user.
cat > /tmp/pagalava-restart <<SUDOERS
# Every privileged operation the running service performs, and nothing else.
# reboot is here because message_reboot() shells out to sudo reboot: without it, a
# reboot command from the dashboard fails silently on an image-installed device,
# where the user has no blanket NOPASSWD (a manual install gets one from Pi OS's
# 010_pi-nopasswd, which is why this went unnoticed). All three reboot paths are
# listed because the firmware probes for whichever exists.
${PAGALAVA_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart receive_messages.service, /usr/bin/systemctl reboot, /sbin/reboot, /usr/sbin/reboot, /bin/reboot, /bin/true, /usr/bin/true
SUDOERS
if visudo -c -f /tmp/pagalava-restart >/dev/null 2>&1; then
    install -m 440 -o root -g root /tmp/pagalava-restart /etc/sudoers.d/pagalava-restart
    echo "installed /etc/sudoers.d/pagalava-restart"
else
    echo "WARNING: generated sudoers rule failed validation; skipping it." >&2
    echo "         Upgrades will need a reboot to take effect." >&2
fi
rm -f /tmp/pagalava-restart

# First boot is enabled; the messaging service is NOT. An image booted without a
# provisioning file must sit idle rather than crash-loop on a missing
# connection string — firstboot.sh is what enables it once there is one.
#
# These symlinks are made by hand because systemd REFUSES to enable or disable
# units inside a chroot — it prints "Running in chroot, ignoring request." and
# returns success, so 'systemctl enable' here is a silent no-op. An image built
# that way boots and then sits there doing nothing, forever, with no error
# anywhere. Creating the wants symlink is exactly what enable itself does.
#
# NOTE: no backticks anywhere in this heredoc. It is unquoted (<<INSIDE) so the
# host expands it, and a backtick in a comment is still command substitution:
# an earlier version of this comment ran the 'enable' builtin at write time and
# its multi-line output broke out of the comment and became real commands.
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/pagalava-firstboot.service \
       /etc/systemd/system/multi-user.target.wants/pagalava-firstboot.service
# And make certain the messaging service is not enabled.
rm -f /etc/systemd/system/multi-user.target.wants/receive_messages.service

apt-get clean
rm -rf /var/lib/apt/lists/*

# Leave the image in a normal state: a held package or a permanent
# policy-rc.d would silently change how the device behaves later.
apt-mark unhold raspi-firmware initramfs-tools initramfs-tools-core >/dev/null
rm -f /usr/sbin/policy-rc.d
INSIDE
chmod +x "${MNT}/tmp/build-inside.sh"

# Cheap insurance: a malformed generated script should fail here, with the
# image still untouched, rather than halfway through the chroot.
bash -n "${MNT}/tmp/build-inside.sh" || fail "generated build-inside.sh is not valid bash"

if [ -n "$LOCAL_REPO" ]; then
    [ -d "$LOCAL_REPO" ] || fail "LOCAL_REPO='$LOCAL_REPO' is not a directory"
    log "seeding source from ${LOCAL_REPO} (not cloning)"
    mkdir -p "${MNT}/tmp/pagalava-src"
    # --exclude .git keeps the image small; the device does not need history.
    # dist/ would otherwise nest a previous image inside this one.
    tar -C "$LOCAL_REPO" --exclude=.git --exclude=dist --exclude=.venv -cf - . \
        | tar -C "${MNT}/tmp/pagalava-src" -xf -
fi

chroot "$MNT" /usr/bin/env \
    PAGALAVA_USER="$PAGALAVA_USER" \
    WORKINGDIR="$WORKINGDIR" \
    VENVDIR="$VENVDIR" \
    REPO_URL="$REPO_URL" \
    REPO_REF="$REPO_REF" \
    /tmp/build-inside.sh

log "stripping identity"
# Anything that would make two devices flashed from this image indistinguishable
# in the wrong way, or that would leak the build host.
rm -f  "${MNT}/tmp/build-inside.sh"
rm -f  "${MNT}"/etc/ssh/ssh_host_*             # regenerated on first boot
rm -f  "${MNT}${WORKINGDIR}/.env"              # must not exist
rm -f  "${MNT}${WORKINGDIR}/config.json"
rm -f  "${MNT}/etc/wpa_supplicant/wpa_supplicant.conf"
rm -f  "${MNT}/root/.bash_history" "${MNT}/home/${PAGALAVA_USER}/.bash_history"
rm -f  "${MNT}/etc/machine-id"; : > "${MNT}/etc/machine-id"
rm -rf "${MNT}/var/log/"*

# Seed the clock to the build time. A Pi has no RTC, so at first boot it believes
# whatever fake-hwclock last saved — which in a golden image is whenever the base
# Raspberry Pi OS image was produced, potentially many months earlier. IoT Hub
# then refuses the TLS handshake with "certificate is not yet valid" and the
# device cannot connect AT ALL until NTP corrects it. Observed on the 1.9
# hardware test: the device came up believing it was four months earlier and only
# connected once timesyncd caught up. It recovered, but on a site where NTP is
# slow or filtered this is a device that looks dead on arrival with no
# explanation on screen.
#
# This does not remove the need for NTP; it shrinks the window to "time since
# this image was built" instead of "time since Raspberry Pi OS was released".
date -u '+%Y-%m-%d %H:%M:%S' > "${MNT}/etc/fake-hwclock.data"
# Recreate the journal directory the strip above just deleted. Its EXISTENCE is
# what makes journald persistent, so removing build logs must not take it with
# them — the first-boot log is the one worth keeping. root:systemd-journal 2755
# is what journald expects; the gid is looked up in the image, not assumed.
mkdir -p "${MNT}/var/log/journal"
_jgid="$(chroot "$MNT" getent group systemd-journal 2>/dev/null | cut -d: -f3)"
if [ -n "$_jgid" ]; then
    chown "0:${_jgid}" "${MNT}/var/log/journal"
    chmod 2755 "${MNT}/var/log/journal"
else
    echo "  note: systemd-journal group not found; journald will fix ownership on boot"
fi
: > "${MNT}/etc/resolv.conf"

log "verifying the image carries no identity"
problems=0
[ -f "${MNT}${WORKINGDIR}/.env" ] && { echo "  .env present!"; problems=1; }
if grep -rqs "IOT_CONNECTION_STRING=" "${MNT}/etc/systemd/system/"; then
    echo "  a systemd unit carries a connection string!"; problems=1
fi
if [ -n "$(ls "${MNT}"/etc/ssh/ssh_host_* 2>/dev/null)" ]; then
    echo "  SSH host keys present!"; problems=1
fi
# -L, not -e. These are symlinks whose targets are absolute paths INSIDE the
# image; tested from the host, -e resolves them against the host's root, finds
# nothing, and reports the link as absent. That made the firstboot check reject
# good images, and — far worse — made the receive_messages check unable to fail
# at all, since a wrongly-enabled service would also read as absent.
WANTS="${MNT}/etc/systemd/system/multi-user.target.wants"
if [ -L "${WANTS}/receive_messages.service" ] || [ -e "${WANTS}/receive_messages.service" ]; then
    echo "  receive_messages.service is enabled — it must ship disabled!"; problems=1
fi
if [ ! -L "${WANTS}/pagalava-firstboot.service" ] && [ ! -e "${WANTS}/pagalava-firstboot.service" ]; then
    echo "  pagalava-firstboot.service is NOT enabled — the image cannot provision itself!"; problems=1
fi
# The link must also point at a unit that actually exists in the image.
if [ "$(chroot "$MNT" raspi-config nonint get_wifi_country 2>/dev/null)" != "PT" ]; then
    echo "  WiFi country is not set — the radio stays rfkill-blocked!"; problems=1
fi
if [ -e "${MNT}/etc/systemd/system/multi-user.target.wants/userconfig.service" ]; then
    echo "  userconfig.service is still enabled — it will nag on every login!"; problems=1
fi
if grep -rqs "^Banner" "${MNT}/etc/ssh/sshd_config.d/" "${MNT}/etc/ssh/sshd_config" 2>/dev/null; then
    echo "  an sshd Banner is still configured — the first-user nag will show on every login!"; problems=1
fi
if [ ! -d "${MNT}/var/log/journal" ]; then
    echo "  journal is not persistent — first-boot logs will be lost on reboot!"; problems=1
fi
if [ -f "${MNT}/etc/sudoers.d/pagalava-restart" ]; then
    # A broken sudoers file is worse than none: it can lock everyone out of
    # sudo on the device.
    if ! chroot "$MNT" visudo -c -f /etc/sudoers.d/pagalava-restart >/dev/null 2>&1; then
        echo "  /etc/sudoers.d/pagalava-restart is present but INVALID!"; problems=1
    fi
    if [ "$(stat -c '%a' "${MNT}/etc/sudoers.d/pagalava-restart")" != "440" ]; then
        echo "  /etc/sudoers.d/pagalava-restart has the wrong mode!"; problems=1
    fi
fi
if [ ! -s "${MNT}/etc/fake-hwclock.data" ]; then
    echo "  /etc/fake-hwclock.data is missing or empty — first boot will start with a"
    echo "  stale clock and IoT Hub will refuse the TLS handshake until NTP catches up."
    problems=1
fi
if [ ! -f "${MNT}/etc/systemd/system/pagalava-firstboot.service" ]; then
    echo "  pagalava-firstboot.service unit file is missing from the image!"; problems=1
fi
[ "$problems" -eq 0 ] || fail "image failed its own checks; not publishing"
echo "  clean"

log "packing"
for m in dev/pts dev proc sys boot/firmware ""; do
    mountpoint -q "${MNT}/${m}" && umount -l "${MNT}/${m}"
done
losetup -d "$LOOPDEV"; LOOPDEV=""

mv "${WORKDIR}/${RPIOS_IMG}" "${OUTDIR}/${OUTNAME}"
xz -T0 -f "${OUTDIR}/${OUTNAME}"
sha256sum "${OUTDIR}/${OUTNAME}.xz" > "${OUTDIR}/${OUTNAME}.xz.sha256"

log "done"
ls -lh "${OUTDIR}/${OUTNAME}.xz"
cat "${OUTDIR}/${OUTNAME}.xz.sha256"

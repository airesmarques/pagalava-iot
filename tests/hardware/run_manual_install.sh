#!/bin/bash
# Run the manual installer on the target, unattended, and exercise whichever
# connection-string path is asked for.
#
#   ./run_manual_install.sh provisioning   # file on the boot partition, no prompt
#   ./run_manual_install.sh interactive    # answer the prompt, as an installer does
#
# The interactive mode matters more than it looks: supplying a provisioning file
# skips `read -r IOT_CONNECTION_STRING` entirely, so the path every existing
# installer uses would otherwise never be tested.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"
require_env
MODE="${1:?usage: run_manual_install.sh provisioning|interactive}"
BRANCH="${FIRMWARE_BRANCH:-main}"
URL="https://raw.githubusercontent.com/airesmarques/pagalava-iot/${BRANCH}/setup_pagalava_iot.sh"

target_up 1 || die "cannot reach ${TARGET_HOST}:22"

echo "Fetching the installer from ${BRANCH}"
tgt "curl -fsSL -o \$HOME/setup_pagalava_iot.sh '${URL}'" || die "could not download the installer"
tgt 'wc -l < $HOME/setup_pagalava_iot.sh' | sed 's/^/        lines: /'

# Never run the installer through sudo. It installs into $HOME and writes a unit
# with the invoking user, so `sudo bash setup_pagalava_iot.sh` installs into
# /root and leaves the service running as root. The script now refuses, but this
# keeps the harness honest even against older copies.
echo "Running as ${TARGET_USER} (never via sudo)"

case "$MODE" in
  provisioning)
    tgt "ls /boot/firmware/pagalava-provisioning*.txt" >/dev/null 2>&1 \
        || die "provisioning mode needs the file on the boot partition (see prepare_boot.sh)"
    STDIN_SRC="< /dev/null"
    ;;
  interactive)
    CS="$(tgt "grep -m1 '^IOT_CONNECTION_STRING=' /boot/firmware/pagalava-provisioning*.txt 2>/dev/null | cut -d= -f2- | tr -d '\"'" | tr -d '\r')"
    [ -n "$CS" ] || die "need a connection string to paste; put a provisioning file on the boot partition first"
    tgt "printf '%s\n' $(printf '%q' "$CS") > /tmp/cs.txt && chmod 600 /tmp/cs.txt"
    # Move the file aside so the script MUST prompt.
    tgt_root "mv /boot/firmware/pagalava-provisioning*.txt /root/prov.bak" >/dev/null 2>&1
    # The string is written into the pipe up front and the pipe held open, so it
    # waits in the buffer until `read` asks. A FIFO would deadlock on open(),
    # and a process holding it open dies with the SSH session.
    STDIN_SRC="< <(cat /tmp/cs.txt; sleep 3600)"
    ;;
  *) die "unknown mode: $MODE" ;;
esac

# Detached, so the run survives this script and any CI step timeout.
tgt "rm -f /tmp/install.log; setsid nohup bash -c 'bash \$HOME/setup_pagalava_iot.sh ${STDIN_SRC} > /tmp/install.log 2>&1; echo INSTALL_DONE_rc=\$? >> /tmp/install.log' </dev/null >/dev/null 2>&1 & sleep 3; echo started"

echo "Waiting for it to finish (up to 40 minutes)"
for i in $(seq 1 120); do
    if tgt 'grep -q INSTALL_DONE_rc /tmp/install.log 2>/dev/null'; then break; fi
    if tgt 'df --output=pcent / 2>/dev/null | tail -1 | tr -dc 0-9' | grep -qx 100; then
        die "the target ran out of disk — the served image was not expanded (see serve_image.sh)"
    fi
    sleep 20
done

RC="$(tgt 'grep -o "INSTALL_DONE_rc=[0-9]*" /tmp/install.log 2>/dev/null | tail -1 | cut -d= -f2' | tr -d '\r')"
[ -n "$RC" ] || die "the installer did not finish within the timeout"

echo
if [ "$MODE" = "interactive" ]; then
    tgt 'grep -q "introduz o valor da IOT_CONNECTION_STRING" /tmp/install.log' \
        && ok "the prompt appeared" || bad "the prompt never appeared"
    tgt 'grep -q "^IOT_CONNECTION_STRING=HostName" /tmp/install.log' \
        && ok "the pasted connection string was accepted" || bad "the connection string was not accepted"
    tgt 'grep -q "is required to proceed" /tmp/install.log' \
        && bad "the installer got an empty connection string" || ok "no empty-value error"
    tgt_root "cp /root/prov.bak /boot/firmware/ 2>/dev/null" >/dev/null 2>&1 || true
else
    tgt 'grep -q "A usar o ficheiro de instalacao" /tmp/install.log' \
        && ok "the provisioning file was found, so no prompt was needed" \
        || bad "the installer did not use the provisioning file"
fi
[ "$RC" = "0" ] && ok "installer exited 0" || bad "installer exited ${RC}"

# The unit must belong to the invoking user, not root.
U="$(tgt "grep '^User=' /etc/systemd/system/receive_messages.service | cut -d= -f2" | tr -d '\r')"
[ "$U" = "$TARGET_USER" ] && ok "service runs as ${U}" \
                          || bad "service runs as '${U}' — expected ${TARGET_USER} (was it run under sudo?)"

summary

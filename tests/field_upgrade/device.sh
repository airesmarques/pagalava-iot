#!/bin/bash
set -euo pipefail
revision=$1
source=$2
target=$3
policy=$4
os=$5
useradd -m pagalava
checkout=/home/pagalava/pagalava-iot
remote=/home/pagalava/origin.git
as_device() {
    runuser -u pagalava -- "$@" </dev/null
}

git init --quiet --bare --initial-branch=main "$remote"
git -C "$remote" index-pack --stdin
git -C "$remote" update-ref refs/heads/main "$source"
chown -R pagalava:pagalava "$remote"
as_device git clone --quiet --no-local "$remote" "$checkout"
cd "$checkout"
setup=setup_pagalava_iot.sh
if [[ $os == 11 && $revision != 653acde ]]; then
    setup=setup_pagalava_iot_debian11.sh
fi
echo "== Setup $revision on Debian $os using $setup =="
for line in 'User=${USERNAME}' 'WorkingDirectory=${WORKINGDIR}' \
    'Environment="PATH=${VENVDIR}/bin"' 'ExecStart=${VENVDIR}/bin/python ${WORKINGDIR}/${SCRIPTNAME}'; do
    grep -Fx "$line" "$setup"
done
# Render the service from the selected historical setup template. The
# container uses the unit's process settings directly without starting systemd.
unit=/etc/systemd/system/receive_messages.service
sed -n '/^\[Unit\]/,/^WantedBy=/p' "$setup" |
    sed -e 's|${USERNAME}|pagalava|g' -e 's|${GROUPNAME}|pagalava|g' \
        -e 's|${WORKINGDIR}|'"$checkout"'|g' -e 's|${VENVDIR}|'"$checkout/.venv"'|g' \
        -e 's|${SCRIPTNAME}|ReceiveMessages.py|g' \
        -e 's|${IOT_CONNECTION_STRING}|offline-fixture|g' > "$unit"
unit_path=$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' "$unit")
unit_user=$(sed -n 's/^User=//p' "$unit")
unit_checkout=$(sed -n 's/^WorkingDirectory=//p' "$unit")
read -r unit_python unit_script < <(sed -n 's/^ExecStart=//p' "$unit")
[[ $unit_user == pagalava && $unit_checkout == "$checkout" ]]
[[ $unit_path == "$checkout/.venv/bin" && $unit_script == "$checkout/ReceiveMessages.py" ]]
as_device python3 -m venv .venv
as_device "$unit_python" --version
as_device .venv/bin/python -m pip install --disable-pip-version-check --no-index \
    --find-links "/wheels/requirements-$revision" -r requirements.txt
as_device .venv/bin/python -m pip freeze
as_device git -C "$remote" update-ref refs/heads/main "$target"

# Replace only the container's privileged command entry points.
mv /usr/bin/git /usr/bin/git.real
install -m 755 /rig/observe-git.sh /usr/bin/git
rm -f /usr/bin/sudo /usr/bin/systemctl /sbin/reboot
install -m 755 /rig/record-command.sh /usr/bin/sudo
install -m 755 /rig/record-command.sh /usr/bin/systemctl
install -m 755 /rig/record-command.sh /sbin/reboot
if [[ -d /usr/sbin && ! -e /usr/sbin/reboot ]]; then
    ln -s /sbin/reboot /usr/sbin/reboot
fi

service() {
    as_device /usr/bin/env -i HOME=/home/pagalava USER=pagalava LOGNAME=pagalava \
        PATH="$unit_path" IOT_CONNECTION_STRING=offline-fixture \
        RIG_SUDO_POLICY="$policy" PYTHONDONTWRITEBYTECODE=1 \
        "$unit_python" "$@"
}
echo "== Historical handler =="
service /rig/probe.py upgrade "$revision" "$source" "$target" "$policy" "$os"
echo "== Simulated restart in a fresh interpreter =="
service -c 'import sys; sys.path.append("/rig"); import probe; probe.restart()'
target_version=$(as_device git --git-dir="$remote" show "${target}:version.json" |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
if [[ $target_version == 1.10 && $revision == 1fefd13 ]]; then
    # One manual fast-forward bypasses the old updater's incomplete PATH.
    as_device git pull --ff-only origin main
    [[ $(as_device git rev-parse HEAD) == "$target" ]]
    echo "MANUAL FAST-FORWARD reached $target"
    service -c 'import sys; sys.path.append("/rig"); import probe; probe.restart()'
fi
if [[ $target_version == 1.10 && $revision == 0d02b65 ]]; then
    echo "== Unified updater second hop =="
    service /rig/probe.py second_hop "$remote" "$policy"
    service /rig/probe.py credential
    baseline=/home/pagalava/baseline
    as_device mkdir "$baseline"
    as_device /bin/bash -c 'git --git-dir="$1" archive 61b7afa | tar -xf - -C "$2"' _ "$remote" "$baseline"
    for version in 1.10 1.9 1.3 2.0; do
        trace=$(service /rig/probe.py relay "$version" | sed -n 's/^RELAY TRACE //p')
        echo "RELAY $version $trace"
        if [[ $version == 1.10 ]]; then
            expected=$trace
        fi
        [[ -n $trace && $trace == "$expected" ]]
    done
    trace=$(cd "$baseline" && service /rig/probe.py relay 1.9 | sed -n 's/^RELAY TRACE //p')
    echo "RELAY 61b7afa $trace"
    [[ $trace == "$expected" ]]
    echo "Activation parity: 1.10, 1.9, 1.3 and 2.0 match 61b7afa"
fi

if [[ $target == 61b7afa* && $(as_device git rev-parse HEAD) == "$target" ]]; then
    echo "== Second upgrade with target script and explicit main channel =="
    as_device /bin/bash -c 'echo main > .update-channel'
    service /rig/probe.py guard
    echo "== Synthetic version.json and target activation handler =="
    as_device /bin/bash -c 'echo "{\"version\":\"1.10\"}" > version.json'
    service /rig/probe.py activation
fi

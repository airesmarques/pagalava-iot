#!/bin/bash
set -euo pipefail
revision=$1
source=$2
target=$3
policy=$4
os=$5
version=$6
install_type=$7
expected=$8
requirements=$9
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
if [[ $install_type == image ]]; then
    as_device mkdir "$checkout"
    as_device /bin/bash -o pipefail -c 'git --git-dir="$1" archive "$2" | tar -xf - -C "$3"' \
        _ "$remote" "$source" "$checkout"
else
    as_device git clone --quiet --no-local "$remote" "$checkout"
fi
cd "$checkout"
setup=setup_pagalava_iot.sh
unit_user_template='User=${USERNAME}'
unit_script_template='ExecStart=${VENVDIR}/bin/python ${WORKINGDIR}/${SCRIPTNAME}'
if [[ $install_type == image ]]; then
    setup=build_image.sh
    unit_user_template='User=${PAGALAVA_USER}'
    unit_script_template='ExecStart=${VENVDIR}/bin/python ${WORKINGDIR}/ReceiveMessages.py'
elif [[ -f setup_pagalava_iot_debian"$os".sh ]]; then
    setup=setup_pagalava_iot_debian"$os".sh
fi
echo "== Setup $revision on Debian $os using $setup =="
for line in "$unit_user_template" 'WorkingDirectory=${WORKINGDIR}' \
    'Environment="PATH=${VENVDIR}/bin"' "$unit_script_template"; do
    grep -Fx "$line" "$setup"
done
# Render the service from the selected historical setup template. The
# container uses the unit's process settings directly without starting systemd.
unit=/etc/systemd/system/receive_messages.service
sed -n '/^\[Unit\]/,/^WantedBy=/p' "$setup" |
    sed -e 's|${USERNAME}|pagalava|g' -e 's|${GROUPNAME}|pagalava|g' \
        -e 's|${PAGALAVA_USER}|pagalava|g' \
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
    --find-links "/wheels/requirements-$requirements" -r requirements.txt
as_device .venv/bin/python -m pip freeze
service_environment=()
if [[ $install_type == image ]]; then
    as_device git -C "$remote" update-ref refs/heads/release/1.9 "$target"
    as_device /bin/bash -c 'printf "IOT_CONNECTION_STRING=offline-fixture\n" > .env'
else
    as_device git -C "$remote" update-ref refs/heads/main "$target"
    service_environment=(IOT_CONNECTION_STRING=offline-fixture)
fi

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
        PATH="$unit_path" "${service_environment[@]}" \
        RIG_SUDO_POLICY="$policy" PYTHONDONTWRITEBYTECODE=1 \
        "$unit_python" "$@"
}
target_version=$(as_device git --git-dir="$remote" show "${target}:version.json" |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
if [[ $install_type == image ]]; then
    [[ $expected == reflash ]]
    tar -cf /tmp/image-before.tar .
    service /rig/probe.py image "$version"
    tar -df /tmp/image-before.tar
    [[ $(tar -tf /tmp/image-before.tar | wc -l) == $(find . | wc -l) ]]
    echo 'ONWARD requires reflash'
    exit 0
fi
echo "== Historical handler =="
service /rig/probe.py upgrade "$revision" "$source" "$target" "$policy" "$os" "$version" "$expected"
fresh_import() {
    service /rig/probe.py restart "$1"
}
if [[ $expected == stays ]]; then
    fresh_import "$version"
    as_device git pull --ff-only origin main
    [[ $(as_device git rev-parse HEAD) == "$target" ]]
    echo "MANUAL FAST-FORWARD reached $target"
fi
fresh_import "$target_version"
if [[ $revision == 0d02b65 ]]; then
    service /rig/probe.py credential
    baseline=/home/pagalava/baseline
    as_device mkdir "$baseline"
    as_device /bin/bash -c 'git --git-dir="$1" archive 61b7afa | tar -xf - -C "$2"' _ "$remote" "$baseline"
    for version in 1.10 1.9 1.3 2.0; do
        trace=$(service /rig/probe.py relay "$version" | sed -n 's/^RELAY TRACE //p')
        echo "RELAY $version $trace"
        if [[ $version == 1.10 ]]; then
            expected_trace=$trace
        fi
        [[ -n $trace && $trace == "$expected_trace" ]]
    done
    trace=$(cd "$baseline" && service /rig/probe.py relay 1.9 | sed -n 's/^RELAY TRACE //p')
    echo "RELAY 61b7afa $trace"
    [[ $trace == "$expected_trace" ]]
    echo "Activation parity: 1.10, 1.9, 1.3 and 2.0 match 61b7afa"
fi

echo "== Target updater onward hop =="
service /rig/probe.py second_hop "$remote" "$policy" "$target_version" "$revision"

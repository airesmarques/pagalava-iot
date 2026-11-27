#!/bin/bash

# The documented legacy invocation sources this file. Keep failures and shell
# options local to the installer so an abort does not close the login shell.
(
set -e

# Configuration variables
REPO_URL="https://github.com/airesmarques/pagalava-iot"
# When invoked through sudo, install for the user who actually ran it rather
# than for root. Without this, `sudo bash setup_pagalava_iot.sh` — a natural
# thing to type for an install script — installs into /root and leaves the IoT
# service running as root, silently and with nothing to notice on a customer
# site. Deliberately not a hard refusal: a device already installed that way
# must stay repairable by whoever is standing in front of it.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    USERNAME="${SUDO_USER}"
    HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    echo "A correr com sudo: a instalar para o utilizador '${USERNAME}' em ${HOME}"
    echo "(e nao para o root, que era o que acontecia antes)"
elif [ "$(id -u)" -eq 0 ]; then
    # Genuine root login, no sudo. Proceed, but say what will happen, because
    # the result is a service running as root from /root.
    echo "" >&2
    echo "AVISO: estas a correr como root sem sudo." >&2
    echo "       O PagaLava vai ficar instalado em /root e o servico vai correr" >&2
    echo "       como root. Funciona, mas nao e a configuracao recomendada." >&2
    echo "       Para instalar normalmente, sai do root e corre:" >&2
    echo "           bash setup_pagalava_iot.sh" >&2
    echo "" >&2
    USERNAME="root"
else
    USERNAME="${USER}"
fi
GROUPNAME="${USER}"
WORKINGDIR="${HOME}/pagalava-iot"
VENVDIR="${WORKINGDIR}/.venv"
SCRIPTNAME="ReceiveMessages.py"
SERVICENAME="receive_messages.service"

# Keep the archive override local to this install. Raspberry Pi/Raspbian
# repositories and custom APT settings such as signed-by are retained.
install_bullseye_packages() (
    local sources source
    sources=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$sources"' EXIT
    mkdir "$sources/sources.list.d" || exit 1
    : > "$sources/sources.list" || exit 1

    for source in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$source" ] || continue
        # Stock Bullseye uses one-line entries. Also handle deb822 if the
        # operator has converted the source files. Rewrite only Debian mirrors.
        sed -E '/^[[:space:]]*(deb(-src)?[[:space:]]|URIs:[[:space:]])/ {
            s@https?://(deb|security)\.debian\.org/(debian-security|debian)/?([[:space:]]|$)@http://archive.debian.org/\2/\3@g
        }' "$source" > "$sources/${source#/etc/apt/}" || exit 1
    done

    local apt_options=(
        -o "Dir::Etc::sourcelist=$sources/sources.list"
        -o "Dir::Etc::sourceparts=$sources/sources.list.d"
        -o "APT::Get::List-Cleanup=false"
    )
    echo "Updating Bullseye package indexes..."
    sudo apt-get "${apt_options[@]}" update --error-on=any || exit 1
    # GPIO/SPI may need to be compiled on boards without compatible wheels.
    sudo apt-get "${apt_options[@]}" install -y \
        git python3 python3-pip python3-venv python3-dev build-essential
)

. /etc/os-release
if [ "${VERSION_ID:-}" != 11 ]; then
    echo "This installer requires Debian 11 (Bullseye)." >&2
    exit 1
fi
install_bullseye_packages || exit 1

# Prefer a provisioning file dropped on the SD card's boot partition, so an
# installer who downloaded one from the dashboard does not have to paste a
# secret into a terminal.
#
# BACKWARD COMPATIBILITY: when there is no such file this prompts exactly as it
# always has. The legacy procedure in the readme must keep working verbatim.
IOT_CONNECTION_STRING=""
for _bootdir in /boot/firmware /boot; do
    [ -d "$_bootdir" ] || continue
    for _provfile in "$_bootdir"/pagalava-provisioning*.txt; do
        [ -f "$_provfile" ] || continue
        # -f2- because the connection string itself contains '=' characters.
        _found="$(grep -m1 '^IOT_CONNECTION_STRING=' "$_provfile" | cut -d= -f2- | tr -d '"')"
        if [ -n "$_found" ]; then
            IOT_CONNECTION_STRING="$_found"
            echo "A usar o ficheiro de instalacao encontrado em: ${_provfile}"
            break
        fi
    done
    [ -n "$IOT_CONNECTION_STRING" ] && break
done

if [ -z "$IOT_CONNECTION_STRING" ]; then
    echo "Por favor introduz o valor da IOT_CONNECTION_STRING:"
    read -r IOT_CONNECTION_STRING
fi

# Check if the connection string is empty
if [ -z "$IOT_CONNECTION_STRING" ]; then
    echo "IOT_CONNECTION_STRING is required to proceed."
    exit 1
fi

# Export the connection string as an environment variable
export IOT_CONNECTION_STRING

# Clone the repository
echo "Cloning or updating the Pagalava repository..."
#git clone ${REPO_URL} "${WORKINGDIR}" || { echo "Failed to clone repository."; exit 1; }
# Check if the pagalava-iot directory exists
cd "${HOME}"
if [ -d "pagalava-iot" ]; then
    echo "Updating existing pagalava-iot repository..."
    cd pagalava-iot
    # Fetch the latest changes without losing local changes
    git fetch --all
    git reset --hard origin/main
    git pull origin main
else
    echo "Cloning the pagalava-iot repository..."
    # Clone your repository (replace with your repository URL)
    git clone https://github.com/airesmarques/pagalava-iot
    # Navigate into the cloned directory
fi

# Navigate into the cloned directory
cd "${WORKINGDIR}"

# Create a virtual environment
echo "Setting up the virtual environment..."
python3 -m venv "${VENVDIR}"

# Install required Python packages
echo "Installing required Python packages..."
"${VENVDIR}/bin/python" -m pip install -r requirements.txt

# Guardar a connection string num ficheiro .env para persistência
echo "IOT_CONNECTION_STRING=\"${IOT_CONNECTION_STRING}\"" > "${WORKINGDIR}/.env"
chmod 600 "${WORKINGDIR}/.env"  # Restringir permissões por segurança

# Make the main script executable
chmod +x "${SCRIPTNAME}"

# Make auxiliary scripts executable
chmod +x update_pagalava.sh
chmod +x get_journalctl.sh
chmod +x stop_service.sh
chmod +x test.sh
chmod +x diagnosticos.sh 



# Setup the service
echo "Setting up the systemd service..."
SERVICEFILE="/etc/systemd/system/${SERVICENAME}"

cat <<EOF | sudo tee "$SERVICEFILE" >/dev/null
[Unit]
Description=Receive Messages Service
After=network-online.target
Wants=network-online.target

[Service]
User=${USERNAME}
Group=${GROUPNAME}
WorkingDirectory=${WORKINGDIR}
Environment="PATH=${VENVDIR}/bin"
Environment="IOT_CONNECTION_STRING=${IOT_CONNECTION_STRING}"
ExecStart=${VENVDIR}/bin/python ${WORKINGDIR}/${SCRIPTNAME}

# Restart settings
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=300
StartLimitBurst=3


[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICENAME}"
sudo systemctl start "${SERVICENAME}"

# Let the service restart itself after an upgrade. Without this, an upgrade
# replaces the files but the running process keeps the old code, so the device
# reports the OLD version until someone reboots it — which looks exactly like a
# failed upgrade. The image build installs the same rule; this covers manual
# installs so both paths behave alike.
#
# Deliberately narrow: this one command and nothing else. A malformed file in
# /etc/sudoers.d locks EVERYONE out of sudo, so it is validated with visudo
# before being installed, and simply skipped if it does not pass.
SUDOERSTMP="$(mktemp)"
cat > "${SUDOERSTMP}" <<SUDOERS
${USERNAME} ALL=(root) NOPASSWD: /usr/bin/systemctl restart ${SERVICENAME}, /usr/bin/systemctl reboot, /sbin/reboot, /usr/sbin/reboot, /bin/reboot, /bin/true, /usr/bin/true
SUDOERS
if sudo visudo -c -f "${SUDOERSTMP}" >/dev/null 2>&1; then
    sudo install -m 440 -o root -g root "${SUDOERSTMP}" /etc/sudoers.d/pagalava-restart
    echo "Installed /etc/sudoers.d/pagalava-restart - upgrades can restart the service."
else
    echo "WARNING: the generated sudoers rule failed validation; skipping it." >&2
    echo "         Upgrades will apply but need a reboot to take effect." >&2
fi
rm -f "${SUDOERSTMP}"

echo "Service ${SERVICENAME} has been started successfully."
)

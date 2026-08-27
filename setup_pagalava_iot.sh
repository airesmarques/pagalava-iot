#!/bin/bash

# Configuration variables
# Refuse to run as root. The script installs into $HOME and writes a systemd
# unit with User=$(whoami), so `sudo bash setup_pagalava_iot.sh` — a very natural
# thing to type — silently installs into /root and leaves the IoT service running
# as root from root's home directory. Nothing warns, and it is hard to spot on a
# customer site. It still uses sudo internally for the steps that need it.
if [ "$(id -u)" -eq 0 ]; then
    echo "" >&2
    echo "ERRO: nao executes este script como root (nem com sudo)." >&2
    echo "" >&2
    echo "  O script instala em \$HOME e cria o servico com o teu utilizador." >&2
    echo "  Executado como root, instala em /root e o servico corre como root." >&2
    echo "" >&2
    echo "  Executa assim, com o teu utilizador normal:" >&2
    echo "      bash setup_pagalava_iot.sh" >&2
    echo "" >&2
    echo "  (o script pede sudo apenas nos passos que precisam)" >&2
    echo "" >&2
    exit 1
fi
REPO_URL="https://github.com/airesmarques/pagalava-iot"
USERNAME="${USER}"
GROUPNAME="${USER}"
WORKINGDIR="${HOME}/pagalava-iot"
VENVDIR="${WORKINGDIR}/.venv"
SCRIPTNAME="ReceiveMessages.py"
SERVICENAME="receive_messages.service"

# Detect Debian version
DEBIAN_VERSION=$(cat /etc/os-release | grep VERSION_ID | cut -d'"' -f2)
echo "Detected Debian version: ${DEBIAN_VERSION}"

if [ "$DEBIAN_VERSION" -lt 12 ]; then
    echo "This script is intended for Debian 12 (Bookworm) or later."
    echo "For Debian 11 (Bullseye), use setup_pagalava_iot_debian11.sh instead."
    exit 1
fi

# Update and upgrade Raspberry Pi OS
echo "Updating and upgrading Raspberry Pi OS..."
sudo apt-get update && sudo apt-get upgrade -y

# Ensure Raspberry Pi archive repository is configured (required for Debian 12+)
echo "Checking Raspberry Pi repository..."
if ! grep -q "archive.raspberrypi.org" /etc/apt/sources.list.d/*.list 2>/dev/null; then
    echo "Adding Raspberry Pi repository..."
    echo "deb http://archive.raspberrypi.org/debian/ bookworm main" | sudo tee /etc/apt/sources.list.d/raspi.list

    # Add the repository key
    if [ ! -f /usr/share/keyrings/raspberrypi-archive-keyring.gpg ]; then
        wget -qO - https://archive.raspberrypi.org/debian/raspberrypi.gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/raspberrypi-archive-keyring.gpg
        # Update the sources list to use signed-by
        echo "deb [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] http://archive.raspberrypi.org/debian/ bookworm main" | sudo tee /etc/apt/sources.list.d/raspi.list
    fi

    sudo apt-get update
fi

# Install Git, Python3, PIP, and GPIO libraries (Debian 12 specific packages)
echo "Installing Git, Python3, PIP, GPIO libraries, Python Virtual environments..."
sudo apt-get install -y \
    git \
    python3 \
    python3-pip \
    python3-venv \
    python3-rpi.gpio \
    rpi.gpio-common \
    python3-lgpio \
    python3-gpiozero \
    raspberrypi-sys-mods \
    raspi-gpio \
    raspi-config

# Create gpio, spi, i2c groups if they don't exist
echo "Ensuring required groups exist..."
getent group gpio > /dev/null || sudo groupadd gpio
getent group spi > /dev/null || sudo groupadd spi
getent group i2c > /dev/null || sudo groupadd i2c

# Add user to required groups for GPIO/SPI/I2C access
echo "Adding ${USERNAME} to gpio, spi, i2c, dialout groups..."
sudo usermod -aG gpio,spi,i2c,dialout ${USERNAME}

# Enable SPI interface (required for relay modules)
echo "Enabling SPI interface..."
if command -v raspi-config &> /dev/null; then
    sudo raspi-config nonint do_spi 0
else
    # Fallback: manually add to config.txt if raspi-config not available
    CONFIG_FILE="/boot/config.txt"
    if [ -f "/boot/firmware/config.txt" ]; then
        CONFIG_FILE="/boot/firmware/config.txt"
    fi
    if ! grep -q "^dtparam=spi=on" "$CONFIG_FILE"; then
        echo "dtparam=spi=on" | sudo tee -a "$CONFIG_FILE"
    fi
fi

# Reload udev rules to apply GPIO permissions
echo "Reloading udev rules..."
sudo udevadm control --reload-rules
sudo udevadm trigger

# Verify GPIO device permissions
echo "Verifying GPIO device permissions..."
if [ -e /dev/gpiomem ]; then
    ls -la /dev/gpiomem /dev/gpiochip*
else
    echo "Warning: /dev/gpiomem not found. A reboot may be required."
fi

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
echo IOT_CONNECTION_STRING=${IOT_CONNECTION_STRING}

# Clone the repository first (before trying to write .env)
echo "Cloning or updating the Pagalava repository..."
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
    git clone https://github.com/airesmarques/pagalava-iot
fi

# Navigate into the cloned directory
cd "${WORKINGDIR}"

# Save the connection string to .env file for persistence (after directory exists)
echo "IOT_CONNECTION_STRING=\"${IOT_CONNECTION_STRING}\"" > "${WORKINGDIR}/.env"
chmod 600 "${WORKINGDIR}/.env"  # Restrict permissions for security

# Create a virtual environment and activate it
echo "Setting up the virtual environment..."
python3 -m venv "${VENVDIR}"
. "${VENVDIR}/bin/activate"

# Install required Python packages
echo "Installing required Python packages..."
pip install -r requirements.txt
deactivate

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

cat <<EOF | sudo tee "$SERVICEFILE"
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

echo ""
echo "=============================================="
echo "Service ${SERVICENAME} has been started successfully."
echo "=============================================="
echo ""
echo "IMPORTANT: A reboot is recommended to ensure all"
echo "GPIO permissions and kernel modules are loaded correctly."
echo ""
echo "Run: sudo reboot"
echo ""

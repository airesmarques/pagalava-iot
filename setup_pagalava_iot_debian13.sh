#!/bin/bash

# Configuration variables
REPO_URL="https://github.com/airesmarques/pagalava-iot"
USERNAME="pagalava"
GROUPNAME="pagalava"
WORKINGDIR="/home/${USERNAME}/pagalava-iot"
VENVDIR="${WORKINGDIR}/.venv"
SCRIPTNAME="ReceiveMessages.py"
SERVICENAME="receive_messages.service"

# Detect Debian version
DEBIAN_VERSION=$(cat /etc/os-release | grep VERSION_ID | cut -d'"' -f2)
DEBIAN_CODENAME=$(cat /etc/os-release | grep VERSION_CODENAME | cut -d'=' -f2)
echo "Detected Debian version: ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"

if [ "$DEBIAN_VERSION" -lt 12 ]; then
    echo "This script is intended for Debian 12 (Bookworm) or later."
    echo "For Debian 11 (Bullseye), use setup_pagalava_iot_debian11.sh instead."
    exit 1
fi

# Set repo codename (use bookworm for both 12 and 13 if trixie repo not available)
REPO_CODENAME="bookworm"
if [ "$DEBIAN_VERSION" -ge 13 ]; then
    echo ""
    echo "*** DEBIAN 13 (TRIXIE) DETECTED ***"
    echo "Note: Python 3.13 requires system site packages for GPIO libraries."
    echo ""
    REPO_CODENAME="trixie"
fi

# Update and upgrade Raspberry Pi OS
echo "Updating and upgrading Raspberry Pi OS..."
sudo apt-get update && sudo apt-get upgrade -y

# Ensure Raspberry Pi archive repository is configured (required for Debian 12+)
echo "Checking Raspberry Pi repository..."
if ! grep -q "archive.raspberrypi.org" /etc/apt/sources.list.d/*.list 2>/dev/null; then
    echo "Adding Raspberry Pi repository..."
    echo "deb http://archive.raspberrypi.org/debian/ ${REPO_CODENAME} main" | sudo tee /etc/apt/sources.list.d/raspi.list

    # Add the repository key
    if [ ! -f /usr/share/keyrings/raspberrypi-archive-keyring.gpg ]; then
        wget -qO - https://archive.raspberrypi.org/debian/raspberrypi.gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/raspberrypi-archive-keyring.gpg
        # Update the sources list to use signed-by
        echo "deb [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] http://archive.raspberrypi.org/debian/ ${REPO_CODENAME} main" | sudo tee /etc/apt/sources.list.d/raspi.list
    fi

    sudo apt-get update
fi

# Install essential packages first (these must succeed)
echo "Installing essential packages (git, python3, pip, venv)..."
sudo apt-get install -y git python3 python3-pip python3-venv
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to install essential packages. Aborting."
    exit 1
fi

# Install GPIO libraries and Raspberry Pi packages
# Some packages may not exist on all Debian versions, so install them separately
echo "Installing GPIO libraries and Raspberry Pi packages..."

# Core GPIO packages (should exist on both Bookworm and Trixie)
CORE_PACKAGES="python3-rpi.gpio rpi.gpio-common python3-lgpio python3-gpiozero raspberrypi-sys-mods raspi-config"
for pkg in $CORE_PACKAGES; do
    if apt-cache show "$pkg" > /dev/null 2>&1; then
        echo "Installing $pkg..."
        sudo apt-get install -y "$pkg" || echo "Warning: Failed to install $pkg (continuing...)"
    else
        echo "Package $pkg not available in repository (skipping)"
    fi
done

# Optional packages (may not exist on Trixie)
OPTIONAL_PACKAGES="raspi-gpio"
for pkg in $OPTIONAL_PACKAGES; do
    if apt-cache show "$pkg" > /dev/null 2>&1; then
        echo "Installing optional package $pkg..."
        sudo apt-get install -y "$pkg" || echo "Warning: Failed to install $pkg (continuing...)"
    else
        echo "Optional package $pkg not available (skipping - this is OK)"
    fi
done

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

echo "Por favor introduz o valor da IOT_CONNECTION_STRING:"
read -r IOT_CONNECTION_STRING

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
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to clone repository. Aborting."
        exit 1
    fi
fi

# Navigate into the cloned directory
cd "${WORKINGDIR}"
if [ ! -d "${WORKINGDIR}" ]; then
    echo "ERROR: Working directory ${WORKINGDIR} does not exist. Aborting."
    exit 1
fi

# Save the connection string to .env file for persistence (after directory exists)
echo "IOT_CONNECTION_STRING=\"${IOT_CONNECTION_STRING}\"" > "${WORKINGDIR}/.env"
chmod 600 "${WORKINGDIR}/.env"  # Restrict permissions for security

# Create a virtual environment and activate it
echo "Setting up the virtual environment..."
if [ "$DEBIAN_VERSION" -ge 13 ]; then
    # Debian 13+ requires system-site-packages to access GPIO libraries
    # because lgpio/RPi.GPIO pip wheels don't exist for Python 3.13
    echo "Using --system-site-packages for Python 3.13 GPIO compatibility..."
    python3 -m venv --system-site-packages "${VENVDIR}"
else
    python3 -m venv "${VENVDIR}"
fi
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

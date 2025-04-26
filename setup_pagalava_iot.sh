#!/bin/bash

# Configuration variables
REPO_URL="https://github.com/airesmarques/pagalava-iot"
USERNAME="pagalava"
GROUPNAME="pagalava"
WORKINGDIR="/home/${USERNAME}/pagalava-iot"
VENVDIR="${WORKINGDIR}/.venv"
SCRIPTNAME="ReceiveMessages.py"
SERVICENAME="receive_messages.service"

# Update and upgrade Raspberry Pi OS
echo "Updating and upgrading Raspberry Pi OS..."
sudo apt-get update && sudo apt-get upgrade -y

# Install Git, Python3, PIP, and GPIO library
echo "Installing Git, Python3, PIP, GPIO library, Python Virtual environments..."
sudo apt-get install git python3 python3-pip python3-rpi.gpio python3-venv -y

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

# Guardar a connection string num ficheiro .env para persistência
echo "IOT_CONNECTION_STRING=\"${IOT_CONNECTION_STRING}\"" > "${WORKINGDIR}/.env"
chmod 600 "${WORKINGDIR}/.env"  # Restringir permissões por segurança

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

echo "Service ${SERVICENAME} has been started successfully."

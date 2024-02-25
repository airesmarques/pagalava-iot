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

# Clone the repository
echo "Cloning the repository..."
git clone ${REPO_URL} "${WORKINGDIR}" || { echo "Failed to clone repository."; exit 1; }

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
ExecStart=${VENVDIR}/bin/python ${WORKINGDIR}/${SCRIPTNAME}

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICENAME}"
sudo systemctl start "${SERVICENAME}"

echo "Service ${SERVICENAME} has been started successfully."

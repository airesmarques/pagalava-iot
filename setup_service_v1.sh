#!/bin/bash

# Filename: setup_service.sh

# Configuration variables
USERNAME="pagalava"
GROUPNAME="pagalava"
WORKINGDIR="/home/pagalava/pagalava"
VENVDIR="${WORKINGDIR}/.venv"
SCRIPTNAME="ReceiveMessages.py"
SERVICENAME="receive_messages.service"

# Step 1: Create a virtual environment if it doesn't exist
if [ ! -d "$VENVDIR" ]; then
    python3 -m venv "$VENVDIR"
fi

# Step 2: Activate the virtual environment and install dependencies
. "$VENVDIR/bin/activate"
pip install -r "${WORKINGDIR}/requirements.txt"
deactivate

# Step 3: Create or overwrite the systemd service file
SERVICEFILE="/etc/systemd/system/${SERVICENAME}"

# Create or overwrite the service file
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

# Step 4: Reload systemd to read new service file and enable the service
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICENAME}"

# Step 5: Start the service
sudo systemctl start "${SERVICENAME}"

echo "Service ${SERVICENAME} has been started."

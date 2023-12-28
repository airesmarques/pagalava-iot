#!/bin/bash

# Configuration variables
SERVICENAME="receive_messages.service"
SERVICEFILE="/etc/systemd/system/${SERVICENAME}"

# Step 1: Stop the service if it's running
sudo systemctl stop "${SERVICENAME}"

# Step 2: Disable the service to prevent it from starting on boot
sudo systemctl disable "${SERVICENAME}"

# Step 3: Remove the systemd service file
sudo rm -f "$SERVICEFILE"

# Step 4: Reload systemd to remove the service from the system
sudo systemctl daemon-reload
sudo systemctl reset-failed

echo "Service ${SERVICENAME} has been removed."

# Step 5: Countdown before rebooting
echo "System will reboot in:"
for i in {5..1}; do
    echo "$i..."
    sleep 1
done

# Step 6: Reboot the system
echo "Rebooting now."
sudo reboot

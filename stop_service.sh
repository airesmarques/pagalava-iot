#!/bin/bash

# Configuration variables
SERVICENAME="receive_messages.service"
SERVICEFILE="/etc/systemd/system/${SERVICENAME}"

# Step 1: Stop the service if it's running
echo "Stopping ${SERVICENAME}..."
sudo systemctl stop "${SERVICENAME}"

# Check the status of the service
echo "Checking the status of ${SERVICENAME} after stopping..."
sudo systemctl status "${SERVICENAME}"


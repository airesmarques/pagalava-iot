#!/bin/bash

# Script to restart the receive_messages.service

SERVICE_NAME="receive_messages.service"
LOG_FILE="/home/pagalava/restart_receive_messages.log"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

echo "[$TIMESTAMP] Attempting to restart ${SERVICE_NAME}..." >> "${LOG_FILE}"

# Restart the service
sudo systemctl restart "${SERVICE_NAME}"

# Check the status of the service
SERVICE_STATUS=$(systemctl is-active "${SERVICE_NAME}")

if [ "${SERVICE_STATUS}" == "active" ]; then
    echo "[$TIMESTAMP] ${SERVICE_NAME} restarted successfully." >> "${LOG_FILE}"
else
    echo "[$TIMESTAMP] Failed to restart ${SERVICE_NAME}. Please check the service logs." >> "${LOG_FILE}"
fi
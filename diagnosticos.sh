#!/bin/bash
# filepath: /home/pagalava/digipay-iot_src/run_diagnostics.sh

# Colors for terminal output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Diagnostics script
DIAGNOSTIC_SCRIPT="${SCRIPT_DIR}/diagnosticos_pagalava.py"

# Function to display messages
log_info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

log_success() {
    echo -e "${GREEN}SUCCESS:${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

log_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

# Check if diagnostics script exists
if [ ! -f "$DIAGNOSTIC_SCRIPT" ]; then
    log_error "Diagnostics script not found at $DIAGNOSTIC_SCRIPT"
    exit 1
fi

# Find and activate virtual environment
find_and_activate_venv() {
    # Check common virtual environment locations
    VENV_DIRS=(
        "$SCRIPT_DIR/.venv"
        "$SCRIPT_DIR/venv"
        "$SCRIPT_DIR/../.venv"
        "$SCRIPT_DIR/../venv"
        "$HOME/.venv/digipay"
    )

    for VENV_DIR in "${VENV_DIRS[@]}"; do
        ACTIVATE_SCRIPT="${VENV_DIR}/bin/activate"
        if [ -f "$ACTIVATE_SCRIPT" ]; then
            log_info "Found virtual environment at $VENV_DIR"
            source "$ACTIVATE_SCRIPT"
            if [ $? -eq 0 ]; then
                log_success "Virtual environment activated successfully"
                return 0
            else
                log_error "Failed to activate virtual environment"
                return 1
            fi
        fi
    done

    # If we reach here, no virtual environment was found
    log_warning "No virtual environment found in standard locations"
    
    # Check if required packages are available in system Python
    REQUIRED_PACKAGES=("azure-iot-device" "python-dotenv" "requests")
    MISSING_PACKAGES=()
    
    for PACKAGE in "${REQUIRED_PACKAGES[@]}"; do
        if ! python3 -c "import ${PACKAGE//-/.}" &>/dev/null; then
            MISSING_PACKAGES+=("$PACKAGE")
        fi
    done
    
    if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
        log_error "Missing required Python packages: ${MISSING_PACKAGES[*]}"
        read -p "Would you like to install the missing packages? (y/N): " INSTALL_CHOICE
        if [[ "$INSTALL_CHOICE" =~ ^[Yy]$ ]]; then
            log_info "Installing missing packages..."
            pip3 install --user "${MISSING_PACKAGES[@]}"
            if [ $? -ne 0 ]; then
                log_error "Failed to install packages"
                return 1
            fi
            log_success "Packages installed successfully"
        else
            log_warning "Proceeding without installing missing packages. Diagnostics may fail."
        fi
    fi
    
    # Even if no venv is found, we'll try to run with system Python
    log_warning "Using system Python instead of a virtual environment"
    return 0
}

# Check if Python 3 is available
if ! command -v python3 &> /dev/null; then
    log_error "Python 3 is not installed or not in PATH"
    exit 1
fi

# Make diagnostics script executable
chmod +x "$DIAGNOSTIC_SCRIPT"

# Find and activate the virtual environment
find_and_activate_venv

# Check if the diagnostic script exists and is executable
if [ ! -x "$DIAGNOSTIC_SCRIPT" ]; then
    log_warning "Setting execute permissions on diagnostic script"
    chmod +x "$DIAGNOSTIC_SCRIPT"
fi

# Run the diagnostic script and pass all arguments
log_info "A executar o Diagnóstico do Dispositivo IoT..."
python3 "$DIAGNOSTIC_SCRIPT" "$@"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    log_success "Diagnóstico concluído com sucesso"
else
    log_warning "Diagnóstico concluído com problemas (código de saída: $EXIT_CODE)"
fi

# Deactivate virtual environment if it was activated
if command -v deactivate &> /dev/null; then
    deactivate
fi

# Instead of exiting, just return the exit code if script is being sourced
# This prevents SSH sessions from closing when the script is run
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Script is being sourced, so return instead of exit
    return $EXIT_CODE 2>/dev/null || true
else
    # Only show final message, don't exit
    log_info "Diagnóstico completo. Pode continuar a utilizar o terminal."
fi

# Remove the exit command to keep the shell open
# exit $EXIT_CODE
#!/bin/bash

# Define the path to the virtual environment and the Python script
VENVDIR="/path/to/your/.venv"  # Update this path accordingly
PYTHONSCRIPT="test_script.py"

echo "Escolhe o modulo a testar:"
#echo "1. Module 1"
echo "2. Module 2"
read -p "Introduz a escolha (por enquanto apenas 2): " choice

# Activate the virtual environment
source "$VENVDIR/bin/activate"

if [ "$choice" = "1" ] || [ "$choice" = "2" ]; then
    # Run the Python script using the Python executable from the virtual environment
    python "$PYTHONSCRIPT" "$choice"
else
    echo "Invalid choice. Please run the script again and choose either 1 or 2."
    # Deactivate the virtual environment before exiting
    deactivate
    exit 1
fi

# Deactivate the virtual environment after the script finishes
deactivate

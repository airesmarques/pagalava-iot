#!/bin/bash

# Define the path to the virtual environment and the Python script
VENVDIR="/path/to/your/.venv"  # Update this path accordingly
PYTHONSCRIPT="test_script.py"

echo "Escolhe o modulo a testar:"
echo "m1. Module 1"
echo "m2. Module 2"
echo "ma. Module 1 and 2"
read -p "Introduz a escolha: " choice

# Activate the virtual environment
source "$VENVDIR/bin/activate"

if [ "$choice" = "m1" ] || [ "$choice" = "m2" ] || [ "$choice" = "ma" ]; then
    # Run the Python script using the Python executable from the virtual environment
    python "$PYTHONSCRIPT" "$choice"
else
    echo "Invalid choice. Please run the script again and choose either m1, m2, ma."
    # Deactivate the virtual environment before exiting
    deactivate
    exit 1
fi

# Deactivate the virtual environment after the script finishes
deactivate

"""
Filename: relay_ops.py
"""

import RPi.GPIO as GPIO
import time
import json

# Custom Exception
class MachineNotConfiguredException(Exception):
    """Exception raised when a machine is not configured in the relay mapping."""
    def __init__(self, machine_id, message="Machine ID is not configured in the relay mapping."):
        self.machine_id = machine_id
        self.message = f"{message} Machine ID: {machine_id}"
        super().__init__(self.message)


ACTIVATION_TIME_INTERVAL: int = 2
ACTIVATION_TIME_DURATION: int = 2

relay_to_gpio_map = {
    # Module 1 - WASH
    1: 22,  # WASH
    2: 23,  # WASH
    3: 24,  # WASH
    4: 25,  # WASH
    6: 27,  # WASH
    8: 18,  # WASH
    # Module 2 - DRY
    9: 12,
    10: 16,
    11: 20,
    12: 21,
    13: 17,
    14: 13,
    15: 19,
    16: 26
}

used_gpio = list(relay_to_gpio_map.values())

GPIO.setmode(GPIO.BCM)  # Use BCM GPIO numbering
GPIO.setup(used_gpio, GPIO.OUT, initial=GPIO.HIGH)

# Load the relay mapping once at the start of the program
relay_mapping_data = {}


def load_relay_mapping(file_path='config.json'):
    """
    Loads relay mapping from a JSON configuration file and converts it into a dictionary with integer keys and values.

    :param file_path: The path to the configuration JSON file.
    :return: A dictionary with integer keys and values representing the relay mapping.
    """
    try:
        with open(file_path, 'r') as file:
            config = json.load(file)
            # Convert keys and values to integers
            relay_mapping = {int(key): int(value) for key, value in config.items()}
            return relay_mapping
    except FileNotFoundError:
        print(f"File not found: {file_path}")
        return {}
    except json.JSONDecodeError:
        print(f"Error decoding JSON from file: {file_path}")
        return {}
    except ValueError:
        print("Invalid format in config.json. Keys and values must be convertible to integers.")
        return {}


# Load relay mapping at the beginning
relay_mapping_data = load_relay_mapping()


def get_relay_number(
    machine_id: int,
    mapping=relay_mapping_data):
    """
    Retrieves the relay number for a given machine number using the relay mapping.

    :param machine_id: The machine ID for which to retrieve the relay number.
    :param mapping: The preloaded relay mapping.
    :return: The relay number corresponding to the given machine ID, or None if not found.
    """
    return mapping.get(machine_id, None)


# Function to control a relay
def control_relay(
    relay_number: int,
    state):
    gpio = relay_to_gpio_map[relay_number]
    
    log_str = f"Relay number: {relay_number} - GPIO: {gpio} - State: {state}"
    print(log_str)
    
    GPIO.output(gpio, state)

    # GPIO.cleanup()


def activate_machine(
    machine_id: int,
    number_of_impulses: int = 1):
    """
    Activates a machine by controlling its relay.

    :param machine_id: The ID of the machine to activate.
    :param number_of_impulses: Number of times to activate the machine.
    :raises MachineNotConfiguredException: If the machine_id is not found in the relay mapping.
    """
    relay_number = get_relay_number(machine_id)
    
    if relay_number is None:
        raise MachineNotConfiguredException(machine_id)
    
    for i in range(number_of_impulses):
        # Activate the machine by setting the relay to the energized state (low)
        control_relay(relay_number, GPIO.LOW)
        # Deactivate after 2 seconds
        time.sleep(ACTIVATION_TIME_DURATION)
        control_relay(relay_number, GPIO.HIGH)
        time.sleep(ACTIVATION_TIME_INTERVAL)


#
# Test functions
#


def test_all(speed: int = 1):
    for relay_label in relay_to_gpio_map:
        print(f"Testing {relay_label}")
        # Turn on the relay
        control_relay(relay_label, GPIO.LOW)
        time.sleep(ACTIVATION_TIME_DURATION / speed)
        # Turn off the relay
        control_relay(relay_label, GPIO.HIGH)
        time.sleep(ACTIVATION_TIME_INTERVAL / speed)


# Test module 1
def test_module_1(speed: int=1):
    # List of relays in Module 1
    module_1_relays = [1, 2, 3, 4, 6, 8]

    for relay_label in module_1_relays:
        print(f"Testing {relay_label} in Module 1")
        # Turn on the relay
        control_relay(relay_label, GPIO.LOW)
        time.sleep(ACTIVATION_TIME_DURATION / speed)
        # Turn off the relay
        control_relay(relay_label, GPIO.HIGH)
        time.sleep(ACTIVATION_TIME_INTERVAL / speed)


def test_module_2(speed: int = 1):
    # List of relays in Module 2
    module_2_relays = [9, 10, 11, 12, 13, 14, 15, 16]

    for relay_label in module_2_relays:
        print(f"Testing {relay_label} in Module 2")
        # Turn on the relay
        control_relay(relay_label, GPIO.LOW)
        time.sleep(ACTIVATION_TIME_DURATION / speed)
        # Turn off the relay
        control_relay(relay_label, GPIO.HIGH)
        time.sleep(ACTIVATION_TIME_INTERVAL / speed)

    
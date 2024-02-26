import RPi.GPIO as GPIO
import time
import json

# Define a dictionary to map relay labels to GPIO pins

# relay_mapping_v0 = {
#     7: 9,
#     8: 10,
#     9: 11,
#     10: 12,
#     11: 13,
#     12: 14,
#     13: 15,
#     14: 16
# }

used_pins = [9, 10, 11, 12, 13, 14, 15, 16, 17, 19, 20, 21, 26]

# L2 - Avenida 
# Maps 
# Relay : Pin
relay_pins_v0 = {
    # Module 1 - WASH
    1: 22,  #WASH
    2: 23,  #WASH
    3: 24,  #WASH
    4: 25,  #WASH
    5: 26,  #WASH
    6: 27,  #WASH
    7: 17,  #WASH
    8: 18,  #WASH
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


GPIO.setmode(GPIO.BCM)  # Use BCM GPIO numbering
GPIO.setup(used_pins, GPIO.OUT, initial=GPIO.HIGH)


def relay_mapping(
    file_path='config.json'):
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

def get_relay_number(
    machine_id : int,
    file_path='config.json'):
    """
    Retrieves the relay number for a given machine number using the relay mapping from a JSON configuration file.

    :param machine_number: The machine number for which to retrieve the relay number.
    :param file_path: The path to the configuration JSON file.
    :return: The relay number corresponding to the given machine number, or None if not found.
    """
    mapping = relay_mapping(file_path)
    return mapping.get(machine_id, None)


# Function to control a relay
def control_relay(
    relay_number: int,
    state):

    pin = relay_pins_v0[relay_number]
    print("preparing for",relay_number, pin)
    GPIO.output(pin, state)

    #GPIO.cleanup()


def activate_machine(
    machine_id: int,
    number_of_impulses: int = 1):
    # Setup GPIO
    
    relay_number = get_relay_number(machine_id)
    
    for i in range(number_of_impulses):   
        # Activate the machine by setting the relay to the energized state (low)
        control_relay(relay_number, GPIO.LOW)
        # Deactivate after 2 seconds
        time.sleep(1)
        control_relay(relay_number, GPIO.HIGH)
        time.sleep(1)



#
# Test functions
#


def test_all():
    for relay_label in relay_pins_v0:
        print(f"Testing {relay_label}")
        # Turn on the relay
        control_relay(relay_label, GPIO.LOW)
        time.sleep(1)
        # Turn off the relay
        control_relay(relay_label, GPIO.HIGH)
        time.sleep(1)


# Test module 1


def test_module_2():
    # List of relays in Module 2
    module_2_relays = [9, 10, 11, 12, 13, 14, 15, 16]

    for relay_label in module_2_relays:
        print(f"Testing {relay_label} in Module 2")
        # Turn on the relay
        control_relay(relay_label, GPIO.LOW)
        time.sleep(1)
        # Turn off the relay
        control_relay(relay_label, GPIO.HIGH)
        time.sleep(1)

import RPi.GPIO as GPIO
import time

# Define a dictionary to map relay labels to GPIO pins

relay_mapping_v0 = {
    "07": "R9",
    "08": "R10",
    "09": "R11",
    "10": "R12",
    "11": "R13",
    "12": "R14",
    "13": "R15",
    "14": "R16"
}


# L2 - Avenida 
relay_pins_v0 = {
    "R1": 22,  #WASH
    "R2": 23,  #WASH
    "R3": 24,  #WASH
    "R4": 25,  #WASH
    "R5": 26,  #WASH
    "R6": 27,  #WASH
    "R7": 17,  #WASH
    "R8": 18,  #WASH
    # Module 2 - DRY
    "R9": 12,
    "R10": 16,
    "R11": 20,
    "R12": 21,
    # Module 3 - DRY
    "R13": 17,
    "R14": 13,
    "R15": 19,
    "R16": 26
}

# Laundry 101 
# TODO


'''
Module 1
11
12
13
14
15
16
17
18
Module 2
21
22
23
24
Module 3
31
32
33
34
'''



GPIO.setmode(GPIO.BCM)  # Use BCM GPIO numbering
GPIO.setup(list(relay_pins_v0.values()), GPIO.OUT, initial=GPIO.HIGH)


# Function to control a relay
def control_relay(relay_label, state):

    pin = relay_pins_v0[relay_label]
    print("preparing for",relay_label, pin)
    GPIO.output(pin, state)

    #GPIO.cleanup()


def activate_machine(
    machine_id: str,
    number_of_impulses: int = 1):
    # Setup GPIO
    
    relay_pin = relay_mapping_v0.get(machine_id)
    
    for i in range(number_of_impulses):   
        # Activate the machine by setting the relay to the energized state (low)
        control_relay(relay_pin, GPIO.LOW)

        # Deactivate after 2 seconds
        time.sleep(1)
        control_relay(relay_pin, GPIO.HIGH)
        time.sleep(1)



#
# Test functions
#


def test_all():
    for relay_label in relay_pins_v0:
        print(f"Testing {relay_label}")
        # Turn on the relay
        control_relay(relay_label, GPIO.LOW)
        # Turn off the relay
        control_relay(relay_label, GPIO.HIGH)


# Test module 1


def test_module_2():
    # List of relays in Module 2
    module_2_relays = ["R9", "R10", "R11", "R12", "R13", "R14", "R15", "R16"]

    for relay_label in module_2_relays:
        print(f"Testing {relay_label} in Module 2")
        # Turn on the relay
        control_relay(relay_label, GPIO.LOW)
        # Turn off the relay
        control_relay(relay_label, GPIO.HIGH)

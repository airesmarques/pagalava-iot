import RPi.GPIO as GPIO
import time

# Define a dictionary to map relay labels to GPIO pins

relay_mapping_v0 = {
    7: 9,
    8: 10,
    9: 11,
    10: 12,
    11: 13,
    12: 14,
    13: 15,
    14: 16
}


# L2 - Avenida 
# Maps 
# Relay : Pin
relay_pins_v0 = {
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
    # Module 3 - DRY
    13: 17,
    14: 13,
    15: 19,
    16: 26
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
    machine_id: int,
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

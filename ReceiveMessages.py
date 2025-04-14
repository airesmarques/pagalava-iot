"""
Filename: ReceiveMessages.py
"""
import logging
import os
import time
import json

from dotenv import load_dotenv
from azure.iot.device import IoTHubDeviceClient

import relay_ops
from relay_ops import MachineNotConfiguredException  # Import the custom exception

# Load environment variables from .env file
load_dotenv()

# Configure logging with timestamp and log level
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

VERSION = "1.2"
#VERSION = "1.1.0"
#VERSION = "1.0"
RECEIVED_MESSAGES = 0

# Retrieve the IoT Hub connection string from environment variables
IOT_CONNECTION_STRING = os.getenv("IOT_CONNECTION_STRING")
if not IOT_CONNECTION_STRING:
    logging.error("IOT_CONNECTION_STRING not found in environment variables.")
    exit(1)
print("Connection String: %s...%s" % (IOT_CONNECTION_STRING[:5], IOT_CONNECTION_STRING[-5:]))  # Partially display for security

def message_configure(config_data: dict):
    func_name = "message_configure"
    logging.info("%s: %s", func_name, config_data)

    # Save the configuration file
    try:
        with open('config.json', 'w') as f:
            json.dump(config_data, f, indent=4)
        logging.info("%s: Configuration saved successfully.", func_name)
    except Exception as e:
        logging.error("%s: Failed to save configuration - %s", func_name, e)

def message_wake_up():
    func_name = "message_wake_up"
    logging.info("%s: Wake up signal received.", func_name)

def message_activate(json_data: dict):
    func_name = "message_activate"
    try:
        intent_id = json_data.get('payment_intent_id') or json_data.get('intent_id')
        machine_id = json_data['machine_id']
        if isinstance(machine_id, str):
            machine_id = int(machine_id)
        number_of_impulses = json_data['number_of_impulses']
        
        logging.info(
            "%s: Activating intent_id=%s machine_id=%s, impulses=%s",
            func_name, intent_id, machine_id, number_of_impulses
        )
        
        # Use version-appropriate activation function
        if VERSION.startswith("1.0"):
            logging.info("%s: Using v1.0 activation method", func_name)
            relay_ops.activate_machine_v1_0(
                machine_id=machine_id,
                number_of_impulses=number_of_impulses
            )
        elif VERSION.startswith("1.1"):
            logging.info("%s: Using v1.1 activation method", func_name)
            relay_ops.activate_machine_v1_1(
                machine_id=machine_id,
                number_of_impulses=number_of_impulses
            )
        elif VERSION.startswith("1.2"):
            logging.info("%s: Using v1.2 activation method", func_name)
            # Don't pass interval_between_impulses_ms as it comes from config, not the message
            relay_ops.activate_machine_v1_2(
                machine_id=machine_id,
                number_of_impulses=number_of_impulses
            )
        else:
            logging.warning("%s: Unknown version %s, defaulting to v1.2 activation", func_name, VERSION)
            relay_ops.activate_machine_v1_2(
                machine_id=machine_id,
                number_of_impulses=number_of_impulses
            )
            
        logging.info("%s: Activation successful for machine_id=%s", func_name, machine_id)
        
    except MachineNotConfiguredException as e:
        logging.error("%s: %s", func_name, e)
    except KeyError as e:
        logging.error("%s: Missing key in JSON data - %s", func_name, e)
    except ValueError as e:
        logging.error("%s: Invalid data format - %s", func_name, e)
    except Exception as e:
        logging.error("%s: Unexpected error - %s", func_name, e)

def message_reboot():
    func_name = "message_reboot"
    logging.info("%s: Reboot command received.", func_name)
    # Implement reboot logic here

def message_upgrade():
    func_name = "message_upgrade"
    logging.info("%s: Upgrade command received.", func_name)
    # Implement upgrade logic here

def message_version():
    func_name = "message_version"
    logging.info("%s: Version command received", func_name)

def message_handler(message):
    global RECEIVED_MESSAGES
    RECEIVED_MESSAGES += 1
    start_time = time.time()
    logging.info("Message received:")

    # Log data from both system and application (custom) properties
    for key, value in vars(message).items():
        logging.info("    %s: %s", key, value)
    
    try:
        # Convert byte string to regular string
        str_data = message.data.decode('utf-8')

        # Parse the string as JSON
        json_data = json.loads(str_data)
    except json.JSONDecodeError as e:
        logging.error("message_handler: Failed to decode JSON - %s", e)
        return
    except AttributeError as e:
        logging.error("message_handler: Invalid message format - %s", e)
        return

    # Extract the message type
    msg_type = json_data.get('msg_type')
    if not msg_type:
        logging.error("message_handler: 'msg_type' not found in the message.")
        return

    # Route the message to the appropriate handler
    if msg_type == 'configure':
        message_configure(json_data.get('data', {}))
    elif msg_type == 'wake_up':
        message_wake_up()
    elif msg_type == 'activate':
        message_activate(json_data)
    elif msg_type == 'reboot':
        message_reboot()
    elif msg_type == 'upgrade':
        message_upgrade()
    elif msg_type == 'version':
        message_version()
    else:
        logging.warning("message_handler: Unknown message type '%s'", msg_type)
    
    logging.info("Total messages received: %s", RECEIVED_MESSAGES)
    logging.info("Processing time: %.2f seconds", time.time() - start_time)

def main():
    logging.info("Starting the Python IoT Hub C2D Messaging device sample...")

    try:
        # Instantiate the IoT Hub client
        client = IoTHubDeviceClient.create_from_connection_string(IOT_CONNECTION_STRING)
        logging.info("IoT Hub client instantiated successfully.")

        logging.info("Waiting for C2D messages. Press Ctrl-C to exit.")
        # Attach the message handler to the client
        client.on_message_received = message_handler

        # Keep the script running to listen for messages
        while True:
            time.sleep(1000)
    except KeyboardInterrupt:
        logging.info("IoT Hub C2D Messaging device sample stopped by user.")
    except Exception as e:
        logging.error("main: Unexpected error - %s", e)
    finally:
        # Gracefully shutdown the IoT Hub client
        try:
            client.shutdown()
            logging.info("IoT Hub client shut down successfully.")
        except Exception as e:
            logging.error("main: Error during client shutdown - %s", e)

if __name__ == '__main__':
    main()
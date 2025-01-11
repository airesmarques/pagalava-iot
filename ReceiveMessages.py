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

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

RECEIVED_MESSAGES = 0

# Retrieve the IoT Hub connection string from environment variables
IOT_CONNECTION_STRING = os.getenv("IOT_CONNECTION_STRING")
if not IOT_CONNECTION_STRING:
    logging.error("IOT_CONNECTION_STRING not found in environment variables.")
    exit(1)
print(f"Connection String: {IOT_CONNECTION_STRING[:5]}...{IOT_CONNECTION_STRING[-5:]}")  # Partially display for security

def message_configure(config_data: dict):
    func_name = "message_configure"
    logging.info(f"{func_name}: {config_data}")

    # Save the configuration file
    try:
        with open('config.json', 'w') as f:
            json.dump(config_data, f, indent=4)
        logging.info(f"{func_name}: Configuration saved successfully.")
    except Exception as e:
        logging.error(f"{func_name}: Failed to save configuration - {e}")

def message_wake_up():
    func_name = "message_wake_up"
    logging.info(f"{func_name}: Wake up signal received.")

def message_activate(json_data: dict):
    func_name = "message_activate"
    try:
        intent_id = json_data.get('payment_intent_id') or json_data.get('intent_id')
        machine_id = json_data['machine_id']
        if isinstance(machine_id, str):
            machine_id = int(machine_id)
        number_of_impulses = json_data['number_of_impulses']
        
        logging.info(
            f"{func_name}: Activating intent_id={intent_id} machine_id={machine_id},  impulses={number_of_impulses}")
        
        relay_ops.activate_machine(
            machine_id=machine_id,
            number_of_impulses=number_of_impulses
        )
        logging.info(f"{func_name}: Activation successful for machine_id={machine_id}")
        
    except MachineNotConfiguredException as e:
        logging.error(f"{func_name}: {e}")
    except KeyError as e:
        logging.error(f"{func_name}: Missing key in JSON data - {e}")
    except ValueError as e:
        logging.error(f"{func_name}: Invalid data format - {e}")
    except Exception as e:
        logging.error(f"{func_name}: Unexpected error - {e}")

def message_reboot():
    func_name = "message_reboot"
    logging.info(f"{func_name}: Reboot command received.")
    # Implement reboot logic here

def message_upgrade():
    func_name = "message_upgrade"
    logging.info(f"{func_name}: Upgrade command received.")
    # Implement upgrade logic here

def message_handler(message):
    global RECEIVED_MESSAGES
    RECEIVED_MESSAGES += 1
    start_time = time.time()
    print("")
    print("Message received:")

    # print data from both system and application (custom) properties
    for property in vars(message).items():
        print ("    {}".format(property))
    
    try:
        # Convert byte string to regular string
        str_data = message.data.decode('utf-8')

        # Parse the string as JSON
        json_data = json.loads(str_data)
    except json.JSONDecodeError as e:
        logging.error(f"message_handler: Failed to decode JSON - {e}")
        return
    except AttributeError as e:
        logging.error(f"message_handler: Invalid message format - {e}")
        return

    # Extract the message type
    msg_type = json_data.get('msg_type')
    if not msg_type:
        logging.error("message_handler: 'msg_type' not found in the message.")
        return

    # Route the message to the appropriate handler
    if msg_type == 'configure':
        message_configure(json_data.get('data'))
    if msg_type == 'wake_up':
        message_wake_up()
    elif msg_type == 'activate':
        message_activate(json_data)
    elif msg_type == 'reboot':
        message_reboot()
    elif msg_type == 'upgrade':
        message_upgrade()
    else:
        logging.warning(f"message_handler: Unknown message type '{msg_type}'")
    
    logging.info(f"Total messages received: {RECEIVED_MESSAGES}")
    logging.info(f"Processing time: {time.time() - start_time:.2f} seconds")

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
        logging.error(f"main: Unexpected error - {e}")
    finally:
        # Gracefully shutdown the IoT Hub client
        try:
            client.shutdown()
            logging.info("IoT Hub client shut down successfully.")
        except Exception as e:
            logging.error(f"main: Error during client shutdown - {e}")

if __name__ == '__main__':
    main()
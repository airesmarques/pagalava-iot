import logging
import os
import time
import json

from dotenv import load_dotenv

from azure.iot.device import IoTHubDeviceClient

import relay_ops

load_dotenv()

logging.basicConfig(level=logging.INFO)



RECEIVED_MESSAGES = 0

IOT_CONNECTION_STRING = os.getenv("IOT_CONNECTION_STRING")
print(f"{IOT_CONNECTION_STRING[:5]}...{IOT_CONNECTION_STRING[-5:]}")


def message_configure(config_data: dict):
    func_name = "message_configure"
    logging.info(f"{func_name}: {config_data}")

    # now save the configuration file
    with open('config.json', 'w') as f:
        json.dump(config_data, f, indent=4)
    

def message_wake_up():
    func_name = "message_wake_up"
    logging.info(f"{func_name}")


def message_activate(json_data: dict):

    machine_id = json_data['machine_id']
    if isinstance(machine_id, str):
        machine_id = int(machine_id)
    number_of_impulses = json_data['number_of_impulses']
    relay_ops.activate_machine(
        machine_id=machine_id,
        number_of_impulses=number_of_impulses
    )
    


def message_handler(message):
    global RECEIVED_MESSAGES
    RECEIVED_MESSAGES += 1
    print("")
    print("Message received:")

    # print data from both system and application (custom) properties
    for property in vars(message).items():
        print ("    {}".format(property))
    
    # Convert byte string to regular string
    str_data = message.data.decode('utf-8')

    # Parse the string as JSON
    json_data = json.loads(str_data)

    # Extract the machine_id value
    msg_type = json_data['msg_type']
    if msg_type == 'configure':
        message_configure(json_data.get('data'))
    if msg_type == 'wake_up':
        message_wake_up()
    elif msg_type == 'activate':
        message_activate(json_data)
    else:
        print("Unknown message type")
    
 
    print("Total calls received: {}".format(RECEIVED_MESSAGES))
    
def main():
    print ("Starting the Python IoT Hub C2D Messaging device sample...")

    # Instantiate the client
    client = IoTHubDeviceClient.create_from_IOT_connection_string(IOT_CONNECTION_STRING)

    print ("Waiting for C2D messages, press Ctrl-C to exit")
    try:
        # Attach the handler to the client
        client.on_message_received = message_handler

        while True:
            time.sleep(1000)
    except KeyboardInterrupt:
        print("IoT Hub C2D Messaging device sample stopped")
    finally:
        # Graceful exit
        print("Shutting down IoT Hub Client")
        client.shutdown()
        
if __name__ == '__main__':
    main()
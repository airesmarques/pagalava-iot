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

CONNECTION_STRING = os.getenv("CONNECTION_STRING")
print(f"{CONNECTION_STRING[:5]}...{CONNECTION_STRING[-5:]}")


def message_router():
    # CreateUpdate Configuration
    # ...
    
    # Activation message
    # ...
    pass


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
    machine_id = json_data['machine_id']
    
    relay_ops.activate_machine(machine_id)
    
    print("Total calls received: {}".format(RECEIVED_MESSAGES))
    
def main():
    print ("Starting the Python IoT Hub C2D Messaging device sample...")

    # Instantiate the client
    client = IoTHubDeviceClient.create_from_connection_string(CONNECTION_STRING)

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
"""
Filename: ReceiveMessages.py
"""
import logging
import os
import time
import json
import re
import requests
import subprocess
import socket

from dotenv import load_dotenv
from azure.iot.device import IoTHubDeviceClient

import relay_ops
import diagnostics_report
from minute_token import generate_minute_token
from relay_ops import MachineNotConfiguredException  # Import the custom exception

# Load environment variables from .env file.
# override=True makes the .env file authoritative even when the systemd unit
# also sets IOT_CONNECTION_STRING, so switching .env (e.g. via env_manager.py)
# reliably takes effect after a service restart.
load_dotenv(override=True)

# Configure logging with timestamp and log level
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

# Read version from external file
def get_version():
    """Read version information from the external version.json file"""
    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        version_file_path = os.path.join(script_dir, "version.json")
        
        if os.path.exists(version_file_path):
            with open(version_file_path, 'r') as file:
                version_data = json.load(file)
                return version_data.get('version', '1.0')
        else:
            logging.warning("Version file not found at %s, using default version", version_file_path)
            return '1.0'  # Default version if file not found
    except Exception as e:
        logging.error("Failed to read version file: %s", str(e))
        return '1.0'  # Default version if there's an error

VERSION = get_version()
logging.info("Running with version: %s", VERSION)

RECEIVED_MESSAGES = 0

# Retrieve the IoT Hub connection string from environment variables
IOT_CONNECTION_STRING = os.getenv("IOT_CONNECTION_STRING")
if not IOT_CONNECTION_STRING:
    logging.error("IOT_CONNECTION_STRING not found in environment variables.")
    exit(1)
print("Connection String: %s...%s" % (IOT_CONNECTION_STRING[:5], IOT_CONNECTION_STRING[-5:]))  # Partially display for security

# Extract device ID from connection string
def get_device_id():
    """Extract the device ID from the IoT Hub connection string."""
    match = re.search(r'DeviceId=([^;]+)', IOT_CONNECTION_STRING)
    if match:
        return match.group(1)
    return "unknown_device"

DEVICE_ID = get_device_id()

def determine_environment():
    """Determine if this is a dev or prod environment from the connection string."""
    # Extract the hostname from the connection string
    match = re.search(r'HostName=([^;]+)', IOT_CONNECTION_STRING)
    if match:
        hostname = match.group(1)
        # Check specifically for "IoTHub-dev" in the hostname
        # instead of just "-dev" anywhere in the connection string
        if "IoTHub-dev" in hostname:
            return {
                "env": "dev",
                "url": "digipay2-dashboard-dev.azurewebsites.net"
            }
    
    # Default to production if no dev indicator found or hostname couldn't be parsed
    return {
        "env": "prod",
        "url": "digipay2-dashboard.azurewebsites.net"
    }

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

CONFIG_FILE = "config.json"


def config_is_missing() -> bool:
    """
    True when this device has no machine-to-relay map.

    A Pi installed from the golden image starts out this way: config.json is
    gitignored and never ships in the image, so until the cloud sends one every
    activation raises MachineNotConfiguredException.
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))
    return not os.path.exists(os.path.join(script_dir, CONFIG_FILE))


def request_configuration() -> bool:
    """
    Ask the backend to send this device its machine-to-relay configuration.

    The configuration does not come back in the HTTP response — the backend
    pushes it over IoT Hub as a normal 'configure' message, which
    message_configure() then writes to config.json. This call only asks.

    Safe to call more than once: the backend ignores repeat requests for the
    same laundry within a minute and answers 429.

    :return: True if the backend accepted the request.
    """
    func_name = "request_configuration"
    env_info = determine_environment()
    url = f"https://{env_info['url']}/api/laundries/iot/request_configuration"
    payload = {
        "device_id": DEVICE_ID,
        "token": generate_minute_token(DEVICE_ID),
    }

    try:
        response = requests.post(
            url,
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=15,
        )
        if response.status_code in (200, 202):
            logging.info("%s: Configuration requested successfully", func_name)
            return True
        if response.status_code == 429:
            logging.info(
                "%s: Configuration was already requested recently, waiting for it",
                func_name,
            )
            return True
        logging.error(
            "%s: Backend refused the request - HTTP %s %s",
            func_name, response.status_code, response.text[:200],
        )
        return False
    except requests.exceptions.RequestException as e:
        # Not fatal: the device keeps running and will ask again on the next
        # activation that finds no configuration.
        logging.error("%s: Could not reach the backend - %s", func_name, e)
        return False


def request_configuration_if_missing() -> None:
    """Ask for configuration at startup, but only if this device has none."""
    if config_is_missing():
        logging.warning(
            "request_configuration_if_missing: No %s on this device - requesting one",
            CONFIG_FILE,
        )
        request_configuration()
    else:
        logging.info(
            "request_configuration_if_missing: %s present, nothing to request",
            CONFIG_FILE,
        )


def message_test_relay(json_data: dict):
    """
    Click relays directly, for bench-testing a freshly assembled board.

    This is the only path that addresses relays rather than machines. Every
    other activation goes through config.json, which maps machine -> relay; a
    board being assembled has no machines yet, and the installer needs to check
    all sixteen relays regardless of how many machines will eventually use
    them.

    relay_to_gpio_map lives in relay_ops, so this works on a device whose
    configuration has never been sent.

    Accepts either:
        {"msg_type": "test_relay", "relay_number": 9}
        {"msg_type": "test_relay", "module": "1" | "2" | "all"}

    Optional "duration_s" shortens or lengthens each click. The default is
    deliberately shorter than a real activation, so a connected machine is not
    started by a wiring check.
    """
    func_name = "message_test_relay"

    duration = json_data.get("duration_s", 1.0)
    try:
        duration = float(duration)
    except (TypeError, ValueError):
        duration = 1.0
    # Bounded: a stuck-closed relay energises whatever is wired to it.
    duration = max(0.1, min(duration, 3.0))

    relay_number = json_data.get("relay_number")
    module = json_data.get("module")

    try:
        if relay_number is not None:
            relay_number = int(relay_number)
            logging.info("%s: pulsing relay %s for %ss", func_name, relay_number, duration)
            relay_ops.pulse_relay(relay_number, duration)
            logging.info("%s: relay %s done", func_name, relay_number)
            return

        if module is not None:
            module = str(module).lower()
            if module == "1":
                relays = relay_ops.MODULE_1_RELAYS
            elif module == "2":
                relays = relay_ops.MODULE_2_RELAYS
            elif module in ("all", "ma", "todos"):
                relays = list(relay_ops.relay_to_gpio_map)
            else:
                logging.error("%s: unknown module %r", func_name, module)
                return
            logging.info("%s: pulsing module %s (%s relays)", func_name, module, len(relays))
            done = relay_ops.pulse_relays(relays, duration)
            logging.info("%s: pulsed relays %s", func_name, done)
            return

        logging.error("%s: neither relay_number nor module given", func_name)
    except KeyError as e:
        logging.error("%s: %s", func_name, e)
    #pylint: disable=broad-except
    except Exception as e:
        # Never let a wiring test kill the messaging loop.
        logging.error("%s: unexpected error - %s", func_name, e)
    #pylint: enable=broad-except


def message_wake_up():
    func_name = "message_wake_up"
    logging.info("%s: Wake up signal received.", func_name)

def message_activate(json_data: dict):
    func_name = "message_activate"

    intent_id = json_data.get('payment_intent_id') or json_data.get('intent_id')
    machine_id_raw = json_data.get('machine_id')
    number_of_impulses = json_data.get('number_of_impulses')
    callback_url = json_data.get('callback_url')
    callback_token = json_data.get('callback_token')
    activation_key = json_data.get('activation_key')

    activation_status = "CONFIRMED"
    activation_error_code = None

    try:
        if machine_id_raw is None:
            raise KeyError('machine_id')
        if number_of_impulses is None:
            raise KeyError('number_of_impulses')

        machine_id = int(machine_id_raw) if isinstance(machine_id_raw, str) else machine_id_raw

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
            relay_ops.activate_machine_v1_2(
                machine_id=machine_id,
                number_of_impulses=number_of_impulses
            )
        elif (VERSION.startswith("1.5") or VERSION.startswith("1.6")
              or VERSION.startswith("1.7") or VERSION.startswith("1.8")):
            logging.info("%s: Using v1.5+ activation method (v1.2 relay + callback)", func_name)
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
        activation_status = "FAILED"
        activation_error_code = "MACHINE_NOT_CONFIGURED"
        # This is the device discovering it has no relay map, arriving by a
        # different route than the startup check. Ask for one so the next
        # activation can succeed: without this the device stays unable to
        # activate anything until someone notices and presses a button in the
        # dashboard, and nothing about the failure is visible from the cloud.
        # This activation is still lost — asking cannot rescue it.
        logging.info("%s: Requesting configuration so the next attempt can work", func_name)
        request_configuration()
    except KeyError as e:
        logging.error("%s: Missing key in JSON data - %s", func_name, e)
        activation_status = "FAILED"
        activation_error_code = "MISSING_KEY"
    except ValueError as e:
        logging.error("%s: Invalid data format - %s", func_name, e)
        activation_status = "FAILED"
        activation_error_code = "INVALID_DATA"
    except Exception as e:
        logging.error("%s: Unexpected error - %s", func_name, e)
        activation_status = "FAILED"
        activation_error_code = "RELAY_ERROR"

    # Send execution confirmation if callback_url provided (v1.5+)
    if callback_url and callback_token and activation_key:
        try:
            from datetime import datetime
            payload = {
                "activation_key": activation_key,
                "callback_token": callback_token,
                "device_id": DEVICE_ID,
                "status": activation_status,
                "executed_at": datetime.utcnow().isoformat() + "Z",
            }
            if activation_error_code:
                payload["error_code"] = activation_error_code
            requests.post(callback_url, json=payload, timeout=10)
            logging.info("Activation callback sent to %s", callback_url)
        except Exception as e:
            logging.warning("Activation callback failed (non-critical): %s", e)


def _install_mode():
    """Describe how this device was installed: 'root', 'user', or 'image'.

    An image-installed device has .env as a symlink to .env.<environment>; a
    manual install leaves a plain file. Running as root additionally means the
    service was set up with sudo and lives in /root.
    """
    try:
        running_as_root = os.geteuid() == 0
        env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
        from_image = os.path.islink(env_path)
        if running_as_root:
            return "root"
        return "image" if from_image else "user"
    except OSError:
        return "unknown"


def message_reboot():
    func_name = "message_reboot"
    logging.info("%s: Reboot command received.", func_name)
    # Try common reboot paths for compatibility across Debian versions
    reboot_candidates = ["/sbin/reboot", "/usr/sbin/reboot", "/bin/reboot"]
    reboot_path = None
    for candidate in reboot_candidates:
        if os.path.exists(candidate):
            reboot_path = candidate
            break

    if reboot_path is None:
        logging.error("%s: Could not find reboot executable.", func_name)
        return

    try:
        subprocess.Popen(
            ["/usr/bin/sudo", reboot_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        logging.info("%s: Reboot command issued via %s", func_name, reboot_path)
    except Exception as e:
        logging.error("%s: Failed to reboot - %s", func_name, e)

def message_upgrade():
    """
    Handle the upgrade message by pulling the latest code from GitHub.
    Uses the update_pagalava.sh script to fetch and update the codebase.
    """
    func_name = "message_upgrade"
    logging.info("%s: Upgrade command received.", func_name)
    
    try:
        # Log the upgrade attempt
        logging.info("%s: Starting upgrade process by running update_pagalava.sh", func_name)
        
        # Use absolute path for bash and script
        script_dir = os.path.dirname(os.path.abspath(__file__))
        update_script_path = os.path.join(script_dir, "update_pagalava.sh")
        
        # Check if script exists
        if not os.path.exists(update_script_path):
            logging.error("%s: Update script not found at %s", func_name, update_script_path)
            return False
        
        # Check if git is installed
        git_path = "/usr/bin/git"
        if not os.path.exists(git_path):
            logging.error("%s: Git executable not found at %s", func_name, git_path)
            return False
        
        # Run the update script with absolute path to bash
        result = subprocess.run(
            ["/bin/bash", update_script_path], 
            capture_output=True, 
            text=True, 
            check=True
        )
        
        # Log the results
        logging.info("%s: Upgrade completed successfully", func_name)
        logging.info("%s: Script output: %s", func_name, result.stdout)
        
        # Restarting needs root, and the service does not run as root. Probe
        # first: sudo from a service has no tty, so if a password is required
        # it fails silently and the device keeps running the OLD code until
        # someone reboots — while reporting a successful upgrade the whole
        # time. That is exactly what it looked like when an upgraded device
        # kept reporting its previous version.
        can_restart = False
        try:
            # -l asks "am I allowed to run this" without running it.
            # Deliberately NOT `sudo -n true`: a device installed from the golden
            # image has a narrow sudoers rule listing only the commands this
            # service needs, so `true` may not be permitted even when the restart
            # is. Probing the wrong command reported "cannot restart" on exactly
            # the devices this was written to fix.
            probe = subprocess.run(
                ["/usr/bin/sudo", "-n", "-l",
                 "/usr/bin/systemctl", "restart", "receive_messages.service"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10
            )
            can_restart = probe.returncode == 0
        except (subprocess.SubprocessError, OSError) as e:
            logging.warning("%s: could not probe sudo - %s", func_name, e)

        if can_restart:
            logging.info("%s: restarting the service to apply the update", func_name)
            # Popen, not run: a successful restart kills this process, so there
            # is nothing to wait for.
            subprocess.Popen(
                ["/usr/bin/sudo", "/usr/bin/systemctl", "restart", "receive_messages.service"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE
            )
        else:
            # Say so plainly. The files are updated and correct; only the
            # running process is stale, and a reboot fixes it.
            logging.warning(
                "%s: FILES UPDATED but this service cannot restart itself "
                "(passwordless sudo unavailable). The device keeps running the "
                "previous version until it is rebooted.", func_name
            )

        return True
    except subprocess.SubprocessError as e:
        logging.error("%s: Upgrade failed - %s", func_name, e)
        if hasattr(e, 'output'):
            logging.error("%s: Script output: %s", func_name, e.output)
        if hasattr(e, 'stderr'):
            logging.error("%s: Error output: %s", func_name, e.stderr)
        return False
    except Exception as e:
        logging.error("%s: Unexpected error during upgrade - %s", func_name, e)
        return False

def message_version(json_data: dict):
    """
    Handle the get_version message and respond with version information.
    The token is simply echoed back for verification by the backend.
    
    :param json_data: The JSON data from the message
    """
    func_name = "message_version"
    logging.info("%s: Version request received", func_name)
    
    # Extract token from the message
    token = json_data.get("token", "")
    
    # Prepare response with device version and echoed token
    response = {
        "device_id": DEVICE_ID,
        "device_version": VERSION,
        "token": token
    }
    
    # Log the response being sent
    logging.info("%s: Sending version info response: %s", func_name, response)
    
    # Send the response directly to the cloud API
    env_info = determine_environment()
    url = f"https://{env_info['url']}/api/laundries/device_version_callback"
    
    # Log the URL we're sending to
    logging.info("%s: Sending request to endpoint: %s", func_name, url)
    logging.info("%s: Environment: %s", func_name, env_info['env'])
    
    headers = {
        'Content-Type': 'application/json'
    }
    
    try:
        logging.info("%s: Initiating POST request...", func_name)
        response_obj = requests.post(url, json=response, headers=headers)
        logging.info("%s: Request completed with status code: %s", func_name, response_obj.status_code)
        
        if response_obj.status_code == 200:
            logging.info("%s: Version info successfully sent", func_name)
            return True
        else:
            logging.error("%s: Failed to send version info. Status code: %s, Response: %s", 
                         func_name, response_obj.status_code, response_obj.text)
            return False
    except requests.exceptions.ConnectionError as e:
        logging.error("%s: Connection error sending version info: %s", func_name, e)
        return False
    except requests.exceptions.Timeout as e:
        logging.error("%s: Timeout error sending version info: %s", func_name, e)
        return False
    except requests.exceptions.RequestException as e:
        logging.error("%s: Request error sending version info: %s", func_name, e)
        return False
    except Exception as e:
        logging.error("%s: Error sending version info: %s", func_name, e)
        return False

def get_local_ip():
    """Get the device's local IP address."""
    try:
        # Connect to an external address to determine the local IP used for routing
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception as e:
        logging.warning("Could not determine local IP address: %s", e)
        return None


def message_diagnostic(json_data: dict):
    """
    Manipula mensagens de diagnóstico, gravando o código de verificação num ficheiro
    e enviando o callback de conectividade para o backend.

    :param json_data: O JSON da mensagem contendo o código de verificação
    """
    func_name = "message_diagnostic"
    logging.info("%s: Mensagem de diagnóstico recebida", func_name)

    verification_code = json_data.get("verification_code")
    if not verification_code:
        logging.error("%s: Código de verificação não encontrado na mensagem", func_name)
        return False

    # Pasta para ficheiros temporários
    script_dir = os.path.dirname(os.path.abspath(__file__))
    diagnostic_dir = os.path.join(script_dir, "diagnostics")

    # Criar pasta se não existir
    if not os.path.exists(diagnostic_dir):
        try:
            os.makedirs(diagnostic_dir)
            logging.info("%s: Pasta de diagnóstico criada", func_name)
        except Exception as e:
            logging.error("%s: Falha ao criar pasta de diagnóstico - %s", func_name, e)
            return False

    # Gravar o código num ficheiro
    verification_file = os.path.join(diagnostic_dir, "verification_code.txt")
    try:
        with open(verification_file, 'w') as file:
            file.write(verification_code)
        os.chmod(verification_file, 0o666)
        logging.info("%s: Código de verificação gravado em %s", func_name, verification_file)
    except Exception as e:
        logging.error("%s: Falha ao gravar código de verificação - %s", func_name, e)
        return False

    # Enviar callback de conectividade para o backend
    ip_address = get_local_ip()
    env_info = determine_environment()
    url = f"https://{env_info['url']}/api/laundries/iot/connectivity_callback"

    payload = {
        "device_id": DEVICE_ID,
        "verification_code": verification_code,
        "ip_address": ip_address
        # NOTE: do NOT add fields here without adding them to the backend's
        # allow-list first. The endpoint is decorated with
        # @az_func_request_params(allowed=[...]) from yimaipy, which REJECTS
        # unknown parameters with 400 - it does not ignore them. Adding
        # install_mode here broke connectivity verification on every device that
        # upgraded, until the field was removed again. The install mode is still
        # logged at startup, so it remains visible in the journal.
    }

    logging.info("%s: Enviando callback de conectividade para %s (IP: %s)", func_name, url, ip_address)

    try:
        response = requests.post(url, json=payload, headers={"Content-Type": "application/json"}, timeout=15)
        if response.status_code == 200:
            logging.info("%s: Callback de conectividade enviado com sucesso", func_name)
            return True
        else:
            logging.error("%s: Falha no callback. Status: %s, Resposta: %s",
                         func_name, response.status_code, response.text)
            return False
    except requests.exceptions.RequestException as e:
        logging.error("%s: Erro ao enviar callback de conectividade: %s", func_name, e)
        return False

def message_report_diagnostics():
    """
    Report what this device is running, on request.

    Answers questions that otherwise need SSH: which Debian, which Python, where
    the connection string actually lives, how exposed the files are. Most devices
    have no inbound SSH, so before this the only way to know was to guess — and
    guessing wrong is how 1.8 crash-looped a laundromat.

    Never raises: diagnostics failing must not affect anything else.
    """
    func_name = "message_report_diagnostics"
    logging.info("%s: Diagnostics requested", func_name)
    env_info = determine_environment()
    ok = diagnostics_report.send(DEVICE_ID, env_info["url"], generate_minute_token)
    if not ok:
        logging.warning("%s: the report was not accepted", func_name)
    return ok



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
    elif msg_type == 'upgrade' or msg_type == 'request_upgrade':
        message_upgrade()
    elif msg_type == 'get_version':
        message_version(json_data)
    elif msg_type == 'test_relay':
        message_test_relay(json_data)
    elif msg_type == 'report_diagnostics':
        message_report_diagnostics()
    elif msg_type == 'diagnostic':
        message_diagnostic(json_data)
    else:
        logging.warning("message_handler: Unknown message type '%s'", msg_type)
    
    logging.info("Total messages received: %s", RECEIVED_MESSAGES)
    logging.info("Processing time: %.2f seconds", time.time() - start_time)

def check_internet_connection():
    """Check if there is internet connectivity by trying to resolve DNS"""
    try:
        # Try to resolve a common domain name
        socket.gethostbyname("azure.microsoft.com")
        return True
    except socket.gaierror:
        return False

# How long to wait at startup for the clock, and how often to look. Sync took
# ~70s on the 1.9 hardware test; 300s is generous without being unbounded, and
# matches the cap already used for reconnect backoff below.
CLOCK_SYNC_TIMEOUT_SECONDS = 300
CLOCK_SYNC_POLL_SECONDS = 5


def wait_for_clock_sync(timeout_seconds=CLOCK_SYNC_TIMEOUT_SECONDS,
                        poll_seconds=CLOCK_SYNC_POLL_SECONDS):
    """
    Wait until the clock has been corrected by NTP. Returns seconds waited.

    A Pi has no RTC, so at first boot it believes whatever fake-hwclock last
    saved. Everything this service then does needs a correct clock:

      * the IoT Hub SAS token is time-based. On the 1.9 hardware test the device
        booted ~1h43m behind, passed certificate validation, and was refused with
        "Connection Refused: not authorised".
      * the minute token used for diagnostics and for requesting configuration is
        sha256("<device_id>:<minute>") from this clock, so a skewed device is
        rejected 401 and cannot even report that it is skewed.

    Without this the device still recovered, but only via the generic reconnect
    backoff, which multiplies to a 300s cap - so it could sit idle for five
    minutes after its clock was already right.

    On timeout it returns anyway rather than blocking forever. A site where NTP
    is filtered then behaves exactly as it does today: the connection is refused
    and the backoff loop retries. This must never make things worse than not
    waiting at all, which is also why it can never raise.
    """
    try:
        state = diagnostics_report.time_synced()
        if state is None:
            # No timedatectl, or it would not answer. Waiting on a question that
            # cannot be answered would hang startup for the full timeout.
            logging.warning("Clock sync state unknown; connecting without waiting.")
            return 0
        if state == "yes":
            return 0

        logging.warning(
            "Clock not synchronised yet; deferring the IoT Hub connection for up "
            "to %ss. Connecting now would be refused: the SAS token is time-based.",
            timeout_seconds,
        )
        waited = 0
        while waited < timeout_seconds:
            time.sleep(poll_seconds)
            waited += poll_seconds
            state = diagnostics_report.time_synced()
            if state is None:
                logging.warning("Clock sync state became unknown after %ss; "
                                "connecting anyway.", waited)
                return waited
            if state == "yes":
                logging.info("Clock synchronised after %ss; connecting.", waited)
                return waited

        logging.error(
            "Clock STILL not synchronised after %ss. Connecting anyway - expect "
            "'not authorised' until NTP reaches this site. Check the site's NTP path.",
            waited,
        )
        return waited
    except Exception as exc:  # deliberately broad: never block startup
        logging.warning("Clock sync wait failed (%s); connecting anyway.", exc)
        return 0


def main():
    """Main function with reconnection logic following Azure best practices"""
    logging.info("Starting the Python IoT Hub C2D Messaging device sample...")
    
    # Initialize client at a broader scope so we can access it in finally block
    client = None
    
    # Initial backoff time in seconds
    backoff_time = 60

    # Guards the startup configuration request so a reconnect loop does not
    # repeat it; MachineNotConfiguredException is the recovery path instead.
    requested_configuration = False
    # Guards the clock wait. main() is a retry loop, so an unguarded wait would
    # burn the full timeout on EVERY reconnect at a site where NTP never arrives.
    clock_wait_done = False
    max_backoff_time = 300  # 5 minutes
    
    while True:
        try:
            # Check for internet connection before attempting to connect
            if not check_internet_connection():
                logging.warning("No internet connectivity detected. Waiting before retry...")
                time.sleep(backoff_time)
                
                # Increase backoff using exponential backoff with max limit
                backoff_time = min(backoff_time * 1.5, max_backoff_time)
                continue
                
            # Reset backoff time when we have connectivity
            backoff_time = 60

            # Before the FIRST connection attempt, and only then. Placed here
            # because everything below needs a correct clock: the hub's SAS
            # token, the diagnostics report and the configuration request are
            # all time-derived.
            if not clock_wait_done:
                diagnostics_report.set_clock_wait_seconds(wait_for_clock_sync())
                clock_wait_done = True

            # Create a new client instance if needed
            if client is None:
                logging.info("Instantiating IoT Hub client...")
                client = IoTHubDeviceClient.create_from_connection_string(IOT_CONNECTION_STRING)
                client.on_message_received = message_handler
                logging.info("IoT Hub client instantiated successfully.")
            
            # NOT a connection confirmation. There is no client.connect() here and
            # the SDK connects lazily, so the old "Connected successfully" printed
            # while the hub was refusing us with "not authorised" - and reading it
            # as success cost real time during the 1.9 clock investigation. Say
            # only what is actually known at this point.
            logging.info("IoT Hub client ready; the SDK connects on demand. "
                         "Waiting for C2D messages. Press Ctrl-C to exit.")
            # Report what this device is, on every start. Passive fleet coverage:
            # most devices have no inbound SSH, so this is the only way we learn
            # what they run. send() never raises - a diagnostics failure must never
            # be why a laundromat stops taking payments.
            diagnostics_report.send(DEVICE_ID, determine_environment()['url'],
                                    generate_minute_token)
            # Recorded on every start, so the journal shows how a device was
            # installed even if it never runs a connectivity check.
            logging.info("Install mode: %s (version %s)", _install_mode(), VERSION)

            # A device imaged from the golden image has no config.json and
            # cannot activate anything until the cloud sends one. Ask now that
            # the network is definitely up. Only once per process: the retry
            # path is the activation handler below.
            if not requested_configuration:
                request_configuration_if_missing()
                requested_configuration = True
            
            # Keep the script running to listen for messages
            while True:
                # Using shorter sleep intervals allows for quicker response to KeyboardInterrupt
                time.sleep(30)
                
                # Periodically check connection status (SDK doesn't provide direct way,
                # but we can implement a ping mechanism or heartbeat if needed)
                
        except KeyboardInterrupt:
            logging.info("IoT Hub C2D Messaging device sample stopped by user.")
            break
            
        except Exception as e:
            logging.error("Connection error: %s", e)
            
            # Properly clean up the client if it exists
            if client:
                try:
                    client.shutdown()
                    logging.info("IoT Hub client shut down due to error.")
                except:
                    pass
                
                # Set client to None so we create a fresh instance on retry
                client = None
            
            logging.info("Will attempt to reconnect in %d seconds...", backoff_time)
            time.sleep(backoff_time)
            
            # Increase backoff using exponential backoff with max limit
            backoff_time = min(backoff_time * 1.5, max_backoff_time)
    
    # Final cleanup
    if client:
        try:
            client.shutdown()
            logging.info("IoT Hub client shut down successfully.")
        except Exception as e:
            logging.error("Error during client shutdown: %s", e)

if __name__ == '__main__':
    main()
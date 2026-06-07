# Bootstrap Migration: Old Devices Without .env

## Problem

Some older Digipay IoT devices have `IOT_CONNECTION_STRING` defined **only** in the systemd unit's
`Environment=` line, with no `.env` file present. On these devices:

1. The `configurar` tool cannot list environments (needs `.env.<id>` files).
2. Switching environments is impossible until `.env` is created.
3. The device is "stuck" on the hardcoded systemd value.

## Current Mitigation

The `load_dotenv(override=True)` change in `ReceiveMessages.py` (v1.6) ensures that **if** a `.env`
is created manually, it will be respected even on these old devices. But the bootstrap step — creating
the initial `.env` from the existing systemd value — is still manual.

## Proposed Solution

Implement a two-step bootstrap flow:

### Step 1: Inspect Message (C2D from Cloud)

Add a new message type `inspect_environment` that:
- Device receives it and reads the current `IOT_CONNECTION_STRING` from `os.environ` (which may be
  the systemd-baked value).
- Device reports back (D2C) the device id, host (dev/prod), and masked key.
- Cloud operator can see: "This device has DeviceId=rpiPagalava42 (dev, baked-in systemd)".

Implementation:
```python
def message_inspect_environment(json_data: dict):
    """Report back the currently-loaded IOT_CONNECTION_STRING."""
    func_name = "message_inspect_environment"
    logging.info("%s: Inspect request received", func_name)
    
    connection_string = os.getenv("IOT_CONNECTION_STRING")
    token = json_data.get("token", "")
    
    response = {
        "device_id": get_device_id(),
        "device_version": VERSION,
        "env_type": determine_environment()["env"],
        "connection_string_masked": _mask_connection_string(connection_string),
        "token": token,
        "has_env_file": Path(".env").exists() or Path(".env").is_symlink()
    }
    
    # POST back to cloud API (similar to message_version)
    # ...
```

### Step 2: Bootstrap .env (Cloud-Triggered or Manual)

Once the cloud (or an operator) knows the device's current state via `inspect_environment`:

**Option A: Cloud-triggered message `bootstrap_env`**
```python
def message_bootstrap_env(json_data: dict):
    """Create .env from the systemd-baked IOT_CONNECTION_STRING."""
    func_name = "message_bootstrap_env"
    connection_string = os.getenv("IOT_CONNECTION_STRING")
    
    if not connection_string:
        logging.error("%s: No IOT_CONNECTION_STRING to bootstrap", func_name)
        return False
    
    env_file = Path(".env")
    if env_file.exists() or env_file.is_symlink():
        logging.warning("%s: .env already exists, skipping", func_name)
        return True
    
    # Create .env with the current systemd value
    try:
        env_file.write_text(f"IOT_CONNECTION_STRING={connection_string}\n")
        env_file.chmod(0o600)
        logging.info("%s: Created .env from systemd environment", func_name)
        return True
    except OSError as exc:
        logging.error("%s: Failed to create .env: %s", func_name, exc)
        return False
```

**Option B: Manual (operator on device)**
```bash
# On the device, via SSH:
echo "IOT_CONNECTION_STRING=$(grep 'IOT_CONNECTION_STRING=' /etc/systemd/system/receive_messages.service | cut -d= -f2-)" > .env
chmod 600 .env
sudo systemctl restart receive_messages.service
```

After either option, the `configurar` tool can be used normally.

### Step 3: (Optional) Remove Systemd Variable

Once `.env` is bootstrapped and working, optionally strip the `Environment=IOT_CONNECTION_STRING=...`
from the systemd unit so that `.env` becomes the sole source of truth:

```bash
sudo systemctl edit receive_messages.service
# Remove the Environment= line, save, then:
sudo systemctl daemon-reload
sudo systemctl restart receive_messages.service
```

## Testing Strategy

1. **Test on bumblebee** (the old v1.3 device sample that only has systemd var):
   - Verify `inspect_environment` message reports the current value.
   - Send `bootstrap_env` message or manually create `.env`.
   - Verify `configurar` now lists the environment correctly.
   - Switch to a different `.env.<id>` and confirm it works.

2. **Verify override behaviour**:
   - Confirm `load_dotenv(override=True)` reads the bootstrapped `.env` not the systemd var.

## Timeline

- **v1.6** (current): Foundation (`override=True`, `configurar` tool, docs).
- **v1.7** (future): `inspect_environment` message.
- **v1.8** (future): `bootstrap_env` message.
- **v1.9+** (later): Optional systemd unit cleanup flow.

## Related Issues

- GitHub issue / GitLab issue: Track bootstrap migration and testing on old devices.
- Bumblebee is the preserved test sample for this migration path.

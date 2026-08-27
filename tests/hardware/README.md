# Hardware tests

Driven through a PiKVM so a firmware version can be validated on a real Pi
without handling SD cards. Start with
[`docs/hardware-test-runbook.md`](../../docs/hardware-test-runbook.md).

| Script | Purpose |
|---|---|
| `lib.sh` | shared helpers, env-var config, pass/fail accounting |
| `serve_image.sh` | stage an image on the PiKVM, expand it, attach it writable |
| `prepare_boot.sh` | write into the image's boot partition what an installer would |
| `run_manual_install.sh` | run the installer unattended, provisioning or interactive |
| `verify_device.sh` | assert a provisioned device is correct |

Configuration is entirely by environment variable and there are no prompts, so
these run the same by hand or from a CI runner. Exit codes: **0** pass, **1** an
assertion failed, **2** the environment is broken — a CI job should treat 2 as
infrastructure down rather than a code failure.

The one step none of these can do is **power on the target**: a Raspberry Pi has
no standby power rail, so Wake-on-LAN does nothing and PiKVM's ATX control
drives a PC front-panel header a Pi does not have. A smart plug or a relay on
the supply is what would close that gap.

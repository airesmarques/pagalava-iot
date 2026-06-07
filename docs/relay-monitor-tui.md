# Relay Monitor TUI Tab

## Overview

Add a new tab to the `configurar` TUI that displays real-time relay activation status and history. This allows testing relay logic without physical hardware, providing visual feedback on which relays are active and when they were activated.

## User Stories

1. **As a developer**, I want to see which relays are active in real-time so I can verify activation logic during testing without relying on physical relays.
2. **As a tester**, I want to see a history of relay activations (since the TUI opened) so I can understand the sequence of events during a test run.
3. **As an operator**, I want to know which relays are configured and their current state so I can validate the system configuration.

## Design

### Architecture

**Monitoring Source**: Hook into `relay_ops` module calls (specifically `activate_machine_v1_2` and similar) to detect when relays are activated. Relay state is transient — relays turn on briefly during activation, then turn off.

**State Storage**: In-memory `RelayHistory` class tracking:
- Relay ID (1–16, from config.json)
- Last activation timestamp
- Activation count (since TUI opened)
- Current state (on/off, based on pulse timing)

**TUI Tab**: New tab labeled "Relés" (or "Relays") showing:
- Grid of 16 relay boxes (4×4 or 2×8 layout)
- Each box shows relay number, machine ID, and current state (● active / ○ inactive)
- Below grid: activation history as a simple table (relay #, timestamp, duration)

### Implementation Details

#### 1. Relay Detection from `config.json`

Read `config.json` to build the relay registry. Example:

```json
{
  "1": {
    "machine_id": "1",
    "relay_number": "9",
    "time_relay_ms": "2000",
    ...
  },
  ...
}
```

Map: relay_number → machine_id. For relays not in config, show as "unconfigured".

#### 2. State Tracking

Create `RelayMonitor` class (in `configurar.py` or separate module):

```python
@dataclass
class RelayEvent:
    relay_id: int
    machine_id: str
    timestamp: datetime
    duration_ms: int  # if we can infer it later

class RelayMonitor:
    def __init__(self, config_path: Path):
        self.relays = {}  # relay_id -> {machine_id, current_state, events}
        self.events = []  # history, newest first
        self.load_config(config_path)
    
    def activate(self, relay_id: int, machine_id: str, duration_ms: int):
        """Called when a relay is activated."""
        event = RelayEvent(relay_id, machine_id, datetime.now(), duration_ms)
        self.events.append(event)
        self.relays[relay_id]['state'] = 'active'
        # Schedule deactivation after duration_ms
    
    def get_history(self, limit: int = 20) -> List[RelayEvent]:
        """Return recent activation history."""
        return self.events[-limit:]
```

**Integration Point**: Monkey-patch or wrap `relay_ops.activate_machine_v1_2` (and other versions) to call `monitor.activate()`.

#### 3. TUI Tab Layout

```
┌─ Relés ─────────────────────────────┐
│  Relay Status:                      │
│  ┌──┐ ┌──┐ ┌──┐ ┌──┐              │
│  │1 │ │2 │ │3 │ │4 │              │
│  │● │ │○ │ │○ │ │● │              │
│  └──┘ └──┘ └──┘ └──┘              │
│  ┌──┐ ┌──┐ ┌──┐ ┌──┐              │
│  │5 │ │6 │ │7 │ │8 │              │
│  │○ │ │○ │ │○ │ │○ │              │
│  └──┘ └──┘ └──┘ └──┘              │
│  ... (up to 16)                    │
│                                    │
│  Histórico de Ativações:           │
│  ┌──────┬─────────────────┬──────┐ │
│  │Relé │Hora             │Máq   │ │
│  ├──────┼─────────────────┼──────┤ │
│  │1    │01:40:15.324     │1     │ │
│  │3    │01:40:12.892     │2     │ │
│  │1    │01:40:10.456     │1     │ │
│  └──────┴─────────────────┴──────┘ │
└─────────────────────────────────────┘
```

**Relay Box States**:
- ● (green, filled): active
- ○ (gray, hollow): inactive
- ? (yellow): unconfigured (not in config.json)

#### 4. Integration with Existing TUI

Modify `configurar.py`:

1. Add `RelayMonitor` instance to app initialization.
2. Add new `RelayTab` widget (Textual `TabPane`).
3. Hook into `relay_ops` calls to feed activation events to monitor.
4. Periodic refresh (every 100–200ms) to update relay state and history display.

### Testing Without Hardware

**Setup**: Run the TUI and trigger activations via:
- Direct `relay_ops.activate_machine_v1_X()` calls (e.g., from a test script)
- Or mock `relay_ops` with test data

**Verification**: Watch the TUI tab to see relays light up and history populate.

### Out of Scope (v1)

- Persistent activation logs (only in-memory since TUI opened)
- Relay timing details (pulse length, interval between impulses)
- GPIO-level monitoring (we hook message handlers, not GPIO directly)
- Relay activation triggered by IoT messages (future: extend to monitor C2D messages)

## Files to Create/Modify

- **New**: `docs/relay-monitor-tui.md` (this document)
- **Modify**: `configurar.py` — add `RelayMonitor` class, hook into relay activation, add UI tab
- **Possibly new**: `relay_monitor.py` (if `RelayMonitor` grows large, extract to separate module)

## Timeline

- **v1.6** (current): Foundation done; relay monitoring not yet implemented.
- **v1.7** (future): Add relay monitor tab, history tracking, basic UI.
- **v1.8+** (later): Persistent logs, timing info, IoT message monitoring.

## Related Work

- Existing `relay_ops.py` module defines activation functions (v1.0, v1.1, v1.2, etc.).
- `config.json` contains relay-to-machine mappings.
- Textual `TabbedContent` / `TabPane` for adding new tab.

## Questions & Notes

- **Relay activation granularity**: Do we catch activation at the `relay_ops` level or GPIO level? (Recommended: `relay_ops` level for simplicity.)
- **State inference**: Relays are momentary (pulse). We either infer state from timing (on for duration_ms, then off) or track it externally. Consider keeping state transient but logging events.
- **Config reload**: Should relay monitor reload `config.json` on demand, or only on TUI startup?

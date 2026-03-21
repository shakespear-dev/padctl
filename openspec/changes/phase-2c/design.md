# Phase 2c Design: Multi-device Supervisor, MacroPlayer, Auto-discover, Hot-reload

## Design Decisions

| # | Decision | Resolution | Rationale |
|---|----------|-----------|-----------|
| D1 | Multi-device architecture | One thread per DeviceInstance | Devices are naturally isolated (different protocols, capabilities, state); existing EventLoop zero-change; one device crash does not affect others |
| D2 | Same-model device disambiguation | Physical path (`HIDIOCGRAWPHYS`) | Serial numbers unreliable; ordering unstable; physical path is already read and is stable |
| D3 | Macro execution engine | timerfd state machine (MacroPlayer) | Single-threaded, no concurrency hazards; consistent with tap-hold timerfd pattern; ~1 ms precision sufficient for 10–50 ms macro steps |
| D4 | Layer switch → macro interrupt | Immediate cancel + key-up flush | Avoids cross-layer state pollution; `pause_for_release` gives user control over hold boundaries |
| D5 | Config reload trigger | SIGHUP (signalfd) | Unix standard; explicit, avoids partial-write races from editors; low extension cost |
| D6 | Mapping hot-swap | Atomic pointer swap + stop_pipe wakeup | Lock-free safe; DeviceInstance not restarted; zero downtime |
| D7 | Config discovery | `--config-dir` (glob `*.toml`) + `--config` backward-compatible | Directory mode fits `/etc/padctl/devices.d/`; existing single-file usage unaffected |

## Architecture

### Thread Model

```
main
├── Supervisor (main thread)
│   ├── signalfd: SIGTERM, SIGINT, SIGHUP
│   └── ppoll: stop_fd + hup_fd + thread-exit detection
│
├── DeviceInstance[0] thread
│   └── EventLoop.run() — hidraw fds + uinput fd + timerfd
│
└── DeviceInstance[1] thread
    └── EventLoop.run() — hidraw fds + uinput fd + timerfd
```

All child threads block SIGTERM, SIGINT, SIGHUP via `pthread_sigmask`. Only the Supervisor's signalfd receives these signals.

On child-thread exit (device disconnect), Supervisor detects join completion and respawns with exponential backoff: 1 s → 2 s → 4 s → 8 s → cap 30 s.

### DeviceInstance

```zig
pub const DeviceInstance = struct {
    config: DeviceConfig,
    allocator: std.mem.Allocator,   // Arena; freed on thread exit
    event_loop: EventLoop,
    interpreter: Interpreter,
    mapper: Mapper,
    output: OutputDevice,
    pending_mapping: ?*MappingConfig, // atomic; hot-swap target

    pub fn init(allocator: std.mem.Allocator, config: DeviceConfig) !DeviceInstance
    pub fn run(self: *DeviceInstance) !void  // thread entry point
    pub fn stop(self: *DeviceInstance) void  // writes stop_pipe
    pub fn updateMapping(self: *DeviceInstance, new: *MappingConfig) void
};
```

`run()` calls `event_loop.run()`. At the top of each ppoll iteration, DeviceInstance checks `pending_mapping` with an acquire load before processing any fds:

```zig
if (@atomicLoad(?*MappingConfig, &self.pending_mapping, .acquire)) |new| {
    self.mapper.replaceConfig(new);
    @atomicStore(?*MappingConfig, &self.pending_mapping, null, .release);
}
```

### Supervisor

```zig
pub const Supervisor = struct {
    instances: std.ArrayList(DeviceInstance),
    threads: std.ArrayList(std.Thread),
    stop_fd: posix.fd_t,  // signalfd: SIGTERM + SIGINT
    hup_fd: posix.fd_t,   // signalfd: SIGHUP

    pub fn run(self: *Supervisor) !void
};
```

`run()` ppoll loop: on `stop_fd` ready → call `stop()` on all instances, join all threads, return. On `hup_fd` ready → invoke reload sequence (see Hot-reload below).

### Macro Config

TOML format:

```toml
[[macro]]
name = "dodge_roll"
steps = [
    { tap = "B" },
    { delay = 50 },
    { tap = "LEFT" },
]

[[macro]]
name = "shift_hold"
steps = [
    { down = "KEY_LSHIFT" },
    { pause_for_release = true },
    { up = "KEY_LSHIFT" },
]

[remap]
M1 = "macro:dodge_roll"

[layer.aim.remap]
M2 = "macro:shift_hold"
```

Data types:

```zig
pub const MacroStep = union(enum) {
    tap: ButtonOrKey,
    down: ButtonOrKey,
    up: ButtonOrKey,
    delay: u32,         // milliseconds
    pause_for_release,
};

pub const Macro = struct {
    name: []const u8,
    steps: []const MacroStep,
};
```

`"macro:name"` in a remap value is parsed to `RemapTarget.macro` carrying the name string. At config parse time, all referenced macro names are validated against the declared `[[macro]]` table; unknown name → `error.UnknownMacro`.

### MacroPlayer + TimerQueue

**TimerQueue** replaces the single timerfd slot in EventLoop. It is a min-heap of `Deadline` entries (tap-hold timeouts + macro delays) keyed by absolute monotonic timestamp. After any queue mutation, the single timerfd is re-armed to the soonest deadline. On timerfd expiry, all expired entries are drained and dispatched.

```zig
pub const MacroPlayer = struct {
    macro: *const Macro,
    step_index: usize,
    waiting_for_release: bool,

    pub fn resume(self: *MacroPlayer, output: *AuxOutputDevice, queue: *TimerQueue) !?void
    pub fn notifyTriggerReleased(self: *MacroPlayer) void
};
```

Execution flow per `resume()` call:

| Step type | Action |
|-----------|--------|
| `tap(key)` | press key → sync → release key → sync; advance step_index; continue |
| `down(key)` | press key → sync; advance; continue |
| `up(key)` | release key → sync; advance; continue |
| `delay(ms)` | arm TimerQueue deadline at `now + ms`; return (resume called again on expiry) |
| `pause_for_release` | set `waiting_for_release = true`; return (resume called on trigger-release notification) |
| end of steps | player finished; caller removes from `active_macros` |

Mapper holds `active_macros: std.ArrayList(MacroPlayer)`. On each ppoll iteration, after processing input fds, Mapper calls `resume()` on all active players. Layer switch → `active_macros` cleared; any held keys flushed via up-events.

### Auto-discover

`HidrawDevice.discoverAll(vid: u16, pid: u16) ![][:0]const u8` — returns all `/dev/hidraw*` paths matching VID/PID. Physical path (`HIDIOCGRAWPHYS`) is used as a stable unique key to prevent duplicate DeviceInstance creation when the same node is matched by multiple config files.

Supervisor config-directory scan:
1. Glob `*.toml` in the directory, parse each for `[device] vid`/`pid`.
2. For each config, call `discoverAll(vid, pid)`.
3. Collect `(physical_path, config)` pairs; deduplicate by physical path.
4. Create one DeviceInstance per unique pair; spawn thread.

CLI:

```
padctl --config devices/flydigi-vader5.toml     # single file (backward-compatible)
padctl --config-dir /etc/padctl/devices.d/      # directory glob
```

### SIGHUP Hot-reload

On SIGHUP, Supervisor:
1. Re-scans config source (file list or directory).
2. Computes diff against running instances keyed by physical path:
   - **New** path → discover device → create DeviceInstance → spawn thread.
   - **Removed** path → `DeviceInstance.stop()` → join thread → free.
   - **Changed mapping** → parse new `MappingConfig` → `DeviceInstance.updateMapping(new)` → writes stop_pipe to wake ppoll.
3. Consecutive SIGHUPs are serialized: second SIGHUP is processed only after the first reload completes.

`updateMapping` uses an atomic store (release order) into `pending_mapping`; the DeviceInstance thread reads it with an acquire load at the top of the next ppoll iteration and calls `mapper.replaceConfig`.

## Data Flow Changes

### `src/config/mapping.zig` additions

```zig
pub const RemapTarget = union(enum) {
    // existing variants...
    macro: []const u8,  // macro name reference
};

pub const MappingConfig = struct {
    // existing fields...
    macros: []const Macro,
};
```

### `src/core/mapper.zig` additions

```zig
active_macros: std.ArrayList(MacroPlayer),
timer_queue: TimerQueue,
```

`Mapper.apply` integrates macro triggers:
- When a remap target resolves to `.macro`, look up the `Macro` by name, create `MacroPlayer`, append to `active_macros`.
- Resume all active players after fd processing.
- On layer switch, drain `active_macros`: call up-event for any held key, clear the list.

### `src/event_loop.zig` changes

- Single `timerfd` slot replaced by `TimerQueue`; timerfd remains one fd in pollfds but is re-armed by `TimerQueue` after each mutation.
- On timerfd ready: call `timer_queue.drainExpired()` → dispatch tap-hold callbacks and macro player resumes.

## Edge Cases

| Case | Handling |
|------|----------|
| Two configs with same VID/PID, same physical path | Deduplication: one DeviceInstance created |
| Config dir empty | Zero instances; Supervisor exits cleanly |
| `macro:name` references undefined macro | `error.UnknownMacro` at parse time, before any thread spawns |
| Empty macro (`steps = []`) | Valid; MacroPlayer finishes immediately (no-op) |
| Macro active during layer switch | Flush held keys; clear `active_macros` |
| Multiple macros playing simultaneously | Each has independent `MacroPlayer`; TimerQueue orders all deadlines |
| SIGHUP during previous reload | Second reload queued; processed sequentially after first completes |
| DeviceInstance thread exits (device disconnect) | Supervisor detects join; exponential backoff respawn |
| `pending_mapping` set before previous apply completes | Acquire/release ordering guarantees the latest value is seen; previous partial mapping is never observed |

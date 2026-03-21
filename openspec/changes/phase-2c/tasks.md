# Phase 2c Tasks

## Dependency Graph

```
Wave 0 (parallel, no deps):
  T1  DeviceInstance struct — extract per-device runtime from main.zig
  T2  MacroConfig TOML parsing — [[macro]] + macro:name remap target

Wave 1 (parallel, depends T1, T2):
  T3  Supervisor — spawn/join DeviceInstance threads + signalfd ppoll   ← T1
  T4  MacroPlayer timerfd state machine + TimerQueue min-heap           ← T2

Wave 2 (parallel, depends T3, T4):
  T5  Auto-discover — --config-dir glob + discoverAll + physical-path dedup   ← T3
  T6  SIGHUP hot-reload — signalfd + atomic mapping swap                      ← T3, T4

Wave 3:
  T7  End-to-end integration test                                       ← T5, T6
```

> Layer column: L0 = pure functions, always CI; L1 = mock vtable/fd, always CI; L2 = real device, local manual.

---

## T1: DeviceInstance encapsulation

**Files**: `src/device_instance.zig` (new), `src/main.zig` (refactor)

**Changes**:

Extract the per-device runtime from `main.zig` into a self-contained struct:

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
    pub fn run(self: *DeviceInstance) !void  // thread entry; calls event_loop.run()
    pub fn stop(self: *DeviceInstance) void  // writes stop_pipe
    pub fn updateMapping(self: *DeviceInstance, new: *MappingConfig) void
};
```

`main.zig` single-device path: create one `DeviceInstance`, spawn via `Thread.spawn(run)`, behavior identical to Phase 2b.

At the top of each ppoll iteration, `run()` checks `pending_mapping` before processing any fds:

```zig
if (@atomicLoad(?*MappingConfig, &self.pending_mapping, .acquire)) |new| {
    self.mapper.replaceConfig(new);
    @atomicStore(?*MappingConfig, &self.pending_mapping, null, .release);
}
```

**Tests (L0)**:
- `DeviceInstance.init` creates all sub-components without error
- `stop()` writes stop_pipe; `run()` exits on the next ppoll return
- `pending_mapping` write is visible to `run()` on the following ppoll iteration; applied before any fd is processed

---

## T2: MacroConfig TOML parsing

**Files**: `src/core/macro.zig` (new), `src/config/mapping.zig` (extend)

**Changes**:

New types in `src/core/macro.zig`:

```zig
pub const MacroStep = union(enum) {
    tap: ButtonOrKey,
    down: ButtonOrKey,
    up: ButtonOrKey,
    delay: u32,           // milliseconds
    pause_for_release,
};

pub const Macro = struct {
    name: []const u8,
    steps: []const MacroStep,
};
```

`src/config/mapping.zig` additions:

```zig
pub const RemapTarget = union(enum) {
    // existing variants ...
    macro: []const u8,   // macro name reference
};

pub const MappingConfig = struct {
    // existing fields ...
    macros: []const Macro,
};
```

TOML format:

```toml
[[macro]]
name = "dodge_roll"
steps = [
    { tap = "B" },
    { delay = 50 },
    { tap = "LEFT" },
]

[remap]
M1 = "macro:dodge_roll"
```

`"macro:name"` in a remap value is parsed to `RemapTarget.macro` carrying the name string. At parse time, every referenced macro name is validated against the `[[macro]]` table; unknown name → `error.UnknownMacro`.

**Tests (L0)**:
- `[[macro]]` multi-entry parse; each step primitive (`tap/down/up/delay/pause_for_release`) decoded correctly
- `"macro:dodge_roll"` parses to `RemapTarget.macro("dodge_roll")`
- reference to undefined macro name → `error.UnknownMacro`
- empty steps array (`steps = []`) → valid, no error (no-op macro)

---

## T3: Supervisor thread management

**Files**: `src/supervisor.zig` (new), `src/main.zig` (refactor)

**Changes**:

```zig
pub const Supervisor = struct {
    instances: std.ArrayList(DeviceInstance),
    threads: std.ArrayList(std.Thread),
    stop_fd: posix.fd_t,   // signalfd: SIGTERM + SIGINT
    hup_fd: posix.fd_t,    // signalfd: SIGHUP

    pub fn run(self: *Supervisor) !void
};
```

Signal isolation: all child threads block SIGTERM, SIGINT, SIGHUP via `pthread_sigmask` at thread start. Only the Supervisor receives them through `stop_fd` / `hup_fd`.

`run()` ppoll loop:
- `stop_fd` ready → `stop()` all instances → join all threads → return.
- `hup_fd` ready → invoke reload sequence (T6).
- Thread exit (device disconnect) → Supervisor detects join completion → exponential-backoff respawn: 1 s → 2 s → 4 s → 8 s → cap 30 s.

**Tests (L1)**:
- Two mock DeviceInstances run concurrently; each processes its own events without interference
- One DeviceInstance `stop()` → that thread exits; the other continues running
- SIGTERM → all `DeviceInstance.stop()` called → all threads joined → Supervisor returns
- Child thread exit → Supervisor triggers respawn with exponential backoff (1 s → 2 s → 4 s → 8 s → 30 s cap)

---

## T4: MacroPlayer timerfd state machine + TimerQueue

**Files**: `src/core/macro_player.zig` (new), `src/core/timer_queue.zig` (new), `src/core/mapper.zig` (integrate)

**Changes**:

`TimerQueue` — min-heap of `Deadline` entries keyed by absolute monotonic timestamp, covering both tap-hold timeouts and macro delays. After any mutation it re-arms the single EventLoop timerfd to the nearest deadline. On timerfd expiry, `drainExpired()` dispatches all entries whose deadline has passed.

```zig
pub const MacroPlayer = struct {
    macro: *const Macro,
    step_index: usize,
    waiting_for_release: bool,

    pub fn resume(self: *MacroPlayer, output: *AuxOutputDevice, queue: *TimerQueue) !void
    pub fn notifyTriggerReleased(self: *MacroPlayer) void
};
```

Execution per `resume()`:

| Step type | Action |
|-----------|--------|
| `tap(key)` | press → sync → release → sync; advance; continue |
| `down(key)` | press → sync; advance; continue |
| `up(key)` | release → sync; advance; continue |
| `delay(ms)` | arm `TimerQueue` deadline at `now + ms`; return |
| `pause_for_release` | set `waiting_for_release = true`; return |
| end of steps | caller removes player from `active_macros` |

`src/core/mapper.zig` additions:

```zig
active_macros: std.ArrayList(MacroPlayer),
timer_queue: TimerQueue,
```

`Mapper.apply` integrations:
- Remap target `.macro` → look up `Macro` by name → create `MacroPlayer` → append to `active_macros`.
- After fd processing, call `resume()` on all active players.
- Layer switch → drain `active_macros`: emit up-event for any held key, then clear list.

`src/event_loop.zig` change: single timerfd slot replaced by `TimerQueue`; on timerfd ready call `timer_queue.drainExpired()`.

**Tests (L0/L1)**:
- `tap(B)` step → `press B` then `release B` emitted in order
- `delay(50)` → timerfd armed at `now + 50 ms`; `resume()` called again after expiry; subsequent steps execute
- `pause_for_release` → player halts; `notifyTriggerReleased()` → `resume()` continues
- Layer switch → `active_macros` cleared; any held key receives an up-event; no residual key-down
- Two concurrent MacroPlayers → each advances its own `step_index` independently
- TimerQueue: tap-hold + macro delay deadlines coexist; earliest deadline wins; `drainExpired()` dispatches all overdue entries in one call

---

## T5: Auto-discover

**Files**: `src/io/hidraw.zig` (extend), `src/main.zig` (extend), `src/supervisor.zig` (extend)

**Changes**:

`HidrawDevice.discoverAll(vid: u16, pid: u16) ![][:0]const u8` — returns all `/dev/hidraw*` paths matching the given VID/PID. Physical path (`HIDIOCGRAWPHYS`) serves as the unique key.

CLI extension:

```
padctl --config devices/flydigi-vader5.toml      # single file (backward-compatible)
padctl --config-dir /etc/padctl/devices.d/       # glob *.toml
```

Supervisor config-directory scan:
1. Glob `*.toml` in the directory; parse each for `[device] vid`/`pid`.
2. For each config call `discoverAll(vid, pid)`.
3. Collect `(physical_path, config)` pairs; deduplicate by physical path.
4. Create one DeviceInstance per unique pair; spawn thread.

**Tests (L1)**:
- Two configs with distinct VID/PID → two DeviceInstances created
- Same VID/PID, two `/dev/hidraw*` nodes with different physical paths → two DeviceInstances
- Same VID/PID matched by two config files, same physical path → deduplicated to one DeviceInstance
- Config directory empty → zero instances; Supervisor exits cleanly

---

## T6: SIGHUP hot-reload

**Files**: `src/supervisor.zig` (extend), `src/device_instance.zig` (extend)

**Changes**:

On SIGHUP, Supervisor:
1. Re-scans config source (file list or directory).
2. Computes diff against running instances keyed by physical path:
   - **New** path → discover device → create DeviceInstance → spawn thread.
   - **Removed** path → `DeviceInstance.stop()` → join → free.
   - **Changed mapping** → parse new `MappingConfig` → `DeviceInstance.updateMapping(new)` → writes stop_pipe to wake ppoll.
3. Consecutive SIGHUPs are serialized: second reload begins only after first completes.

`updateMapping` atomic protocol (already specified in T1): release store into `pending_mapping`; DeviceInstance acquire-loads at the top of the next ppoll iteration.

**Tests (L1)**:
- SIGHUP → mapping updated; DeviceInstance not restarted; new mapping effective within one ppoll cycle
- SIGHUP → new config file added → new DeviceInstance spawned
- SIGHUP → config file removed → DeviceInstance stopped and joined
- Two rapid SIGHUPs → second reload starts only after first completes; no race condition

---

## T7: End-to-end integration test

**Files**: `src/test/phase2c_e2e_test.zig` (new)

**Scenarios**:

**Multi-device parallel (L1)**:
- Two mock DeviceInstances, each with independent EventLoop and output sink
- Events injected into device A produce no change in device B state
- `DeviceInstance.stop()` on A → A's thread exits; B continues running unaffected

**Macro playback (L0/L1)**:
- Config: `M1 = "macro:dodge_roll"` (tap B, delay 50, tap LEFT)
- M1 pressed → B press+release emitted → timerfd 50 ms → LEFT press+release emitted
- Config: `M2 = "macro:shift_hold"` (down LSHIFT, pause_for_release, up LSHIFT)
- Trigger held → LSHIFT down emitted; trigger released → LSHIFT up emitted

**Hot-reload (L1)**:
- Running with `M1 = "macro:dodge_roll"` → send SIGHUP → mapping replaced with `M1 = "KEY_A"` → M1 press produces KEY_A, not macro
- DeviceInstance not restarted; mapping swap latency < one ppoll cycle

**Layer 2 manual (local device required)**:
- Two controllers connected simultaneously → each produces independent uinput output
- Macro triggered on controller A → correct key sequence emitted; controller B unaffected
- `zig build test` (L0 + L1) passes; L2 scenarios use `error.SkipZigTest` guard

All L0 + L1 scenarios run under `zig build test` and must pass in CI. L2 scenarios skip when no real device is present.

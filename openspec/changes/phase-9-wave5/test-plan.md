# Phase 9 Wave 5: Test Plan — inotify Hot-Reload + Battery Extraction (T17/T19a)

Each test maps to a success criterion in `brief.md`.

## T17: inotify Tests

### Unit Tests: Supervisor inotify (in `src/supervisor.zig`)

- [ ] TP1: **inotify_fd created and valid** — `Supervisor.init()` with a valid config dir
  path produces `inotify_fd >= 0` and `debounce_fd >= 0`.

- [ ] TP2: **missing config dir degrades gracefully** — `Supervisor.init()` with a
  nonexistent directory path produces `inotify_fd == -1`. No crash, ppoll loop still
  handles stop/hup/netlink normally.

- [ ] TP3: **initForTest disables inotify** — `Supervisor.initForTest()` produces
  `inotify_fd == -1` and `debounce_fd == -1`.

- [ ] TP4: **file write triggers debounce arm** — create temp dir, init Supervisor
  watching it. Write a file into the dir. Verify `debounce_fd` becomes readable
  after ~500ms (poll with 600ms timeout).

- [ ] TP5: **debounce coalesces rapid writes** — write 5 files into watched dir within
  100ms. Verify only one debounce_fd expiry occurs (not 5). Read the timerfd, verify
  exactly one 8-byte read succeeds, subsequent read returns EAGAIN.

- [ ] TP6: **debounce re-arm resets timer** — write file, wait 300ms, write another file.
  Timer should fire ~500ms after the second write (total ~800ms from first write), not
  500ms from the first write.

- [ ] TP7: **SIGHUP still works alongside inotify** — with inotify active, sending
  SIGHUP still triggers immediate reload (existing test remains valid).

- [ ] TP8: **IN_MOVED_TO detected** — write file to temp location outside watched dir,
  then `rename()` it into the watched dir. Verify debounce timer arms.

### Unit Tests: ppoll fd management

- [ ] TP9: **ppoll with all 5 fds** — Supervisor with valid netlink + valid inotify uses
  nfds=5. No fd is skipped.

- [ ] TP10: **ppoll with inotify disabled** — Supervisor with `inotify_fd == -1`. ppoll
  uses pollfds with fd=-1 for inotify/debounce slots (ignored by kernel). No hang, no error.

## T19a: Battery Level Tests

### Unit Tests: GamepadState (in `src/core/state.zig`)

- [ ] TP11: **applyDelta: battery_level** — `applyDelta(.{ .battery_level = 8 })` on
  default state sets `battery_level == 8`. Other fields unchanged.

- [ ] TP12: **diff: battery_level changed** — `GamepadState{ .battery_level = 5 }.diff(GamepadState{})`
  produces `delta.battery_level == 5`.

- [ ] TP13: **diff: battery_level unchanged** — two states with same `battery_level`.
  `delta.battery_level == null`.

### Unit Tests: Interpreter (in `src/core/interpreter.zig`)

- [ ] TP14: **parseFieldTag("battery_level") returns .battery_level** — direct enum check.

- [ ] TP15: **applyFieldTag battery_level** — `applyFieldTag(&delta, .battery_level, 8)`
  sets `delta.battery_level == 8`.

- [ ] TP16: **DualSense USB report: battery_level extracted** — parse `dualsense.toml`,
  construct 64-byte USB report with byte 53 = `0x38` (bits[3:0] = 8, bits[7:4] = 3).
  `processReport` returns delta with `battery_level == 8` (only lower nibble).

- [ ] TP17: **DualSense BT report: battery_level extracted** — parse `dualsense.toml`,
  construct 78-byte BT report with byte 54 = `0x2A` (bits[3:0] = 10, bits[7:4] = 2).
  `processReport` returns delta with `battery_level == 10`.

### Unit Tests: Device Config Parse (in `src/config/device.zig`)

- [ ] TP18: **dualsense.toml field count unchanged** — after renaming `battery_raw` to
  `battery_level` and switching to bits DSL, the total field count per report remains
  the same (USB: 16, BT: 16).

- [ ] TP19: **battery_level field uses bits DSL** — parsed USB report field named
  `battery_level` has `bits` set (not `offset + type`). `bits[0] == 53, bits[1] == 0,
  bits[2] == 4`.

## Regression Guard

- [ ] TP20: All existing `supervisor.zig` tests pass (SIGHUP reload, attach/detach, etc.)
- [ ] TP21: All existing `state.zig` tests pass (applyDelta, diff)
- [ ] TP22: All existing `interpreter.zig` tests pass (DualSense USB/BT, touchpad, etc.)
- [ ] TP23: All existing `device.zig` tests pass (field validation, bits, etc.)
- [ ] TP24: All existing `event_loop.zig` tests pass
- [ ] TP25: All fuzz tests pass unchanged

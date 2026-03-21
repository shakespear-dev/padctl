# Tasks: Phase 9 Wave 5 — inotify Hot-Reload + Battery Extraction (T17/T19a)

Branch: `feat/phase-9-wave5`
Commit: (leave blank -- filled after implementation)

## Execution Plan

T17 and T19a are independent — can be implemented in any order or in parallel.
Within each task, sub-steps are sequential.

---

## T17: inotify Config Hot-Reload

### T17a: Add inotify_fd and debounce_fd to Supervisor

- [ ] Add fields to `Supervisor` struct:
  ```zig
  inotify_fd: posix.fd_t,
  debounce_fd: posix.fd_t,
  ```

- [ ] In `Supervisor.init()`, after `hup_fd` setup:
  - Create inotify instance with `IN.CLOEXEC | IN.NONBLOCK`
  - Add watch on config dir with `IN_CLOSE_WRITE | IN_MOVED_TO`
  - Create timerfd with `MONOTONIC, CLOEXEC | NONBLOCK`
  - On failure: set `inotify_fd = -1`, `debounce_fd = -1` (graceful degradation)

- [ ] In `Supervisor.initForTest()`: set `inotify_fd = -1`, `debounce_fd = -1`

- [ ] In `Supervisor.deinit()`: close both fds if >= 0

### T17b: Extend ppoll loop

- [ ] Extend pollfds array from 3 to 5 slots:
  - Slot 3: `inotify_fd`
  - Slot 4: `debounce_fd`

- [ ] Compute `nfds` accounting for inotify/debounce availability:
  - If `netlink_fd >= 0` and `inotify_fd >= 0`: nfds = 5
  - If `netlink_fd >= 0` and `inotify_fd < 0`: nfds = 3
  - If `netlink_fd < 0` and `inotify_fd >= 0`: nfds = 4 (reorder slots)
  - If both < 0: nfds = 2

  Simplification: keep fixed slot positions. Invalid fds use `fd = -1` which ppoll ignores.

- [ ] Handle inotify_fd readable:
  - Drain all pending inotify events (read into buffer, discard contents)
  - Call `armDebounce()` to (re-)arm the 500ms timer

- [ ] Handle debounce_fd readable:
  - Drain timerfd (read 8-byte u64)
  - Call `reloadFn` + `self.reload()` (same code path as SIGHUP handler)

### T17c: armDebounce helper

- [ ] Add `armDebounce` method to Supervisor:
  - `linux.timerfd_settime(debounce_fd, .{}, &spec, null)` — use `linux` namespace
    consistently (timerfd_settime is in `std.os.linux`, not `posix`; same pattern as
    `event_loop.zig`)
  - Re-arming a running timer resets the countdown (timerfd semantics)

### T17d: Config dir path resolution

- [ ] Accept config dir path as parameter to `Supervisor.init()` (not `run()`)
- [ ] Default: `$XDG_CONFIG_HOME/padctl/` or `~/.config/padctl/`
- [ ] If directory doesn't exist: skip inotify setup (`inotify_fd = -1`)

---

## T19a: Battery Level Field

### T19a-a: Add battery_level to GamepadState

- [ ] Add `battery_level: u8 = 0` to `GamepadState` struct
- [ ] Add `battery_level: ?u8 = null` to `GamepadStateDelta` struct
- [ ] Add `battery_level` comparison to `diff()`:
  ```zig
  if (self.battery_level != prev.battery_level) d.battery_level = self.battery_level;
  ```
- [ ] Add `battery_level` application to `applyDelta()`:
  ```zig
  if (delta.battery_level) |v| self.battery_level = v;
  ```

### T19a-b: Add battery_level to interpreter FieldTag

- [ ] Add `battery_level` variant to `FieldTag` enum (before `unknown`)
- [ ] Add to `parseFieldTag`:
  ```zig
  if (std.mem.eql(u8, name, "battery_level")) return .battery_level;
  ```
- [ ] Add to `applyFieldTag`:
  ```zig
  .battery_level => delta.battery_level = @intCast(val & 0xff),
  ```

### T19a-c: Update DualSense TOML

- [ ] In USB report: rename `battery_raw` to `battery_level`, use bits DSL:
  ```toml
  battery_level = { bits = [53, 0, 4] }
  ```
- [ ] In BT report: rename `battery_raw` to `battery_level`, use bits DSL:
  ```toml
  battery_level = { bits = [54, 0, 4] }
  ```
- [ ] Update field comments to describe the extraction

---

## Post-merge wrap-up

- [ ] Archive this OpenSpec
- [ ] Update `planning/roadmap.md` Phase 9 Wave 5 status

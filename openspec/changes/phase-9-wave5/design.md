# Design: Phase 9 Wave 5 — inotify Hot-Reload + Battery Extraction (T17/T19a)

## Files

| File | Role |
|------|------|
| `src/supervisor.zig` | Add inotify_fd + debounce timerfd to Supervisor, extend ppoll |
| `src/core/state.zig` | Add `battery_level` to GamepadState / GamepadStateDelta |
| `src/core/interpreter.zig` | Add `battery_level` to FieldTag, parseFieldTag, applyFieldTag |
| `devices/sony/dualsense.toml` | Rename `battery_raw` to `battery_level`, add mask transform |

---

## T17: inotify Config Hot-Reload

### Current SIGHUP Mechanism

`Supervisor.init()` creates a signalfd for SIGHUP (`hup_fd`). The `run()` ppoll loop
watches `hup_fd` — when readable, it drains the signal and calls `reloadFn` + `self.reload()`.
This works but requires the user to manually `kill -HUP <pid>`.

### inotify Design

Add an inotify fd watching the user config directory (`~/.config/padctl/`). When a file
is written or moved into the directory, arm a 500ms one-shot timerfd. When the timer fires,
call the same `reloadFn` + `self.reload()` path.

#### New Fields in Supervisor

```zig
inotify_fd: posix.fd_t,       // inotify instance fd
debounce_fd: posix.fd_t,      // timerfd for 500ms debounce
config_dir: []const u8,        // watched directory path (owned)
```

#### Init

Config dir path is accepted as a parameter to `Supervisor.init()` (alongside existing
allocator and config parameters). The inotify watch is created during init, consistent
with how `netlink_fd` and `hup_fd` are set up in the same init path.

```zig
// In Supervisor.init(), after hup_fd setup:
const inotify_fd = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
// inotify_add_watch(inotify_fd, config_dir, IN_CLOSE_WRITE | IN_MOVED_TO)
const debounce_fd = posix.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
```

`IN_CLOSE_WRITE` catches normal editor saves. `IN_MOVED_TO` catches atomic-rename patterns
(e.g., vim writes to a temp file then renames). Together they cover all common editor
save strategies.

`IN_MODIFY` is intentionally excluded — it fires on every partial write, producing
spurious reloads on large files.

#### ppoll Extension

Current ppoll watches 3 fds: `[stop_fd, hup_fd, netlink_fd]`. Extend to 5:

```zig
var pollfds = [5]posix.pollfd{
    .{ .fd = self.stop_fd, ... },
    .{ .fd = self.hup_fd, ... },
    .{ .fd = self.netlink_fd, ... },
    .{ .fd = self.inotify_fd, ... },
    .{ .fd = self.debounce_fd, ... },
};
```

The inotify_fd and debounce_fd slots are conditional (like netlink_fd): if inotify_fd < 0
(init failed), `nfds` excludes both inotify and debounce slots.

#### Event Flow

```
editor saves file
    → inotify_fd readable (IN_CLOSE_WRITE)
    → drain inotify events (read all pending)
    → arm debounce_fd: 500ms one-shot timerfd
    → (more saves within 500ms re-arm the timer, resetting countdown)
    → debounce_fd fires after 500ms quiet period
    → call reloadFn + self.reload() (same path as SIGHUP)
```

#### Debounce via timerfd

The existing `armTimerfd` / `disarmTimerfd` helpers in `event_loop.zig` provide the pattern.
Supervisor adds equivalent inline logic (no dependency on EventLoop):

```zig
fn armDebounce(self: *Supervisor) void {
    const spec = linux.itimerspec{
        .it_value = .{ .sec = 0, .nsec = 500_000_000 },
        .it_interval = .{ .sec = 0, .nsec = 0 },
    };
    _ = linux.timerfd_settime(self.debounce_fd, .{}, &spec, null);
}
```

Re-arming while already armed resets the countdown — this is the standard timerfd behavior,
no explicit disarm needed.

#### SIGHUP Backward Compatibility

The existing SIGHUP handler remains unchanged. SIGHUP triggers immediate reload (no debounce).
inotify and SIGHUP are independent trigger sources for the same reload path.

#### P9 Testability

`initForTest` sets `inotify_fd = -1` and `debounce_fd = -1`, disabling the inotify path
in test mode. For inotify-specific tests, use a temporary directory:

```zig
// Create temp dir, init inotify watching it, write a file, verify debounce timer arms
```

The inotify/timerfd logic is a thin syscall wrapper — the interesting behavior (debounce
coalescing) is testable with real kernel fds (Layer 1, no privileges needed beyond
filesystem access).

---

## T19a: Battery Level Extraction

### Current State

`dualsense.toml` declares `battery_raw = { offset = 53, type = "u8" }`. The interpreter
parses this field from the HID report, but `parseFieldTag("battery_raw")` returns `.unknown`,
so `applyFieldTag` discards the value.

`GamepadState` has no battery field.

### Design

#### 1. Add `battery_level` to GamepadState

```zig
pub const GamepadState = struct {
    // ... existing fields ...
    battery_level: u8 = 0,
    // ...
};
```

And the corresponding delta field:

```zig
pub const GamepadStateDelta = struct {
    // ... existing fields ...
    battery_level: ?u8 = null,
    // ...
};
```

Update `diff()` and `applyDelta()` accordingly (mechanical, follows existing pattern).

#### 2. Add `battery_level` to FieldTag

In `src/core/interpreter.zig`:

```zig
const FieldTag = enum {
    // ... existing tags ...
    battery_level,
    unknown,
};

fn parseFieldTag(name: []const u8) FieldTag {
    // ... existing entries ...
    if (std.mem.eql(u8, name, "battery_level")) return .battery_level;
    return .unknown;
}

fn applyFieldTag(delta: *GamepadStateDelta, tag: FieldTag, val: i64) void {
    switch (tag) {
        // ... existing arms ...
        .battery_level => delta.battery_level = @intCast(val & 0xff),
        .unknown => {},
    }
}
```

#### 3. Update DualSense TOML

Rename `battery_raw` to `battery_level` and add a bitmask transform to extract only
the level nibble (bits [3:0], range 0-10):

```toml
# Battery: bits[3:0]=level(0-10), bits[7:4]=status (ignored for now)
battery_level = { offset = 53, type = "u8", transform = "mask(0x0f)" }
```

However, `mask` is not currently a supported transform op (existing transforms are:
`negate`, `abs`, `scale`, `clamp`, `deadzone`). Two options:

**Option A — Use bits DSL** (already implemented in Phase 9 Wave 2, T4):
```toml
battery_level = { bits = [53, 0, 4] }  # byte 53, start bit 0, 4 bits
```
This extracts bits[3:0] directly as a 4-bit unsigned integer (0-15). This is the
cleaner approach — bits DSL was designed for exactly this kind of sub-byte extraction.

**Option B — Pass raw u8, extract in future**: Keep `type = "u8"` and store the full byte.
Consumer code masks the nibble when needed.

**Decision: Option A (bits DSL)**. The bits DSL is already implemented and this is its
intended use case. The battery level field in DualSense is a 4-bit sub-byte field.

BT report uses the same layout at offset 54:
```toml
battery_level = { bits = [54, 0, 4] }  # BT: battery at byte 54
```

#### DualSense Touch Contact Fields

`dualsense.toml` 中 `touch0_contact` / `touch1_contact` 仍使用 `type = "u8"` 而非 bits DSL。
DualSense 触摸板的 contact 字段布局 (bit7=inactive, bits[6:0]=finger ID) 与 battery level
的简单 nibble 提取不同 — 需要同时提取 active 标志位和 finger ID 两个语义字段。当 DualSense
触摸板支持正式实现时 (不在 Wave 5 范围内), 将统一迁移到 bits DSL。

#### Output Device Impact

`battery_level` is an internal state field, not an evdev output axis. It does not appear
in `[output.axes]` or `[output.buttons]`. The uinput output layer is unaffected.

Future use: logging, status display, or (if ever implemented) UPower integration. For now
it simply populates `GamepadState.battery_level` for any consumer that reads state.

---

## Key Design Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | inotify watches directory, not individual files | Files may be created/deleted; directory watch is stable across renames. |
| D2 | IN_CLOSE_WRITE + IN_MOVED_TO, not IN_MODIFY | IN_MODIFY fires on every partial write. CLOSE_WRITE fires once after write completes. MOVED_TO catches atomic-rename saves. |
| D3 | 500ms timerfd debounce, re-arm on each event | Coalesces rapid saves (editor autosave, multi-file edits). Standard timerfd re-arm behavior resets countdown automatically. |
| D4 | SIGHUP preserved alongside inotify | Backward compatibility. Scripted workflows may rely on SIGHUP. |
| D5 | inotify_fd = -1 in initForTest | Keeps existing tests unaffected. inotify-specific tests create their own instance. |
| D6 | battery_level via bits DSL, not raw u8 | DualSense battery is a 4-bit nibble. bits DSL extracts it cleanly without a new mask transform. |
| D7 | battery_level is u8 in GamepadState | Range 0-10 fits in u8. Consistent with lt/rt field type. |
| D8 | No output device changes for battery | Battery is internal state, not an evdev axis. uinput layer unchanged. |

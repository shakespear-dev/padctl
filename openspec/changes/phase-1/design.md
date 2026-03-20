# Design: padctl Phase 1

## Architecture

```
src/
├── main.zig              # daemon entry, ppoll event loop, signalfd
├── cli.zig               # --config / --mapping / --validate argument parsing
├── core/
│   ├── state.zig         # GamepadState, GamepadStateDelta, ButtonId
│   ├── interpreter.zig   # processReport() 5-step pipeline
│   └── remap.zig         # Phase 1 simplified remap (no Layer/suppress/inject)
├── io/
│   ├── ioctl_constants.zig  # centralized ioctl constant definitions
│   ├── hidraw.zig           # hidraw backend, discover(), grabAssociatedEvdev()
│   ├── uinput.zig           # UinputDevice, AuxDevice (minimal), OutputDevice vtable
│   └── usbraw.zig           # libusb backend, ring buffer, reader thread
├── config/
│   ├── toml.zig          # sam701/zig-toml parse/free lifecycle wrapper
│   ├── device.zig        # DeviceConfig + OutputConfig schema + load-time validation
│   └── mapping.zig       # MappingConfig schema (Phase 1: [remap] section only)
└── test/
    ├── mock_device_io.zig   # MockDeviceIO vtable (frames replay + write_log)
    └── mock_output.zig      # MockOutput vtable (GamepadState sequence recording)
```

## Interface Changes

### Core State Types

```zig
// src/core/state.zig

pub const ButtonId = enum(u8) {
    A, B, X, Y,
    LB, RB,
    LT_digital, RT_digital,
    SELECT, START, HOME,
    L3, R3,
    DPAD_UP, DPAD_DOWN, DPAD_LEFT, DPAD_RIGHT,
    C, Z,
    M1, M2, M3, M4,
    LM, RM,
    O,
    TOUCHPAD,
    _count,
};

pub const GamepadStateDelta = struct {
    left_x:  ?i16 = null,
    left_y:  ?i16 = null,
    right_x: ?i16 = null,
    right_y: ?i16 = null,
    lt:      ?u8  = null,
    rt:      ?u8  = null,
    gyro_x:  ?i16 = null,
    gyro_y:  ?i16 = null,
    gyro_z:  ?i16 = null,
    accel_x: ?i16 = null,
    accel_y: ?i16 = null,
    accel_z: ?i16 = null,
    buttons: [@intFromEnum(ButtonId._count)]?bool =
        [_]?bool{null} ** @intFromEnum(ButtonId._count),
    dpad: ?[4]bool = null,
};

pub const GamepadState = struct {
    left_x:  i16 = 0,
    left_y:  i16 = 0,
    right_x: i16 = 0,
    right_y: i16 = 0,
    lt:      u8  = 0,
    rt:      u8  = 0,
    gyro_x:  i16 = 0,
    gyro_y:  i16 = 0,
    gyro_z:  i16 = 0,
    accel_x: i16 = 0,
    accel_y: i16 = 0,
    accel_z: i16 = 0,
    buttons: [@intFromEnum(ButtonId._count)]bool =
        [_]bool{false} ** @intFromEnum(ButtonId._count),
    dpad: [4]bool = [_]bool{false} ** 4,
};
```

### DeviceIO vtable (`src/io/`)

```zig
pub const DeviceIO = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read:    *const fn (ptr: *anyopaque, buf: []u8) ReadError!usize,
        write:   *const fn (ptr: *anyopaque, data: []const u8) WriteError!void,
        pollfd:  *const fn (ptr: *anyopaque) std.posix.pollfd,
        close:   *const fn (ptr: *anyopaque) void,
    };

    pub const ReadError  = error{ Again, Disconnected, Io };
    pub const WriteError = error{ Disconnected, Io };
};
```

### OutputDevice vtable (`src/io/uinput.zig`)

```zig
pub const OutputDevice = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        emit:   *const fn (ptr: *anyopaque, state: GamepadState) anyerror!void,
        pollFf: *const fn (ptr: *anyopaque) anyerror!?FfEvent,
        close:  *const fn (ptr: *anyopaque) void,
    };
};

pub const AuxOutputDevice = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        emitAux: *const fn (ptr: *anyopaque, events: []const AuxEvent) anyerror!void,
        close:   *const fn (ptr: *anyopaque) void,
    };
};

pub const FfEvent = struct {
    effect_type: u16,
    strong:      u16,
    weak:        u16,
};

pub const AuxEvent = union(enum) {
    rel:          struct { code: u16, value: i32 },
    key:          struct { code: u16, pressed: bool },
    mouse_button: struct { code: u16, pressed: bool },
};

pub const UinputDevice = struct {
    fd:   std.posix.fd_t,
    prev: GamepadState,

    pub fn create(cfg: *const OutputConfig) !UinputDevice;
    pub fn outputDevice(self: *UinputDevice) OutputDevice;
    pub fn emit(self: *UinputDevice, state: GamepadState) !void;
    pub fn pollFf(self: *UinputDevice) !?FfEvent;
    pub fn close(self: *UinputDevice) void;
};

pub const AuxDevice = struct {
    fd: std.posix.fd_t,

    pub fn create(cfg: *const OutputAuxConfig) !AuxDevice;
    pub fn auxOutputDevice(self: *AuxDevice) AuxOutputDevice;
    pub fn emitAux(self: *AuxDevice, events: []const AuxEvent) !void;
    pub fn close(self: *AuxDevice) void;
};
```

### Interpreter (`src/core/interpreter.zig`)

```zig
pub const Interpreter = struct {
    config: *const DeviceConfig,

    pub fn processReport(
        self: *Interpreter,
        interface_id: u8,
        raw: []const u8,
    ) ProcessError!?GamepadStateDelta;

    pub const ProcessError = error{ ChecksumMismatch, MalformedConfig };
};
```

`processReport` is stateless: identical inputs always produce identical outputs.

### DeviceConfig / OutputConfig (`src/config/device.zig`)

Key structs (abbreviated — see engineering specs for full field lists):

```zig
pub const DeviceConfig = struct {
    device:   DeviceInfo,
    reports:  []ReportSpec,
    commands: std.StringHashMap(CommandTemplate),
    output:   OutputConfig,
};

pub const OutputConfig = struct {
    name: []const u8,
    vid:  u16,
    pid:  u16,
    axes:            std.StringHashMap(AxisSpec),
    buttons:         std.StringHashMap(u16),  // ButtonId name → resolved BTN code
    dpad:            DpadOutputConfig,
    force_feedback:  ?FfConfig,
    aux:             ?OutputAuxConfig,
};

pub const OutputAuxConfig = struct {
    name:          []const u8,
    keys:          []u16,   // resolved KEY_* codes inferred from remap targets
    mouse_buttons: []u16,   // resolved BTN_* codes
};
```

## Implementation Notes

### ioctl Constant Construction

`translate-c` cannot expand `_IOW`/`_IOR`/`_IO`/`_IOWR` macros (Zig issue #7376).
All ioctl constants are defined in `src/io/ioctl_constants.zig` using
`std.os.linux.ioctl.IOR/IOW/IO` with structs obtained via `@cImport`. No magic numbers
are written by hand. Required constants:

```
HIDIOCGRAWINFO, HIDIOCGRAWPHYS (fixed 256B buffer),
EVIOCGRAB,
UI_DEV_CREATE, UI_DEV_SETUP, UI_ABS_SETUP,
UI_SET_EVBIT, UI_SET_ABSBIT, UI_SET_KEYBIT, UI_SET_FFBIT
```

### @cImport Usage

`linkLibC()` in `build.zig` adds libc include paths, making Linux kernel headers
visible to `@cImport` without additional `addIncludePath` calls. This covers:
- `linux/hidraw.h` — `hidraw_devinfo`, `hidraw_report_descriptor`
- `linux/uinput.h` — `uinput_setup`, `uinput_abs_setup`, `input_event`
- `linux/input-event-codes.h` — ABS_* and BTN_* constants for code resolution

### ABS/BTN Code Resolution

`resolveAbsCode` and `resolveBtnCode` execute at config load time. They iterate a
comptime-generated table built from `@cImport` constants. Unknown codes return
`error.UnknownAbsCode` / `error.UnknownBtnCode` at startup, never at runtime.

### CRC32 Seed Semantics

The DSL `checksum.seed` field is a **prefix byte**, not the initial CRC value.
Processing order: `crc.update(&[_]u8{seed})` first, then `crc.update(data[range])`,
then `crc.final()`. `Crc32IsoHdlc` initial value remains the standard `0xFFFFFFFF`.
This matches Linux `crc32_le(0xFFFFFFFF, &seed, 1)` behavior.

### usbraw Ring Buffer

Capacity: `max_report_size * 16` (≈1.6 seconds of backlog at 100Hz). On overflow,
the oldest report is dropped and a warning is logged. The reader thread exits cleanly:
`close()` sets an atomic `should_stop` flag; the thread checks it after each
`libusb_interrupt_transfer` timeout (100ms), then exits; `close()` calls `thread.join()`
before closing pipe fds.

### ppoll Event Loop Layout

```zig
const MAX_FDS = 8;
// [0..n_interfaces-1]  — DeviceIO pollfds (hidraw or usbraw pipe)
// [n_interfaces]       — signalfd (SIGTERM/SIGINT)
// [n_interfaces+1]     — uinput FF fd (pollFf events)
// [n_interfaces+2]     — timerfd slot (reserved, nfds excludes this in Phase 1)
```

`runEventLoop` is extracted as a standalone function taking `fds: []pollfd` to
enable Layer 1 mock injection without touching `main()`.

### Conditional Fields via Multi-Report Grouping

Phase 1 implements conditional field semantics by placing fields in the correct
`[[report]]` entry. The IF1 extended report contains gyro/accel fields; the IF0
standard report does not. `GamepadStateDelta` Optional semantics (null = retain
previous value) automatically handle the missing-field case. No `condition`/`when`
DSL keyword is needed.

### Phase 1 Remap Constraints

The `src/core/remap.zig` skeleton provides simplified remap without Layer, suppress
pipeline, or tap-hold. For each frame, declared remaps are applied: the source button
is suppressed and the target is injected. `key` and `mouse_button` targets route to
`AuxDevice`; `gamepad_button` targets route to the main `OutputDevice`. This is
sufficient for the M1 → KEY_F13 use case.

`AuxDevice` in Phase 1 registers only KEY/BTN capabilities inferred from remap
targets. When no `key`/`mouse_button` remap targets are declared, `AuxDevice` is
not created.

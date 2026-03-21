# Phase 2b Tasks

## Dependency Graph

```
Wave 0 (parallel, no deps):
  T1  uinput fd O_RDWR + pollfds registration + pollFf drain loop
  T2  fillTemplate — src/core/command.zig

Wave 1 (parallel, depends T1 + T2):
  T3  ff_effects[16] storage + upload/play/erase full handling   ← T1
  T4  FF event → fillTemplate → DeviceIO.write routing           ← T2, T3

Wave 2 (parallel, depends T4):
  T5  gyro.activate hold_<Name> parse + check before step [3]   ← T4
  T6  gyro joystick mode: emit_state.rx/ry override + suppress   ← T5
  T7  layer switch reset gyro/stick processors                   ← T5
  T8  dt_ms nanoTimestamp delta, Mapper.apply(delta, dt_ms)      ← T4

Wave 3:
  T9  end-to-end integration test                                ← T5,T6,T7,T8
```

> Layer column: L0 = pure functions, always CI; L1 = mock vtable/fd, always CI; L2 = real device, local manual.

---

## T1: uinput fd O_RDWR + pollfds registration + pollFf drain loop

**Files**: `src/io/uinput.zig`, `src/event_loop.zig`

**Changes**:

1. `UinputDevice.create`: change `O{ .ACCMODE = .WRONLY, .NONBLOCK = true }` to `O{ .ACCMODE = .RDWR, .NONBLOCK = true }`.
2. `EventLoop`: add uinput fd slot to `pollfds` with `POLL.IN`. On ppoll ready, call `pollFf()`.
3. `UinputDevice.pollFf`: replace current single-read body with drain loop:

```zig
var result: ?FfEvent = null;
while (true) {
    var ev: c.input_event = undefined;
    const n = std.posix.read(self.fd, std.mem.asBytes(&ev)) catch |err| switch (err) {
        error.WouldBlock => break,
        else => return err,
    };
    if (n != @sizeOf(c.input_event)) break;
    // upload / erase / play branches (T3)
}
return result;
```

**Tests (L1)**:
- fd opened `O_RDWR`: both read and write succeed (no `EBADF`)
- pollfds contains uinput fd; `nfds` incremented correctly
- empty drain loop (no events): returns `null` immediately, no block

---

## T2: fillTemplate — src/core/command.zig (new file)

**Files**: `src/core/command.zig`

**Interface**:

```zig
pub const Param = struct { name: []const u8, value: u16 };

pub fn fillTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    params: []const Param,
) ![]u8
```

**Parsing rules** (space-delimited tokens):
- `{name:u8}` — find `name` in `params`; emit `@intCast(u8, value >> 8)`
- otherwise — `std.fmt.parseInt(u8, token, 16)`, fail with `error.InvalidHexByte` if out of range
- unknown name → `error.UnknownParam`
- unknown type → `error.UnsupportedParamType`

**Tests (L0)**:
- `"00 08 00 {strong:u8} {weak:u8} 00 00 00"`, `strong=0x8000`, `weak=0x4000` → `[8]u8{0,8,0,0x80,0x40,0,0,0}`
- pure hex template (no placeholders) parses correctly
- unknown param name → `error.UnknownParam`
- unknown type (e.g. `{x:u16}`) → `error.UnsupportedParamType`
- hex literal > 255 (e.g. `"1FF"`) → `error.InvalidHexByte`

---

## T3: ff_effects[16] storage + upload/play/erase full handling

**Files**: `src/io/uinput.zig`

**Changes**:

Add to `UinputDevice`:
```zig
ff_effects: [16]FfEffect = [_]FfEffect{.{}} ** 16,

pub const FfEffect = struct { strong: u16 = 0, weak: u16 = 0 };
```

In `pollFf` drain loop, handle three event types:

```zig
// Upload
if (ev.type == c.EV_UINPUT and ev.code == c.UI_FF_UPLOAD) {
    var upload: c.uinput_ff_upload = undefined;
    upload.request_id = @bitCast(ev.value);
    try ioctlPtr(self.fd, UI_BEGIN_FF_UPLOAD, @intFromPtr(&upload));
    if (upload.effect.type == c.FF_RUMBLE and upload.effect.id < 16) {
        self.ff_effects[@intCast(upload.effect.id)] = .{
            .strong = upload.effect.u.rumble.strong_magnitude,
            .weak   = upload.effect.u.rumble.weak_magnitude,
        };
    }
    upload.retval = 0;
    try ioctlPtr(self.fd, UI_END_FF_UPLOAD, @intFromPtr(&upload));
}

// Erase
if (ev.type == c.EV_UINPUT and ev.code == c.UI_FF_ERASE) {
    var erase: c.uinput_ff_erase = undefined;
    erase.request_id = @bitCast(ev.value);
    try ioctlPtr(self.fd, UI_BEGIN_FF_ERASE, @intFromPtr(&erase));
    if (erase.effect_id < 16) self.ff_effects[@intCast(erase.effect_id)] = .{};
    erase.retval = 0;
    try ioctlPtr(self.fd, UI_END_FF_ERASE, @intFromPtr(&erase));
}

// Play
if (ev.type == c.EV_FF and ev.code < 16) {
    result = if (ev.value > 0)
        FfEvent{ .effect_type = c.FF_RUMBLE, .strong = self.ff_effects[ev.code].strong, .weak = self.ff_effects[ev.code].weak }
    else
        FfEvent{ .effect_type = c.FF_RUMBLE, .strong = 0, .weak = 0 };
}
```

**Tests (L0/L1)**:
- upload effect id=2, strong=0xffff, weak=0x8000 → `ff_effects[2]` fields correct
- play value=1 → returns `FfEvent{strong=0xffff, weak=0x8000}`
- play value=0 (stop) → returns `FfEvent{strong=0, weak=0}`
- erase effect id=2 → `ff_effects[2]` zeroed
- upload id ≥ 16 → handshake completes, ff_effects unchanged, no panic

---

## T4: FF event → fillTemplate → DeviceIO.write routing

**Files**: `src/event_loop.zig`

**Changes**:

After `pollFf()` returns, route the event:

```zig
if (ff_event) |ff| {
    const cmd = device_config.commands.rumble orelse continue;
    const bytes = try fillTemplate(allocator, cmd.template, &.{
        .{ .name = "strong", .value = ff.strong },
        .{ .name = "weak",   .value = ff.weak },
    });
    defer allocator.free(bytes);
    try device_io.write(cmd.interface, bytes);
}
```

`CommandConfig` (including `commands.rumble`) is already declared from Phase 1 DSL.

**Tests (L1)**:
- mock `FfEvent{strong=0x8000, weak=0x4000}` → mock `DeviceIO.write` receives correct byte sequence
- `commands.rumble` absent → skip silently, no panic
- `write` fails with `error.Disconnected` → propagates to caller

---

## T5: gyro.activate condition check

**Files**: `src/core/mapper.zig`

**Changes**:

Add helper (file scope):
```zig
fn checkGyroActivate(activate: ?[]const u8, buttons: u32) bool {
    const spec = activate orelse return true;
    if (std.mem.startsWith(u8, spec, "hold_")) {
        const btn_name = spec["hold_".len..];
        return buttons & buttonBit(btn_name) != 0;
    }
    return true;
}
```

In `Mapper.apply`, before step [3] gyro block:
```zig
const gcfg = self.effectiveGyroConfig();
const activate = (self.config.gyro orelse &.{}).activate; // ?[]const u8
const gyro_active = checkGyroActivate(activate, self.state.buttons);
if (!gyro_active) self.gyro_proc.reset();
```

When `gyro_active` is false: skip gyro processing, do not suppress any axes.

Also thread `activate` through `effectiveGyroConfig` / layer override as needed (read from mapping config, not from `GyroConfig` runtime struct).

**Tests (L0)**:
- `activate=null` → always returns true
- `activate="hold_RB"`, RB bit set → true; RB bit clear → false
- inactive frame: step [3] gyro produces no REL events; right-stick axes not suppressed
- inactive → active transition: ema reset, no jump on first active frame

---

## T6: gyro joystick mode axis override

**Files**: `src/core/mapper.zig`

**Changes**:

In step [3] gyro block, add joystick branch after mouse branch:

```zig
if (std.mem.eql(u8, gcfg.mode, "joystick")) {
    var suppress_right_stick = false;
    if (gout.joy_x) |jx| { emit_state.rx = jx; suppress_right_stick = true; }
    if (gout.joy_y) |jy| { emit_state.ry = jy; suppress_right_stick = true; }
    if (suppress_right_stick) {
        // inhibit raw right-stick passthrough in step [6]
        // mark right stick as suppressed (analogous to stick mode suppress)
    }
}
```

Concretely: when `suppress_right_stick`, apply same zeroing logic as `right_cfg.suppress_gamepad` path — but the values were already written into `emit_state.rx/ry` from gyro, so the zeroing in step [6] must not overwrite them. Implementation: set a local `bool gyro_overrides_right_stick`; in step [6] right-stick suppress block, skip zeroing when this flag is set (gyro already wrote the desired values).

**Tests (L0)**:
- joystick mode, `gout.joy_x=1000` → `emit_state.rx=1000`; raw right-stick ABS suppressed
- joystick mode, `gout.joy_x=null` → `emit_state.rx` unchanged; no suppress
- mouse mode: `joy_x/y` do not affect `emit_state` axes

---

## T7: layer switch reset gyro/stick processors

**Files**: `src/core/mapper.zig`

**Changes**:

In `Mapper.apply`, step [2] block:

```zig
const configs = self.config.layer orelse &.{};
const prev_active = self.layer.getActive(configs);
const action = self.layer.processLayerTriggers(configs, self.state.buttons, self.prev.buttons);
const curr_active = self.layer.getActive(configs);

if (prev_active != curr_active) {
    self.gyro_proc.reset();
    self.stick_left.reset();
    self.stick_right.reset();
}
```

`getActive` returns `?*const LayerConfig` (pointer); pointer identity comparison is sufficient for change detection (same layer object = same pointer).

**Tests (L0)**:
- EMA accumulated → layer switch → gyro output starts from zero next frame (no jump)
- no layer switch → processor state preserved; EMA continuous
- hold layer press (PENDING→ACTIVE) + release each trigger one reset

---

## T8: dt_ms nanoTimestamp measurement

**Files**: `src/event_loop.zig`, `src/core/mapper.zig`

**Changes in `event_loop.zig`**:

```zig
var last_ts: i128 = std.time.nanoTimestamp();

// each ppoll iteration:
const now = std.time.nanoTimestamp();
const dt_ns = now - last_ts;
const dt_ms: u32 = @intCast(@max(1, @divFloor(dt_ns, 1_000_000)));
last_ts = now;
try mapper.apply(delta, dt_ms);
```

**Changes in `src/core/mapper.zig`**:

Extend `apply` signature:
```zig
pub fn apply(self: *Mapper, delta: GamepadStateDelta, dt_ms: u32) !OutputEvents
```

Replace both `stick_left.process(&left_cfg, ..., 16)` and `stick_right.process(&right_cfg, ..., 16)` calls with `dt_ms`.

**Tests (L1)**:
- two `apply` calls 4 ms apart → stick mouse mode REL value ≈ 16 ms baseline × (4/16) = 0.25× (±1 rounding)
- `dt_ms = 0` cannot occur (clamped to 1)
- EventLoop mock: inject fixed dt, verify stick speed normalization

---

## T9: End-to-end integration test

**Files**: `src/test/integration/phase2b.zig` (new)

**Scenarios**:

**FF rumble full chain (L1)**:
- mock uinput fd inject `EV_UINPUT+UI_FF_UPLOAD` → verify `ff_effects` stored correctly
- inject `EV_FF` play → verify mock `DeviceIO.write` receives correct rumble bytes
- inject `EV_FF` value=0 → verify write receives all-zero rumble command

**gyro activate (L0)**:
- RB not held → step [3] gyro output zero, no REL events
- RB held → gyro active, REL events produced

**gyro joystick (L0)**:
- joystick mode + gyro input → `emit_state.rx` overridden, original axis suppressed

**dt_ms normalization (L1)**:
- inject 250 Hz cadence (4 ms) → stick mouse mode REL output ≈ 16 ms baseline / 4

**layer reset (L0)**:
- gyro EMA accumulated → layer switch → next frame gyro output starts from zero, no jump

**Layer 2 (manual, local)**:
- Vader 5 real device: launch game, trigger FF_RUMBLE → controller vibrates
- gyro hold RB → gyro activates, moving controller produces mouse input

All L0/L1 scenarios run under `zig build test` (CI). L2 scenarios use `error.SkipZigTest` when `/dev/uinput` unavailable.

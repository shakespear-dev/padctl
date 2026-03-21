# Phase 2b Design: FF Pipeline, Gyro Activate/Joystick, dt_ms

## Design Decisions

| # | Decision | Resolution | Rationale |
|---|----------|-----------|-----------|
| D1 | uinput fd mode | `O_RDWR \| O_NONBLOCK` | `O_WRONLY` cannot read EV_FF/EV_UINPUT events; vader5 uses RDWR |
| D2 | pollFf drain strategy | `while` loop until `WouldBlock` | upload/erase/play can arrive consecutively; single read drops events |
| D3 | ff_effects slot count | 16 (`ff_effects_max = 16`) | matches output DSL `force_feedback.max_effects = 16` |
| D4 | fillTemplate location | new `src/core/command.zig` | separates dynamic template filling from `init.zig` static hex parsing; reusable for LED etc. |
| D5 | u16 → u8 scaling | `value >> 8` (high byte) | vader5 verified: `strong_magnitude` 0–65535 → u8 0–255 via `>> 8` |
| D6 | dt_ms calculation | Option A: `nanoTimestamp` delta at ppoll return | universal, no device timestamp dependency; better than hard-coded 16 ms for 250 Hz devices |
| D7 | gyro.activate semantics | `hold` only (Phase 2b) | toggle deferred; vader5 achieves same via layer override |
| D8 | BT CRC | not in Phase 2b | USB rumble needs no CRC; DualSense USB priority; defer BT CRC complexity |

## Architecture

### FF Pipeline

```
Game process
  ├─ ioctl(EVIOCSFF, ff_effect{FF_RUMBLE, id=-1, strong, weak})
  │    kernel assigns effect_id → triggers upload_effect callback
  └─ write(EV_FF, effect_id, value=1)   // play

uinput fd (O_RDWR | O_NONBLOCK) ← registered in EventLoop pollfds (POLL.IN)
  │
pollFf() drain loop
  ├─ EV_UINPUT + UI_FF_UPLOAD
  │    ioctl(UI_BEGIN_FF_UPLOAD) → extract strong/weak from ff_effect.u.rumble
  │    ff_effects[effect_id] = {strong, weak}
  │    upload.retval = 0; ioctl(UI_END_FF_UPLOAD)
  ├─ EV_UINPUT + UI_FF_ERASE
  │    ioctl(UI_BEGIN_FF_ERASE) → effect_id
  │    ff_effects[effect_id] = zeroed; ioctl(UI_END_FF_ERASE)
  └─ EV_FF + effect_id
       value > 0 → return FfEvent{strong, weak} from ff_effects[id]
       value = 0 → return FfEvent{strong=0, weak=0}  (stop)

EventLoop (ppoll returns, uinput fd ready)
  └─ if ff_event |ff|
       cmd = device_config.commands.rumble orelse skip
       bytes = fillTemplate(allocator, cmd.template, &.{strong=ff.strong, weak=ff.weak})
       device_io.write(cmd.interface, bytes)
```

### fillTemplate

Token-by-token (space-delimited) scan of template string:

- `{name:u8}` → look up `name` in params slice; `value >> 8` to get u8
- hex literal → `parseInt(u8, token, 16)`

Errors: `UnknownParam`, `UnsupportedParamType`, `InvalidHexByte`. Result is allocator-owned `[]u8`.

Only `u8` type required in Phase 2b; `u16le`/`u16be` deferred.

### Gyro Activate

Inserted before mapper step [3], after step [2] layer triggers:

```
checkGyroActivate(activate: ?[]const u8, buttons: u32) bool
  null / "always" / unrecognized  → true
  "hold_<Name>"                   → buttons & buttonBit(Name) != 0
```

If `false`: call `gyro_proc.reset()`, skip gyro processing, output zero, do not suppress axes.

### Gyro Joystick Mode

Mapper step [3], joystick branch:

```
gout = gyro_proc.process(gcfg, gx, gy, gz)
if mode == "joystick":
    if gout.joy_x |jx|: emit_state.rx = jx; suppress_right_stick = true
    if gout.joy_y |jy|: emit_state.ry = jy; suppress_right_stick = true
```

`suppress_right_stick` causes step [6] to zero `emit_state.rx/ry` when assembling output, overriding any passthrough. Since gyro already wrote the target values into `emit_state.rx/ry` before step [6] zeroing applies, the actual zeroing only applies to the original raw values path — in practice the joystick branch writes directly into emit_state before the suppress path, so the suppress just ensures the raw-axis passthrough is inhibited.

### Layer Switch Reset

After `layer.processLayerTriggers` returns, compare active layer identity:

```
prev_active = layer.getActive(configs)   // before processLayerTriggers
processLayerTriggers(...)
curr_active = layer.getActive(configs)   // after

if prev_active != curr_active:
    gyro_proc.reset()
    stick_left.reset()
    stick_right.reset()
```

`GyroProcessor.reset()` and `StickProcessor.reset()` are already implemented (Phase 2a skeletons).

### dt_ms Measurement

`EventLoop` maintains a `last_ts: i128` initialized at startup. Each ppoll iteration:

```
now = std.time.nanoTimestamp()
dt_ns = now - last_ts
dt_ms: u32 = @max(1, @divFloor(dt_ns, 1_000_000))
last_ts = now
mapper.apply(delta, dt_ms)
```

Minimum clamp to 1 ms prevents zero-delta on very fast frames. `Mapper.apply` signature extends to `apply(delta, dt_ms: u32)`; passes dt_ms to `stick_left.process` and `stick_right.process` replacing hard-coded 16.

## Data Flow Changes

### `UinputDevice` struct additions

```zig
ff_effects: [16]FfEffect = [_]FfEffect{.{}} ** 16,

pub const FfEffect = struct { strong: u16 = 0, weak: u16 = 0 };
```

### `Mapper.apply` signature change

```zig
pub fn apply(self: *Mapper, delta: GamepadStateDelta, dt_ms: u32) !OutputEvents
```

Previously `dt_ms` was hard-coded inside apply; now it is a parameter.

### New `command.zig` exports

```zig
pub const Param = struct { name: []const u8, value: u16 };
pub fn fillTemplate(allocator: std.mem.Allocator, template: []const u8, params: []const Param) ![]u8
```

## Edge Cases

| Case | Handling |
|------|----------|
| FF upload with `effect.id >= 16` | Complete handshake (retval=0), do not write ff_effects; no panic |
| FF play with unknown effect_id | `ff_effects[id]` default zero → sends stop command; safe |
| `commands.rumble` absent in config | Skip silently, no write |
| `fillTemplate` unknown param name | `error.UnknownParam` |
| `fillTemplate` hex literal > 255 | `error.InvalidHexByte` |
| `gyro.activate` null | Always active (same as Phase 1 behavior) |
| `gyro.activate` unrecognized string | Treated as always-active; forward-compatible |
| dt_ms = 0 (impossible after clamp) | Clamped to 1; stick mouse delta will be minimal |
| Layer switch while gyro active | Reset clears EMA; next frame gyro starts from zero |

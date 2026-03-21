# Phase 2b Test Plan

## Test Layers

| Layer | Description | CI |
|-------|-------------|-----|
| L0 | Pure functions — no fd, no kernel, no alloc side-effects | Yes |
| L1 | Mock vtable / mock fd — no `/dev/uinput`, no real device | Yes |
| L2 | Real device — Vader 5 connected, `/dev/uinput` available | Manual only |

All L0 + L1 tests live under `zig build test` and must pass in CI.

---

## T2: fillTemplate (L0)

| # | Input | Expected |
|---|-------|----------|
| 1 | template=`"00 08 00 {strong:u8} {weak:u8} 00 00 00"`, strong=`0x8000`, weak=`0x4000` | `[8]u8{0,8,0,0x80,0x40,0,0,0}` |
| 2 | template=`"02 FF 00"` (pure hex, no placeholders) | `[3]u8{0x02,0xff,0x00}` |
| 3 | template with unknown param name `{foo:u8}` | `error.UnknownParam` |
| 4 | template with unsupported type `{x:u16}` | `error.UnsupportedParamType` |
| 5 | hex literal token `"1FF"` (> 255) | `error.InvalidHexByte` |
| 6 | template=`"00 {strong:u8}"`, strong=`0x0100` | `[2]u8{0x00, 0x01}` (high byte only) |
| 7 | empty template `""` | `[]u8{}` (zero length, no error) |

---

## T3: ff_effects storage (L0/L1)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | upload effect id=2, strong=0xffff, weak=0x8000 | `ff_effects[2] = {0xffff, 0x8000}` |
| 2 | play value=1, effect id=2 (after T3.1) | returns `FfEvent{strong=0xffff, weak=0x8000}` |
| 3 | play value=0 (stop), any id | returns `FfEvent{strong=0, weak=0}` |
| 4 | erase effect id=2 (after T3.1) | `ff_effects[2] = {0, 0}` |
| 5 | upload effect id=20 (out of range) | handshake completes (retval=0), `ff_effects` unchanged, no panic |
| 6 | consecutive upload + play without intervening drain | both processed; play uses most recent upload value |
| 7 | play before any upload for that id | returns `FfEvent{strong=0, weak=0}` (default zero slot) |

---

## T1: uinput fd O_RDWR (L1)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | fd flags contain `O_RDWR` | `read()` and `write()` both succeed (no `EBADF`) |
| 2 | pollfds array | contains uinput fd entry with `POLL.IN`; `nfds` incremented by 1 |
| 3 | drain loop on empty fd | returns `null` immediately; no block |

---

## T4: FF routing (L1)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | `FfEvent{strong=0x8000, weak=0x4000}` + template `"00 08 00 {strong:u8} {weak:u8} 00 00 00"` | mock `DeviceIO.write` called with `[8]u8{0,8,0,0x80,0x40,0,0,0}` |
| 2 | `commands.rumble` absent from config | no `write` call; no panic |
| 3 | `device_io.write` returns `error.Disconnected` | error propagates to EventLoop caller |

---

## T5: gyro.activate (L0)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | `activate=null` | `checkGyroActivate` returns `true` always |
| 2 | `activate="hold_RB"`, RB bit set in buttons | returns `true` |
| 3 | `activate="hold_RB"`, RB bit clear | returns `false` |
| 4 | inactive frame (RB clear) | step [3] gyro produces zero REL events; right-stick axes not suppressed |
| 5 | `activate="always"` | returns `true` (unrecognized non-hold string → always active) |
| 6 | transition: inactive (EMA accumulated) → active (RB pressed) | `gyro_proc.reset()` called; first active frame output starts from zero |

---

## T6: gyro joystick mode (L0)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | joystick mode, `gout.joy_x=1000`, `gout.joy_y=-500` | `emit_state.rx=1000`, `emit_state.ry=-500`; suppress flag set |
| 2 | joystick mode, `gout.joy_x=null` | `emit_state.rx` unchanged from raw state; no suppress |
| 3 | mouse mode with same gyro input | `joy_x/y` null; `emit_state.rx/ry` not touched by gyro |
| 4 | joystick mode + right stick remap | gyro values in rx/ry survive; raw right-stick suppressed |

---

## T7: layer switch reset (L0)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | EMA non-zero → hold layer activates | `gyro_proc.reset()` called; `ema_x/y = 0` |
| 2 | EMA non-zero → layer releases (ACTIVE→IDLE) | `gyro_proc.reset()` called again |
| 3 | no layer switch frame | processor state preserved; EMA value unchanged |
| 4 | stick accumulator non-zero → layer switch | `stick_left.reset()` and `stick_right.reset()` called; accumulators zeroed |
| 5 | toggle layer toggle-on → toggle-off | two resets total (once per transition) |

---

## T8: dt_ms measurement (L1)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | two `apply` calls 4 ms apart, stick mouse mode | REL output ≈ `baseline_at_16ms × (4/16)` (±1 rounding) |
| 2 | `dt_ms` clamped | `dt_ms ≥ 1` always; `dt_ms = 0` impossible |
| 3 | EventLoop mock: inject fixed `dt_ms=8` | stick REL = half of `dt_ms=16` result |
| 4 | EventLoop mock: inject fixed `dt_ms=32` | stick REL = double of `dt_ms=16` result |

---

## T9: Integration (L0/L1/L2)

### FF full chain (L1)

| # | Steps | Expected |
|---|-------|----------|
| 1 | inject `EV_UINPUT+UI_FF_UPLOAD` via mock fd → inject `EV_FF` play | `DeviceIO.write` called with correct bytes from template |
| 2 | inject `EV_FF` value=0 | `DeviceIO.write` called with all-zero rumble bytes |
| 3 | inject upload + immediate play without gap | drain loop handles both; play uses stored strong/weak |

### gyro activate E2E (L0)

| # | Steps | Expected |
|---|-------|----------|
| 1 | send frames with RB=0, gyro input non-zero | no REL output |
| 2 | send frame with RB=1, same gyro input | REL output produced |

### gyro joystick E2E (L0)

| # | Steps | Expected |
|---|-------| ----------|
| 1 | joystick mode + non-zero gx/gy | `emit_state.rx/ry` set from gyro; raw right-stick ABS not emitted |

### dt_ms normalization E2E (L1)

| # | Steps | Expected |
|---|-------|----------|
| 1 | 60 frames at `dt_ms=4`, stick pushed to max, mouse mode | cumulative REL ≈ 60 × (4/16) × `baseline_per_frame` |

### Layer reset E2E (L0)

| # | Steps | Expected |
|---|-------|----------|
| 1 | 20 frames gyro active, EMA saturated → trigger layer switch → 1 more frame | frame after switch: `rel_x/y = 0` |

### L2 Manual (local device required)

| # | Scenario | Pass Condition |
|---|----------|----------------|
| 1 | Start game that uses FF_RUMBLE; run padctl with Vader 5 | Controller vibrates on in-game events |
| 2 | Config: `gyro.activate = "hold_RB"`, mode = "mouse" | Moving controller with RB held moves mouse; releasing RB stops it |
| 3 | Config: `gyro.activate = "hold_RB"`, mode = "joystick" | Moving controller with RB held deflects right stick; right stick suppressed |
| 4 | Config: stick mouse mode; play at 250 Hz | Mouse speed matches 62.5 Hz baseline (no 4× over-speed) |

L2 tests use `error.SkipZigTest` guard when `/dev/uinput` is unavailable.

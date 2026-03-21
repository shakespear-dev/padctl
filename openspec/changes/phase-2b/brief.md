# Phase 2b Brief: FF Pipeline, Gyro Activate/Joystick, dt_ms

## What

Complete the input pipeline to full Vader 5 feature parity:

1. **Force Feedback pipeline** — `pollFf` drain loop with `ff_effects[16]` storage; upload/play/erase full handling; `fillTemplate` command template parser; FF event routing to `DeviceIO.write`.
2. **Gyro activate** — `hold_<Name>` condition parsed and checked before mapper step [3]; inactive → reset processor.
3. **Gyro joystick mode** — `joy_x/y` values override `emit_state.rx/ry`; original right-stick axes suppressed.
4. **Layer switch reset** — gyro/stick processors reset on layer change; eliminates EMA residual jump.
5. **dt_ms measured** — `nanoTimestamp` delta replaces hard-coded 16 ms; passed into `Mapper.apply`.

## Why

Phase 2a delivered the skeleton; Phase 2b activates it. FF events arrive on the uinput fd but are currently discarded (no effect storage, no drain loop, fd opened `O_WRONLY`). Gyro activate field is declared but never checked. Joystick mode computes `joy_x/y` but mapper ignores them. `dt_ms = 16` hard-coded causes 4× speed error on 250 Hz devices.

## Scope

| Area | Files |
|------|-------|
| uinput fd + FF storage | `src/io/uinput.zig` |
| Command template parser | `src/core/command.zig` (new) |
| FF routing + dt_ms | `src/event_loop.zig` |
| Gyro activate, joystick, layer reset | `src/core/mapper.zig` |
| Integration test | `src/test/integration/phase2b.zig` (new) |

## Out of Scope

- DualSense BT CRC (`checksum` field) — deferred to Phase 2c
- `gyro.activate` toggle semantics — deferred to Phase 2c
- `fillTemplate` u16le/u16be types — deferred to Phase 2c

## Success Criteria

- FF upload → play → erase full chain: game triggers FF_RUMBLE → padctl writes hidraw rumble command, strength correctly scaled (`>> 8`)
- `fillTemplate` parses `{strong:u8}` / `{weak:u8}` placeholders, output matches hand-computed bytes (L0)
- uinput fd `O_RDWR`; `pollFf` drain loop handles consecutive upload + play without dropping events
- `gyro.activate = "hold_RB"`: RB not held → gyro output zero; RB held → gyro active (L0)
- Gyro joystick mode: `emit_state.rx/ry` overridden by gyro, original right-stick axes suppressed (L0)
- Layer switch: gyro/stick processors reset on change, no jump (L0)
- `dt_ms` measured: 250 Hz device stick mouse speed matches 62.5 Hz device after normalization (L1)
- `zig build test` (L0 + L1) all pass, CI-runnable

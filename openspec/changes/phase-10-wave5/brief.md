# Brief: Phase 10 Wave 5 — Generic Device Mapping (T19-T23)

## Why

padctl currently only supports gamepad-class devices. The `FieldTag` enum and
`GamepadState/GamepadStateDelta` structures hardcode gamepad semantics (left_x,
right_y, lt, rt, ButtonId). Non-gamepad HID devices — racing wheels, flight
sticks, HOTAS throttles, arcade sticks, custom HID peripherals — cannot be
supported because their axes/buttons have no FieldTag equivalent.

This wave introduces a `mode = "generic"` path that bypasses `FieldTag` and
`GamepadState` entirely. Field names become arbitrary TOML keys, and their
output mapping is declared via `[output.mapping]` using standard Linux event
codes (ABS_WHEEL, BTN_GEAR_UP, etc.). The byte extraction layer
(`readFieldByTag`, `extractBits`, `runTransformChain`) is fully shared with
the gamepad path — only the semantic mapping layer differs.

~200 lines of new code, ~25 lines of modifications. After this wave, adding a
new non-gamepad device requires only a TOML file (P1 compliance).

## Scope

| Task | Description | Dependencies |
|------|-------------|-------------|
| T19 | `GenericFieldSlot` struct + `GenericDeviceState` (fixed 32-slot array, compiled at config load) | T1, T2 (done) |
| T20 | Config parser — `mode = "generic"` in `[device]`, `[output.mapping]` section parsing + event code resolution | T19 |
| T21 | Generic emit path in event_loop — bypass GamepadState, iterate GenericDeviceState slots, emit uinput events directly | T19, T20 |
| T22 | Generic uinput device creation — auto-register ABS/KEY capabilities from `[output.mapping]` declarations | T20 |
| T23 | Example device TOML — `devices/example/generic-wheel.toml` as contributor template | T20, T21, T22 |

## Success Criteria

- Generic mode device (wheel/joystick) fully driven by TOML config, zero code changes
- `mode = "generic"` device TOML parses, validates, and creates correct uinput device
- Byte extraction shared with gamepad path (no code duplication)
- No regression on any existing gamepad device
- Example TOML demonstrates all generic features (multi-axis, buttons, range)
- `zig build test` passes with new tests (Layer 0+1)

## Out of Scope

- Remap/layer/gyro support for generic devices (not needed for non-gamepad use cases)
- REL_* (relative axis) event type support (can be added later if needed)
- WASM plugin interaction with generic path (compatible by design, tested in Phase 9+)
- Force feedback for generic devices
- Touchpad/aux output for generic devices

## References

- Phase plan: `planning/phase-10.md` (docs-repo, Wave 5)
- Research: `research/调研-混合通用设备映射架构.md` (docs-repo, Method C)
- Design principles: `design/principles.md` (docs-repo, P1/P2/P3/P8)
- Source: `src/core/interpreter.zig`, `src/io/uinput.zig`, `src/config/device.zig`, `src/event_loop.zig`
- Source: `src/config/input_codes.zig` (event code resolution tables)

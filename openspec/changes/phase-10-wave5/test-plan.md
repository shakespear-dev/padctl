# Phase 10 Wave 5: Test Plan — Generic Device Mapping (T19-T23)

All tests are Layer 0 (pure function) or Layer 1 (mock vtable). No kernel
device access required. All run under `zig build test`.

## T19: GenericFieldSlot + extractGenericFields

- [ ] TP1: **Standard field extraction** — construct GenericDeviceState with 1 ABS slot
  (offset=0, type=i16le, range=[-32768, 32767]). Write 0x0180 at offset 0 in a
  synthetic buffer. Call `extractGenericFields`. Verify `values[0] == 384` (0x0180 LE).

- [ ] TP2: **Bits field extraction** — slot with bits mode (byte_offset=2, start_bit=0,
  bit_count=4). Write 0x0A at byte 2. Verify `values[i] == 10`.

- [ ] TP3: **Button slot produces 0/1** — slot with `is_button = true`. Non-zero raw
  value -> `values[i] == 1`. Zero raw value -> `values[i] == 0`.

- [ ] TP4: **Axis clamp to range** — slot with `range_min = 0, range_max = 255`. Raw
  value 300 (via u16le) -> `values[i] == 255` (clamped).

- [ ] TP5: **Transform chain applied** — slot with `transform = "negate"`. Raw value
  100 -> `values[i] == -100` (within i32 range).

- [ ] TP6: **Multiple slots** — 3 slots with different offsets. All extract correctly
  from the same buffer.

## T20: Config Parser

- [ ] TP7: **Gamepad TOML backward compatible** — all existing device TOMLs (no `mode`
  field) parse and validate without error. No regression.

- [ ] TP8: **Generic TOML parses** — TOML with `mode = "generic"` and `[output.mapping]`
  parses and validates.

- [ ] TP9: **mode = "generic" without mapping fails** — generic-mode TOML that omits
  `[output.mapping]` returns validation error.

- [ ] TP10: **Unknown event code fails** — `[output.mapping]` entry with
  `event = "INVALID_CODE"` returns validation error.

- [ ] TP11: **ABS without range fails** — `[output.mapping]` ABS entry without `range`
  returns validation error.

- [ ] TP12: **resolveEventCode ABS** — `resolveEventCode("ABS_WHEEL")` returns
  `{ .event_type = EV_ABS, .event_code = ABS_WHEEL }`.

- [ ] TP13: **resolveEventCode BTN** — `resolveEventCode("BTN_GEAR_UP")` returns
  `{ .event_type = EV_KEY, .event_code = BTN_GEAR_UP }`.

- [ ] TP14: **resolveEventCode KEY** — `resolveEventCode("KEY_A")` returns
  `{ .event_type = EV_KEY, .event_code = KEY_A }`.

- [ ] TP15: **resolveEventCode unknown** — `resolveEventCode("INVALID")` returns
  `error.UnknownEventCode`.

- [ ] TP16: **Generic mode skips ButtonId validation** — generic TOML with
  `button_group.map` keys like `gear_up` (not in ButtonId enum) validates without error.

- [ ] TP17: **Gamepad mode still validates ButtonId** — gamepad TOML with invalid
  `button_group.map` key still returns error (existing behavior preserved).

## T21: Generic Emit Path

- [ ] TP18: **Generic branch selected** — EventLoopContext with `generic_state != null`
  takes the generic path; `generic_state == null` takes the gamepad path.

- [ ] TP19: **matchReport export** — `Interpreter.matchReport(interface_id, raw)` returns
  the same result as the former private `matchCompiled`. Existing tests pass.

- [ ] TP20: **No regression on gamepad path** — all existing EventLoop tests pass
  unchanged when `generic_state` is null (default).

## T22: Generic Uinput Device

Note: GenericUinputDevice.create() requires `/dev/uinput` (Layer 2). The following
tests verify the logic without opening real devices.

- [ ] TP21: **emitGeneric differential** — construct GenericDeviceState with 2 slots.
  Set values[0] = 100, values[1] = 200, prev_values all 0. Call emitGeneric with
  a mock fd (pipe). Read the written bytes, verify 2 input_events + SYN_REPORT.

- [ ] TP22: **emitGeneric no-change skip** — set values == prev_values. Call emitGeneric.
  Verify zero bytes written (no events, no SYN_REPORT).

- [ ] TP23: **emitGeneric updates prev_values** — after emitGeneric, verify
  `prev_values == values`.

- [ ] TP24: **Event types correct** — ABS slot emits `type = EV_ABS`, BTN slot emits
  `type = EV_KEY`. Verify from written bytes.

## T23: Example TOML

- [ ] TP25: **generic-wheel.toml parses** — `device.parseFile(allocator, path)` succeeds
  for `devices/example/generic-wheel.toml`.

- [ ] TP26: **generic-wheel.toml has correct mode** — `cfg.device.mode` equals `"generic"`.

- [ ] TP27: **generic-wheel.toml has mapping** — `cfg.output.mapping` is non-null with
  >= 6 entries (4 axes + 2+ buttons minimum).

- [ ] TP28: **Auto-test discovers example** — the Dir.walk-based auto-device test
  discovers and processes `generic-wheel.toml` without error.

## Regression Guard

- [ ] TP29: All existing `interpreter.zig` tests pass (pub visibility changes do not
  break internal callers)
- [ ] TP30: All existing `device.zig` tests pass (new Optional fields have no effect)
- [ ] TP31: All existing `uinput.zig` tests pass
- [ ] TP32: All existing `event_loop.zig` tests pass
- [ ] TP33: Full `zig build test` passes (all modules, Layer 0+1)

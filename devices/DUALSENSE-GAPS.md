# DualSense DSL Coverage Gaps

DSL overall coverage: ~75%. Core gamepad input (sticks, triggers, buttons, IMU) is fully covered.
Five features cannot be expressed in Phase 1 DSL.

## Gap 1: Touchpad 12-bit cross-byte bit-fields

The touchpad X/Y coordinates are 12-bit values packed across byte boundaries:
- `touch0_x`: bits 0–11 starting at byte 34 (spans bytes 34–35)
- `touch0_y`: bits 4–15 starting at byte 35 (spans bytes 35–36)

Phase 1 DSL `bits = [offset, start, length]` only supports `start + length <= 8` (single-byte
extraction). A `u16le + mask/shift` workaround is possible but not yet in the validated transform
set. Cross-byte bit-fields are scheduled for Phase 2.

## Gap 2: Adaptive Trigger complex mode parameters

Each trigger motor has 1-byte mode + 10-byte parameter block (bytes 11–32 of output report 0x02).
Full effect modes (0x21 Feedback, 0x26 Vibration, etc.) pack force/amplitude data as 3-bit fields
across 10 zone positions. The `[commands.*]` template placeholder system accepts only whole-byte
`{name:u8}` values; it cannot express sub-byte packing or conditional parameter encoding. Simple
modes (0x01/0x02/0x06) work within current DSL.

## Gap 3: BT mode seq_tag counter

Bluetooth output report 0x31 byte 1 high nibble is a 0–15 rolling counter that must increment with
every transmitted report. This is inherently stateful — the DSL is declarative and has no mechanism
to maintain or increment a per-session counter. Requires engine-level support.

## Gap 4: BT mode CRC32 output computation

Bluetooth output reports require a CRC32 appended at bytes 74–77, computed over the full report
content with seed byte `0xA2` prepended. The `[commands.*.checksum]` DSL token exists for input
verification but the engine must still implement the "build template → compute CRC32 → append"
pipeline for output reports. Until the engine handles this, BT output (rumble/LED) is unavailable.
USB output is unaffected (no CRC).

## Gap 5: IMU calibration via Feature Report

Accurate IMU readings require reading Feature Report 0x05 (41 bytes) at startup to obtain
per-axis bias, sensitivity-plus, and sensitivity-minus values, then applying the correction formula
each frame:

    gyro_calibrated = (speed_plus + speed_minus) * 1024 * (raw - bias) / (plus - minus)
    accel_calibrated = 2 * 8192 * (raw - bias) / (plus - minus)

This is a multi-step stateful process (HID GET_FEATURE call → value cache → per-frame arithmetic)
that cannot be expressed in the declarative field/transform DSL. Raw uncalibrated values are still
usable for relative motion; absolute accuracy requires engine-level calibration support.

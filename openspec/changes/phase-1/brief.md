# Brief: padctl Phase 1 — Core MVP

## Why

padctl is a Linux userspace gamepad compatibility daemon. Existing solutions
(kernel drivers, evdev remappers, device-specific daemons) cannot simultaneously
provide "parse arbitrary raw HID protocol + generic mapping engine + declarative
device config". padctl fills this gap.

Phase 1 delivers the minimum viable product that proves the core value proposition:
a declarative TOML device config drives a generic protocol interpreter that requires
zero code changes to add new device support. The Flydigi Vader 5 Pro serves as the
first validation target — a device with dual USB interfaces, vendor-class bulk I/O,
proprietary extension protocol, and IMU data, making it a demanding but representative
test of the DSL's expressiveness.

## References

- `planning/phase-1.md` — Phase 1 task plan, design decisions, success criteria
- `engineering/interpreter.md` — Protocol Interpreter interface spec
- `engineering/device-io.md` — DeviceIO vtable and hidraw/usbraw backend spec
- `engineering/output.md` — OutputDevice vtable and uinput creation spec
- `engineering/mapper.md` — Mapper interface and remap pipeline spec
- `_agent/state/needs-snapshot.md` — Acceptance criteria and DSL reference

All paths are relative to the doc-repo root.

## Scope

Phase 1 covers tasks T0 through T12:

| Task | Capability |
|------|-----------|
| T0 | TOML library spike validation (sam701/zig-toml, 4 structural checks) |
| T1 | Zig project skeleton, build.zig, GitHub Actions CI |
| T2 | TOML parser integration (sam701/zig-toml, allocator lifecycle) |
| T3 | DeviceConfig schema + load-time validation + commands template schema |
| T4 | OutputConfig schema + ABS/BTN code resolution |
| T5 | hidraw backend + ioctl constants + MockDeviceIO test infrastructure |
| T6 | usbraw/libusb backend + ring buffer |
| T7 | Protocol Interpreter (5-step processReport pipeline) |
| T8 | UinputDevice + OutputDevice vtable + minimal AuxDevice skeleton |
| T9a | ppoll event loop + signalfd signal handling |
| T9b | CLI parsing + config loading + handshake sequence |
| T9c | Full pipeline integration (DeviceIO → Interpreter → OutputDevice) |
| T10 | Vader 5 Pro device config (devices/flydigi-vader5.toml) |
| T11 | End-to-end validation (Layer 1 automated + Layer 2 manual) |
| T12 | Basic button remap ([remap] section, no Layer/suppress/inject) |

**Explicitly deferred to Phase 2+:**
- Layer system (hold/toggle/tap-hold, timerfd activation)
- Full suppress/inject pipeline
- Gyro→mouse, stick→mouse/scroll, DPad→arrows modes
- Force feedback play routing (Phase 1 registers FF capability only)
- Dual uinput device topology full implementation (AuxDevice REL axes)
- padctl-capture / padctl-debug tools (Phase 3)
- WASM plugin extension point (Phase 4)

## Success Criteria

Derived from `planning/phase-1.md §Success Criteria`:

1. `zig build` succeeds; produces single binary `padctl`; no dependency warnings
2. GitHub Actions CI passes (`zig fmt --check` + `zig build` + `zig build test`)
3. `DeviceConfig.load("devices/flydigi-vader5.toml")` returns without error; all
   fields parsed correctly including commands templates and `response_prefix`
4. `Interpreter.processReport()` correctly parses all fields from a 32-byte Vader 5
   IF1 extended input sample (joystick i16le with Y-axis negation, button bitfields,
   IMU i16le)
5. Handshake sequence (CMD 0x01/0xa1/0x02/0x04) verified via MockDeviceIO:
   write/read/retry logic correct
6. `ppoll` + signalfd event loop: SIGTERM/SIGINT causes clean exit, no fd leaks
   (Layer 1 automated)
7. Output device DSL: VID/PID/capabilities entirely config-driven, no hardcoded
   values in code
8. Conditional fields via multi-report grouping: IF1 report contains gyro/accel
   fields; IF0 report does not; GamepadStateDelta Optional semantics verified
9. Commands template parsing: `[commands.rumble]` with `{strong:u8} {weak:u8}`
   placeholders correctly constructs byte sequence (L0 unit test)
10. Basic button remap: M1 → KEY_F13 scenario passes Layer 1 test
11. `zig build test` (Layer 0+1) all pass; CI-runnable without real hardware
12. hidraw `discover(0x37d7, 0x2401, 1)` locates correct `/dev/hidrawN` (Layer 2 manual)
13. usbraw `open(ctx, 0x37d7, 0x2401, 0)` successfully claims libusb IF0 (Layer 2 manual)
14. `evtest` recognizes the virtual gamepad; VID/PID matches `[output]` declaration
    (Layer 2 manual)
15. A/B/X/Y/LB/RB/D-Pad/sticks/LT/RT all produce correct uinput events (Layer 2 manual)

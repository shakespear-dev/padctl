# Reviewer Report: Phase 9a T2 — DualSense IMU Calibration WASM Plugin

## Verdict: **PASS**

**BLOCKING: 0**

## Review Scope

Reviewed all 4 OpenSpec files (brief.md, design.md, tasks.md, test-plan.md) + gardener-report.md.
Cross-checked against:
- `design/principles.md` (P1-P9)
- `research/调研-DualSense-Feature-Report-0x05-校准.md`
- `src/wasm/host.zig`, `src/wasm/runtime.zig`, `src/wasm/wasm3_backend.zig`
- `sdk/wasm/padctl_plugin.h`
- `devices/sony/dualsense.toml`

## Completeness

- [x] brief.md: problem statement clear, scope well-bounded, success criteria measurable
- [x] design.md: architecture diagram, byte layout, formulas, state serialization, DualShock 4 compatibility, TOML changes — all present
- [x] tasks.md: T2a-T2d sequential with implementation-level detail, compile flags specified, post-merge cleanup
- [x] test-plan.md: TP1-TP4 cover all 4 success criteria in brief.md, TP5-TP7 regression guards
- [x] gardener-report.md: PASS, host API alignment verified against 6 import functions, vtable methods, export names, state constraints

## Principle Compliance

### P7 (WASM Escape Hatch) — Justified

IMU calibration is a textbook P7 use case:
1. **Stateful**: requires one-time Feature Report read, persistent calibration params across frames
2. **Multi-step arithmetic**: 17 field extraction, 6-axis parameter computation (bias/numer/denom), per-frame division
3. **Runtime-dependent parameters**: calibration values vary per physical controller unit — cannot be static TOML constants

The research report's Section 5 exhaustively analyzes three alternatives (engine built-in, DSL expression engine, WASM) and correctly concludes WASM is the only approach that doesn't violate P1 (declarative simplicity) or P3 (progressive complexity). Adding an expression engine to the DSL to handle this one case would push the DSL toward a scripting language — the exact anti-pattern P3 exists to prevent.

### Other Principles

- [x] **P1**: Plugin is confined to IMU calculation; all other device protocol parsing remains declarative TOML
- [x] **P2**: No device-specific branches in the interpreter — the host simply dispatches to the plugin's `process_report`
- [x] **P3**: Plugin mechanism adds zero complexity for devices that don't need it (`[wasm]` section is optional)
- [x] **P5**: WASM binary is embedded/shipped alongside the single binary; no additional runtime dependency
- [x] **P6**: Calibration plugin is part of device protocol config (referenced in `devices/sony/dualsense.toml`), not user mapping
- [x] **P9**: Plugin tests use the existing `HostContext` mock infrastructure + `Wasm3Plugin` vtable; no kernel dependency

## Feasibility

- [x] Host API complete: all 3 host functions needed (`set_state`, `get_state`, `get_config`) are implemented and linked in `wasm3_backend.zig`
- [x] vtable methods complete: `processCalibration` and `processReport` paths verified in `wasm3_backend.zig` lines 93-127
- [x] SDK header declares both exports with matching signatures (`padctl_plugin.h` lines 40-45)
- [x] State budget: 72 bytes well within `max_value_size = 4096`
- [x] WASM memory layout: `input_offset=0`, `output_offset=4096` provides clean separation for raw/out buffers
- [x] Estimated ~105 lines C is plausible for this complexity (fixed-offset parsing + 6x same formula + state serialization)

## Test Coverage

- [x] TP1: `process_calibration` parse + store — covers happy path with known reference values
- [x] TP2: `process_report` apply calibration — verifies formula correctness AND non-IMU passthrough integrity
- [x] TP3: Zero-denominator fallback — edge case with specific expected fallback constants
- [x] TP4: DualShock 4 compatibility — 37-byte report, different IMU offsets via `get_config`
- [x] TP5-TP7: Regression guards for existing wasm3/host/mock test suites

## Non-Blocking Notes

1. **test-plan.md L33 gyro_speed_minus**: The example fixture uses `gyro_speed_minus = -582`, which would give `speed_2x = 582 + (-582) = 0`, leading to `sens_numer = 0` — all calibrated gyro values would be zero regardless of raw input. The Note on L36-37 acknowledges this and recommends realistic positive values. The implementer should follow L37, not L33. Gardener also flagged this. No spec change needed since the note is self-correcting.

2. **`process_report` return value semantics**: design.md says "return 0 (override)". The wasm3_backend interprets `ret >= 0` as override and `ret < 0` as drop. These are consistent — returning 0 from the WASM function triggers the override path. The `passthrough` result only occurs when `fn_proc` is null (no export). This means once the plugin exports `process_report`, there is no way to signal "passthrough for this frame" — every frame is either override or drop. This is acceptable for a calibration plugin (it always has calibration data after init), but worth noting for future plugin designs.

3. **BT IMU offset**: The design correctly identifies BT gyro_x at offset 17 (vs USB at 16) and relies on `get_config("imu_offset")` to select the right base. The TOML config doesn't currently declare this config value — the implementer will need to ensure the host passes the correct offset. This is an implementation detail, not a spec gap (the spec says "IMU offsets from `get_config`" in D5).

4. **Clamp to i16 range**: The design specifies clamping calibrated values to `[-32768, 32767]`. With zero-denominator fallback (`numer=2097152, denom=32767`), a raw value of 1000 would produce `1000 * 2097152 / 32767 = 64,034`, which overflows i16 and would be clamped to 32767. The clamping logic is therefore essential and correctly specified.

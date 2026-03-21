# Reviewer Report: Phase 10 Wave 5 — Generic Device Mapping (T19-T23)

## Review Scope

Reviewed: `brief.md`, `design.md`, `tasks.md`, `test-plan.md`, `gardener-report.md`.
Cross-referenced: `src/core/interpreter.zig`, `src/config/device.zig`,
`src/io/uinput.zig`, `src/config/input_codes.zig`, `src/event_loop.zig`.
Principles check: `design/principles.md` (P1, P2, P3).

## P1/P2/P3 Compliance

### P1 — Declarative First

- [x] Generic mode is fully TOML-driven: `mode = "generic"` + `[output.mapping]`
- [x] Adding a non-gamepad device = adding ONE TOML file, zero code changes
- [x] Example TOML (`devices/example/generic-wheel.toml`) demonstrates the workflow
- [x] No device-specific code paths introduced — generic logic is a parallel module

### P2 — Universal Protocol Engine

- [x] Byte extraction layer shared: `readFieldByTag`, `extractBits`, `signExtend`,
  `runTransformChain` are reused from interpreter.zig (exported as `pub`)
- [x] Generic path does NOT duplicate extraction logic — it calls the same functions
- [x] No device-specific if/switch branches added to interpreter.zig
- [x] `matchCompiled`/`verifyChecksumCompiled` reused for report matching

### P3 — Progressive Complexity

- [x] D1: explicit `mode = "generic"` opt-in — gamepad users never see generic concepts
- [x] Existing TOMLs omit `mode` -> defaults to null -> treated as gamepad (backward compatible)
- [x] Generic mode adds `[output.mapping]` only when needed — no burden on simple gamepad configs
- [x] No mandatory new fields for existing devices

## Checklist

### Completeness

- [x] Problem statement clear — FieldTag/GamepadState hardcode gamepad semantics,
  non-gamepad devices cannot be supported
- [x] All five tasks (T19-T23) have clear scope and deliverables
- [x] All modified source files identified in the Files table
- [x] Shared infrastructure reuse explicitly listed (T19c)
- [x] Out-of-scope boundary well-defined (remap/layer, REL_*, WASM, FF, touchpad)

### Correctness

- [x] `GenericFieldSlot` embeds extraction params — avoids indirection, consistent
  with `CompiledField` philosophy
- [x] `GenericDeviceState` uses flat i32 array — zero allocation, zero string ops (D2)
- [x] `MAX_GENERIC_FIELDS = 32` — reasonable upper bound for non-gamepad devices
- [x] `extractGenericFields` correctly dispatches standard vs bits mode
- [x] `emitGeneric` uses differential emit pattern — consistent with `UinputDevice.emit()`
- [x] `resolveEventCode` prefix dispatch covers ABS_/BTN_/KEY_ — correct and unambiguous (D6)
- [x] Validation skips ButtonId for generic mode (D7) — correct, generic field names are arbitrary
- [x] Gardener W1 fixed: `BTN_GEAR_UP`/`BTN_GEAR_DOWN` added to `btn_table` prerequisite in
  design.md and tasks.md

### Design Quality

- [x] D1 (explicit mode field) — correct, avoids ambiguity with P3
- [x] D2 (flat array, no HashMap) — correct for hot path performance
- [x] D3 (embedded extraction params) — reduces indirection, self-contained slots
- [x] D4 (no remap/layer) — reasonable deferral, non-gamepad devices handle remapping differently
- [x] D5 (separate generic.zig) — correct separation of concerns
- [x] D6 (prefix dispatch) — leverages existing resolver functions
- [x] D7 (skip ButtonId validation) — necessary for arbitrary field names
- [x] D8 (example in devices/example/) — correct, fictional device in example directory

### Architecture

- [x] Generic path is a parallel module (`src/core/generic.zig`), not inlined in interpreter
- [x] Event loop branching is clean: `if (generic_state) { ... } else { existing gamepad }`
- [x] `GenericUinputDevice` lives alongside `UinputDevice` — both use same ioctl helpers
- [x] Config parser additions are backward-compatible (all new fields are optional)

### Test Plan

- [x] TP1-TP6: unit tests for `extractGenericFields` (standard, bits, button, clamp, transform, multi-slot)
- [x] TP7: backward compatibility check for existing TOMLs
- [x] TP8-TP17: config parser tests (parse, validate, error cases, ButtonId skip)
- [x] TP18-TP20: event loop integration tests
- [x] TP21-TP24: emitGeneric differential tests with mock fd
- [x] TP25-TP28: example TOML parse and auto-discovery tests
- [x] TP29-TP33: regression guards for all modified modules
- [x] All tests are Layer 0/1 — no kernel device access needed

### Task Breakdown

- [x] T19a-T19e: logical decomposition, unit tests included
- [x] T20a-T20e: config changes with validation tests
- [x] T21a-T21c: event loop integration with clear insertion point
- [x] T22a-T22b: uinput creation with supervisor integration
- [x] T23a-T23b: example TOML with auto-test verification
- [x] Execution order correctly specified: T19 -> T20 -> T21+T22 (parallel) -> T23

### Gardener Report

- [x] Gardener passed with 1 warning (W1), fixed inline in design.md and tasks.md
- [x] All source cross-references verified (visibility, field presence, function signatures)

## Findings

No blocking issues found. Gardener W1 (missing `BTN_GEAR_UP`/`BTN_GEAR_DOWN` in
`btn_table`) was fixed inline before this review.

## Verdict

**PASS** — spec is ready for implementation. No blocking issues.

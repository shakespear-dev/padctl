# Brief: Phase 9a — WASM Real Integration (wasm3)

## Why

`src/wasm/runtime.zig` defines a `WasmPlugin` vtable and a `MockPlugin` stand-in, but no real
WASM runtime is linked. All WASM-dependent features (DualSense calibration handshake, Switch Pro
BT protocol, community plugins) are blocked until a real backend exists. Phase 9a replaces
MockPlugin with a wasm3-backed implementation, making the WASM escape hatch (P7) operational.

## Problem Scope

- Vendor wasm3 C source into `third_party/wasm3/` (pinned commit)
- `build.zig` integration: `-Dwasm=true/false` flag, `addCSourceFiles` for wasm3
- `src/wasm/wasm3_backend.zig`: `Wasm3Plugin` struct implementing `WasmPlugin.VTable` via wasm3 C API
- Host function binding: 7 callbacks registered via `m3_LinkRawFunctionEx`
- Memory layout: 8KB scratch area, 1MB linear memory limit (ADR-005)
- Trap rate limiting (10 traps/second, auto-unload on exceeded)
- WAT-compiled `.wasm` test fixtures for unit tests

## Success Criteria

- `zig build -Dwasm=true` compiles and links wasm3 statically
- `zig build -Dwasm=false` compiles without wasm3 (MockPlugin fallback)
- 8 unit tests in `wasm3_backend.zig` pass (echo round-trip, error paths, trap handling)
- Existing MockPlugin tests in `runtime.zig` and `wasm_e2e_test.zig` unchanged and passing
- Echo plugin WAT fixture: `init_device` returns 0, `process_report` copies raw input to output

## Out of Scope

- DualSense calibration WASM plugin (Phase 9a T2 — deferred until T1 verified)
- Switch Pro BT WASM plugin (Phase 9 Wave 4)
- WASM SDK documentation and C header (Phase 9a T3 — after T1 and T2)
- Execution timeout watchdog (timerfd thread — separate task, not blocking T1)
- wasmtime alternative backend (deferred per ADR-005)

## References

- ADR: `decisions/005-wasm-plugin-runtime.md`
- Phase plan: `_agent/state/needs-snapshot.md` (Phase 9, Wave 1)
- Existing vtable: `src/wasm/runtime.zig`
- Host functions: `src/wasm/host.zig`
- Design principles: `design/principles.md` (P5, P7, P9)
- Prior openspec: `openspec/changes/phase-7/`

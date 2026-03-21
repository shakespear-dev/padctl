# Phase 9a: Test Plan — WASM Real Integration (wasm3)

Each test maps to a success criterion in `brief.md`.

## Test Fixtures

3 WAT source files pre-compiled to `.wasm` and committed to `src/test/fixtures/`:

**echo_plugin.wasm** (from `echo_plugin.wat`):
- Exports: `init_device() -> i32` (returns 0), `process_report(i32, i32, i32, i32) -> i32`
  (copies `raw_len` bytes from `raw_ptr` to `out_ptr`, returns 0)
- Imports: none
- Purpose: verifies end-to-end load/call/read-back cycle

**no_exports.wasm** (from `no_exports.wat`):
- Exports: none (valid module with only memory declaration)
- Purpose: verifies graceful handling when expected exports are absent

**trap_plugin.wasm** (from `trap_plugin.wat`):
- Exports: `process_report(i32, i32, i32, i32) -> i32` (executes `unreachable` immediately)
- Purpose: verifies trap capture, error return, and rate limiting

## Unit Tests (in `src/wasm/wasm3_backend.zig`)

- [ ] TP1: **load valid module** — load `echo_plugin.wasm` bytes; `load()` returns success;
  `self.env != null` and `self.rt != null`.
  validates: T1c load lifecycle

- [ ] TP2: **load invalid module** — pass arbitrary bytes `[0xDE, 0xAD]` to `load()`;
  returns `LoadError.PluginLoadFailed`.
  validates: T1c error path

- [ ] TP3: **initDevice returns true** — load `echo_plugin.wasm`; call `initDevice()`;
  returns `true` (export found, returned 0).
  validates: T1e initDevice

- [ ] TP4: **initDevice absent export** — load `no_exports.wasm`; call `initDevice()`;
  returns `false` (export not found, no crash).
  validates: T1e missing export handling

- [ ] TP5: **processReport echo round-trip** — load `echo_plugin.wasm`; call
  `processReport(&[_]u8{0xAA, 0xBB, 0xCC}, &out)`; verify `out[0..3]` equals
  `[0xAA, 0xBB, 0xCC]`; result is `.passthrough`.
  validates: T1e processReport + memory layout

- [ ] TP6: **processReport trap returns drop** — load `trap_plugin.wasm`; call `processReport`;
  result is `.drop`; `trap_count == 1`.
  validates: T1e trap handling

- [ ] TP7: **trap rate limiting auto-unload** — load `trap_plugin.wasm`; call `processReport`
  10 times rapidly (within 1 second); after 10th call, plugin is unloaded (`env == null`).
  validates: T1e trap rate limiting

- [ ] TP8: **unload + destroy lifecycle** — load `echo_plugin.wasm`; call `unload()`; verify
  `env == null`; call `destroy(allocator)` — no double-free or crash.
  validates: T1c unload/destroy

## Build Verification

- [ ] TP9: `zig build -Dwasm=true` — compiles padctl with wasm3 linked; no errors.
  validates: T1b build integration

- [ ] TP10: `zig build -Dwasm=false` — compiles padctl without wasm3; no errors.
  validates: T1b conditional compilation

- [ ] TP11: `zig build test -Dwasm=true` — all unit tests pass (TP1–TP8 plus existing tests).
  validates: T1c/T1d/T1e correctness

- [ ] TP12: `zig build test -Dwasm=false` — all existing tests pass; wasm3_backend tests skipped.
  validates: T1b MockPlugin fallback

## Regression Guard

- [ ] TP13: All 8 existing `MockPlugin` tests in `src/wasm/runtime.zig` pass unchanged.
  validates: P9 — mock tests not broken by wasm3 addition

- [ ] TP14: All 4 tests in `src/test/wasm_e2e_test.zig` pass unchanged.
  validates: P9 — E2E mock tests not broken

- [ ] TP15: All 7 tests in `src/wasm/host.zig` pass unchanged.
  validates: HostContext unchanged

## Manual Tests (not required for merge)

- [ ] TP16: Manually compile `echo_plugin.wat` → `.wasm` with `wat2wasm`; binary-diff against
  committed fixture — identical.
  validates: fixture reproducibility

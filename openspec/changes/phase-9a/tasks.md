# Tasks: Phase 9a — WASM Real Integration (wasm3)

Branch: `feat/phase-9a`
Commit: (leave blank — filled after implementation)

## Execution plan

T1a–T1e sequential (each depends on prior). T2 and T3 deferred until T1 verified.

---

## T1a: Vendor wasm3 source

- [ ] Create `third_party/wasm3/source/` directory
- [ ] Copy 12 C source files from wasm3 commit `79d412ea`:
  `m3_api_libc.c`, `m3_api_meta.c`, `m3_api_tracer.c`, `m3_api_uvwasi.c`,
  `m3_api_wasi.c`, `m3_bind.c`, `m3_code.c`, `m3_compile.c`, `m3_core.c`,
  `m3_emit.c`, `m3_env.c`, `m3_exec.c`, `m3_function.c`, `m3_info.c`,
  `m3_module.c`, `m3_optimize.c`, `m3_parse.c`
- [ ] Copy all headers: `m3_*.h`, `wasm3.h`, `wasm3_defs.h`
- [ ] Create `third_party/wasm3/VERSION` with content: `79d412ea`
- [ ] Verify: `ls third_party/wasm3/source/*.c | wc -l` matches expected count

## T1b: build.zig integration

- [ ] Add build option:
  ```zig
  const use_wasm = b.option(bool, "wasm", "Link wasm3 runtime (default: true)") orelse true;
  ```
- [ ] When `use_wasm = true`:
  - `addCSourceFiles` for all `.c` files in `third_party/wasm3/source/`
  - Compile flags: `.{ "-std=c99", "-DDEBUG=0", "-Dd_m3HasWASI=0" }`
  - `addIncludePath(b.path("third_party/wasm3/source/"))`
  - Add `wasm3_backend` import to `exe_mod`, `src_mod`, `unit_mod`, `tsan_mod`
- [ ] When `use_wasm = false`:
  - No wasm3 C sources compiled
  - No `wasm3_backend` import added
- [ ] Both `exe` and `unit_tests` link `libc` (already true)
- [ ] Verify: `zig build -Dwasm=true` compiles without errors
- [ ] Verify: `zig build -Dwasm=false` compiles without errors

## T1c: wasm3_backend.zig — Wasm3Plugin struct

- [ ] Create `src/wasm/wasm3_backend.zig`
- [ ] Import wasm3 C API via `@cImport(@cInclude("wasm3.h"))`
- [ ] Define `Wasm3Plugin` struct:
  ```zig
  pub const Wasm3Plugin = struct {
      env: ?m3.IM3Environment = null,
      rt: ?m3.IM3Runtime = null,
      module: ?m3.IM3Module = null,
      ctx: ?*HostContext = null,
      trap_count: u32 = 0,
      last_trap_ts: i64 = 0,
      allocator: std.mem.Allocator,
  };
  ```
- [ ] Implement `create(allocator) !WasmPlugin`:
  - Allocate `Wasm3Plugin` on heap
  - Return `WasmPlugin{ .ptr = self, .vtable = &vtable }`
- [ ] Implement `load(wasm_bytes, ctx) LoadError!void`:
  - `m3_NewEnvironment()`
  - `m3_NewRuntime(env, 1024 * 1024, null)` — 1MB stack/memory limit
  - `m3_ParseModule(env, &module, wasm_bytes.ptr, wasm_bytes.len)`
  - `m3_LoadModule(rt, module)`
  - Call `bindHostFunctions()` (T1d)
  - On any wasm3 error: return `LoadError.PluginLoadFailed`
- [ ] Implement `unload()`:
  - `m3_FreeRuntime(rt)`, `m3_FreeEnvironment(env)`
  - Set all pointers to `null`
- [ ] Implement `destroy(allocator)`:
  - Call `unload()` if `env != null`
  - `allocator.destroy(self)`
- [ ] Define `const vtable = WasmPlugin.VTable{ ... }` with all 6 function pointers

## T1d: Host function binding

- [ ] Implement `bindHostFunctions(rt, ctx)` in `wasm3_backend.zig`:
  - For each of the 7 host functions, call `m3_LinkRawFunctionEx`:
    ```zig
    _ = m3.m3_LinkRawFunctionEx(module, "env", "device_read", "i(iii)", hostDeviceRead, ctx);
    ```
  - Missing imports are non-fatal (plugin may not use all host functions)
- [ ] Implement each host callback as a `fn` with signature `callconv(.C)`:
  - Extract args from wasm3 runtime stack
  - Validate pointer+length within linear memory: `m3_GetMemory(rt, &mem_size, 0)`
  - If `ptr + len > mem_size`: log warning, return -1
  - Read/write host-side data at `mem[ptr..ptr+len]`
  - Delegate to `HostContext` method
- [ ] 7 callbacks: `hostDeviceRead`, `hostDeviceWrite`, `hostLog`, `hostGetConfig`,
  `hostSetState`, `hostGetState`, `hostGetReportField`
- [ ] All bounds checks use `@intCast` with explicit range validation (no UB on negative ptr)

## T1e: processReport / initDevice / processCalibration

- [ ] Implement `initDevice()`:
  - `m3_FindFunction(&fn_ptr, rt, "init_device")`
  - If not found: return `false`
  - Call `m3_Call(fn_ptr, 0, null)` — if trap, increment trap counter, return `false`
  - Read return value via `m3_GetResultsI(fn_ptr)`: return `result == 0`
- [ ] Implement `processCalibration(buf)`:
  - Get linear memory pointer via `m3_GetMemory`
  - Copy `buf` to linear memory at offset 0 (scratch input area)
  - Find `process_calibration` export; if absent, return silently
  - Call with args `(ptr=0, len=buf.len)`
  - On trap: increment trap counter, log warning
- [ ] Implement `processReport(raw, out)`:
  - Copy `raw` to linear memory offset 0
  - Find `process_report` export; if absent, return `.passthrough`
  - Call with args `(raw_ptr=0, raw_len=raw.len, out_ptr=4096, out_len=out.len)`
  - On trap: increment trap counter, return `.drop`
  - Read return value:
    - `0` → copy `out.len` bytes from linear memory offset 4096 to `out`, return `.passthrough`
    - `1` → copy bytes, construct `GamepadStateDelta` from out buffer, return `.override`
    - other → return `.drop`
- [ ] Implement trap rate limiting:
  - On every trap: check monotonic timestamp
  - If elapsed > 1s since `last_trap_ts`: reset `trap_count = 1`
  - Else: `trap_count += 1`
  - If `trap_count >= 10`: call `unload()`, log `"plugin auto-unloaded: trap rate exceeded"`

---

## T2: DualSense calibration WASM plugin (deferred)

Depends on: T1 fully verified and merged.

- [ ] Create `plugins/dualsense_calibration.wat` — WAT source implementing `init_device`:
  - Call `env.device_write` to send calibration request (report 0x05)
  - Call `env.device_read` to receive calibration response
  - Parse calibration data, store via `env.set_state`
- [ ] Compile to `plugins/dualsense_calibration.wasm`
- [ ] Add `[wasm]` section to `devices/sony/dualsense.toml`:
  ```toml
  [wasm]
  plugin = "plugins/dualsense_calibration.wasm"
  ```
- [ ] Integration test: MockDeviceIO returns synthetic calibration data; verify `init_device`
  stores parsed values via `getState`

## T3: WASM SDK documentation (deferred)

Depends on: T1 and T2.

- [ ] Create `sdk/plugin.h` — C header defining the 3 export signatures and 7 import declarations
- [ ] Create `sdk/README.md` — build instructions for C/Zig/Rust plugins targeting `wasm32-freestanding`
- [ ] Create `sdk/examples/echo.c` — minimal echo plugin in C
- [ ] Verify: `clang --target=wasm32 -nostdlib sdk/examples/echo.c -o echo.wasm` compiles

---

## Post-merge wrap-up

- [ ] Archive this OpenSpec
- [ ] Update `planning/roadmap.md` Phase 9a status

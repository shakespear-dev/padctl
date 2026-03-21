# Design: Phase 9a — WASM Real Integration (wasm3)

## Files

| File | Role |
|------|------|
| `third_party/wasm3/source/*.c` | Vendored wasm3 C source (17 files + headers) |
| `third_party/wasm3/source/*.h` | Vendored wasm3 headers |
| `build.zig` | `-Dwasm` flag, `addCSourceFiles`, wasm3 module injection |
| `src/wasm/wasm3_backend.zig` | `Wasm3Plugin` struct implementing `WasmPlugin.VTable` (to be created) |
| `src/wasm/runtime.zig` | Add conditional import: wasm3 backend or MockPlugin |
| `src/main.zig` | Add `wasm3_backend` to `refAllDecls` for test discovery |
| `src/test/fixtures/echo_plugin.wasm` | Pre-compiled echo plugin (from WAT) (to be created) |
| `src/test/fixtures/no_exports.wasm` | Pre-compiled module with no WASM exports (to be created) |
| `src/test/fixtures/trap_plugin.wasm` | Pre-compiled module that traps on call (to be created) |

## Architecture

### Vendoring Strategy

wasm3 source is vendored at `third_party/wasm3/` pinned to commit `79d412ea`. The directory
contains only the `source/` subdirectory (17 `.c` files, ~15 headers). No build system files,
no tests, no examples. A `third_party/wasm3/VERSION` file records the pinned commit hash.

Rationale: wasm3 is ~100KB compiled; vendoring avoids system dependency (P5). Pinned commit
ensures reproducible builds across machines.

### Build Integration

```
build.zig
  ├── -Dwasm=true (default)  → link wasm3 C sources, inject wasm3 module
  └── -Dwasm=false            → skip wasm3, MockPlugin remains the only backend
```

When `-Dwasm=true`:
1. `addCSourceFiles` compiles the 17 wasm3 `.c` files with `-std=c99 -DDEBUG=0 -Dd_m3HasWASI=0`
   (Note: `d_m3HasWASI` is the correct wasm3 config macro name — verify against pinned commit headers at vendor time)
2. `addIncludePath` points to `third_party/wasm3/source/`
3. The `wasm3_backend` module is added as an import to the main exe, test, and tsan modules
4. `src/wasm/runtime.zig` conditionally imports `wasm3_backend.zig` via `@import`

When `-Dwasm=false`:
1. No C files compiled, no include path added
2. `wasm3_backend` import is absent; `runtime.zig` uses a compile-time sentinel
3. `createWasm3Plugin` returns `error.WasmNotAvailable`

### Wasm3Plugin Struct

```zig
pub const Wasm3Plugin = struct {
    env: ?*m3.IM3Environment,
    rt: ?*m3.IM3Runtime,
    module: ?*m3.IM3Module,
    ctx: ?*HostContext,
    trap_count: u32,
    last_trap_ts: i64,
    allocator: std.mem.Allocator,
};
```

Lifecycle:
1. `create(allocator)` — allocates struct, zeroes all pointers
2. `load(wasm_bytes, ctx)` — calls `m3_NewEnvironment`, `m3_NewRuntime` (1MB memory limit),
   `m3_ParseModule`, `m3_LoadModule`, then binds host functions
3. `initDevice()` — finds `init_device` export via `m3_FindFunction`, calls it; returns false
   if export not found
4. `processCalibration(buf)` — copies `buf` to wasm3 linear memory scratch area (offset 0),
   finds and calls `process_calibration(ptr=0, len=buf.len)`
5. `processReport(raw, out)` — copies `raw` to scratch area offset 0, calls
   `process_report(raw_ptr=0, raw_len, out_ptr=4096, out_len)`, reads back from offset 4096
6. `unload()` — calls `m3_FreeRuntime`, `m3_FreeEnvironment`, zeroes pointers
7. `destroy(allocator)` — calls `unload` if not yet unloaded, then `allocator.destroy(self)`

### Memory Layout

wasm3 linear memory scratch area (within the 1MB limit):

```
Offset     Size    Purpose
0x0000     4096    Raw input buffer (host writes, plugin reads)
0x1000     4096    Output buffer (plugin writes, host reads)
0x2000+    rest    Plugin-managed heap (malloc within linear memory)
```

Host copies data into/from these fixed offsets before/after each call. The plugin receives
pointer+length pairs referring to these offsets within its own linear memory address space.

### Host Function Binding

6 host functions registered under module `"env"` via `m3_LinkRawFunctionEx`:

| WASM Import | C Signature | HostContext Method |
|-------------|-------------|--------------------|
| `env.device_read` | `(report_id: i32, buf_ptr: i32, buf_len: i32) -> i32` | `deviceRead` |
| `env.device_write` | `(buf_ptr: i32, buf_len: i32) -> i32` | `deviceWrite` |
| `env.log` | `(level: i32, msg_ptr: i32, msg_len: i32) -> void` | `log` |
| `env.get_config` | `(key_ptr: i32, key_len: i32, out_ptr: i32, out_len: i32) -> i32` | `getConfig` |
| `env.set_state` | `(key_ptr: i32, key_len: i32, val_ptr: i32, val_len: i32) -> void` | `setState` |
| `env.get_state` | `(key_ptr: i32, key_len: i32, out_ptr: i32, out_len: i32) -> i32` | `getState` |

Each host function callback:
1. Extracts pointer+length args from the wasm3 stack
2. Validates pointer+length within wasm3 linear memory bounds (reject if OOB)
3. Reads/writes host-side data via `HostContext` methods
4. Pushes return value to wasm3 stack

Bounds-check failure logs a warning and returns -1 (or void); no trap, no crash.

### Trap Rate Limiting

Per ADR-005, plugins that trap repeatedly are auto-unloaded:

- `Wasm3Plugin` tracks `trap_count` and `last_trap_ts` (monotonic clock)
- On any wasm3 trap (from `processReport`, `initDevice`, or `processCalibration`):
  - If `now - last_trap_ts > 1s`, reset `trap_count = 1`
  - Otherwise, increment `trap_count`
  - If `trap_count >= 10`, call `unload()` and log error
- Rate: 10 traps/second threshold before auto-unload

### Conditional Compilation

`runtime.zig` uses build-time option to select backend:

```zig
const wasm3_available = @hasDecl(@import("root"), "wasm3_backend");

pub fn createWasm3Plugin(allocator: std.mem.Allocator) !WasmPlugin {
    if (comptime wasm3_available) {
        return wasm3_backend.Wasm3Plugin.create(allocator);
    }
    return error.WasmNotAvailable;
}
```

This preserves MockPlugin for all existing tests regardless of `-Dwasm` setting.

### Test Fixtures

3 WAT source files compiled to `.wasm` via `wat2wasm` (offline, committed as binary):

**echo_plugin.wat**: exports `init_device() -> 0`, `process_report(raw_ptr, raw_len, out_ptr,
out_len) -> 0`. Copies `raw_len` bytes from `raw_ptr` to `out_ptr` using `memory.copy`.

**no_exports.wat**: valid WASM module with no function exports. Tests graceful handling of
missing exports.

**trap_plugin.wat**: exports `process_report` that executes `unreachable` (WASM trap). Tests
trap capture and rate limiting.

## Key Design Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | Vendor wasm3 source, not system library | P5 single binary; no runtime dependency |
| D2 | `-Dwasm=true` default | WASM is a core feature (P7); opt-out for minimal builds |
| D3 | 8KB scratch area (2x 4KB) | Matches max HID report size (4096B); simple fixed-offset protocol |
| D4 | 1MB linear memory limit | ADR-005 constraint; sufficient for stateless protocol plugins |
| D5 | Host functions validate all pointer+length args | Sandbox boundary; malicious plugin cannot read host memory |
| D6 | Trap rate limit (10/s) not timeout watchdog | Timeout requires timerfd thread (separate task); rate limit is simpler first step |
| D7 | Pre-compiled .wasm fixtures committed as binary | Avoids `wat2wasm` build dependency; fixtures are small (<1KB each) |
| D8 | MockPlugin preserved alongside Wasm3Plugin | P9: existing mock-based tests unchanged; wasm3 tests are additive |

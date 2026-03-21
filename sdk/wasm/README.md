# padctl WASM Plugin SDK

## Overview

A padctl WASM plugin is a `.wasm` module that handles device protocols too
stateful or complex for the declarative TOML DSL (design principle P7). Typical
use cases: multi-step handshake sequences, custom checksum computation,
calibration data interpretation (e.g. DualSense adaptive triggers).

**If the TOML DSL can express it, do not write a plugin.** Plugins exist solely
as an escape hatch for stateful protocols.

## Plugin Lifecycle

```
load ──► init_device ──► process_calibration ──► process_report (per frame) ──► unload
                              (on Feature Report)       (when override enabled)
```

1. **load** -- padctl reads the `.wasm` file specified in `[wasm] plugin`, parses
   the module, links host functions, and instantiates the runtime.
2. **init_device** -- called once after the device is opened. Use this for
   handshake sequences (feature report reads/writes via host functions).
3. **process_calibration** -- called when a Feature Report arrives with
   calibration data. The raw bytes are copied into the input scratch area.
4. **process_report** -- called every input frame when
   `wasm.overrides.process_report = true`. The raw HID report is in the input
   buffer; write transformed data to the output buffer.
5. **unload** -- padctl tears down the wasm3 runtime on device disconnect,
   fatal error, or trap rate limit exceeded.

All exports are optional. Missing exports are silently skipped -- the device
falls back to pure TOML parsing for that hook.

## Exported Functions (plugin implements these)

### `init_device() -> i32`

Optional. Called once after device open.

- Return `0` for success.
- Return non-zero to signal init failure (non-fatal; padctl logs and continues).
- Timeout: 5 seconds.

### `process_calibration(buf_ptr: i32, buf_len: i32)`

Optional. Called when calibration data (Feature Report) arrives.

- `buf_ptr` -- offset in linear memory where calibration bytes are placed
  (input scratch area, `0x0000`).
- `buf_len` -- byte count.
- No return value.

### `process_report(raw_ptr: i32, raw_len: i32, out_ptr: i32, out_len: i32) -> i32`

Optional. Called per input frame only when `[wasm.overrides] process_report = true`.

- `raw_ptr` / `raw_len` -- raw HID report in the input scratch area (`0x0000`).
- `out_ptr` / `out_len` -- output scratch area (`0x1000`) for override data.
- Return `>= 0` -- signals override; host reads the full output buffer.
- Return `< 0` -- drop this frame (padctl keeps previous gamepad state).
- Timeout: 1 ms.

## Imported Host Functions (plugin calls these)

All imports use module name `"env"`.

### `device_read(report_id: i32, buf_ptr: i32, buf_len: i32) -> i32`

Read a HID Feature Report from the device.

- `report_id` -- HID report ID to request.
- `buf_ptr` / `buf_len` -- destination buffer in plugin linear memory.
- Returns bytes read, or `< 0` on error.

### `device_write(buf_ptr: i32, buf_len: i32) -> i32`

Write an HID Output Report to the device.

- `buf_ptr` / `buf_len` -- source buffer in plugin linear memory.
- Returns bytes written, or `< 0` on error.

### `log(level: i32, msg_ptr: i32, msg_len: i32)`

Write a log message to padctl's log output.

- `level` -- `0` = debug, `1` = error.
- Messages are truncated at 256 bytes by the host.
- In C, call `padctl_log()` (declared in `padctl_plugin.h`). The WASM import name
  is `env.log` via `__attribute__((import_name("log")))`, avoiding the `math.h`
  `log()` collision.

### `get_config(key_ptr: i32, key_len: i32, out_ptr: i32, out_len: i32) -> i32`

Read a device config field value (from the TOML file) as a UTF-8 string.

- `key_ptr` / `key_len` -- field name (e.g. `"left_x.offset"`).
- `out_ptr` / `out_len` -- destination buffer.
- Returns byte count written, or `< 0` on error.

### `set_state(key_ptr: i32, key_len: i32, val_ptr: i32, val_len: i32)`

Write a key-value entry to the per-plugin persistent store (survives across
frames within one device session).

- Max 256 entries, max 4096 bytes per value.

### `get_state(key_ptr: i32, key_len: i32, out_ptr: i32, out_len: i32) -> i32`

Read a previously stored key-value entry.

- Returns byte count copied into `out`, or `0` if key not found.

### `abort`

Not yet implemented. Documented in engineering spec as a future addition.

## Memory Model

- Linear memory limit: **1 MB** (memory.grow beyond this returns -1).
- Scratch areas used by the host to pass data:
  - `0x0000 - 0x0FFF` (4 KB) -- input buffer (raw report / calibration data).
  - `0x1000 - 0x1FFF` (4 KB) -- output buffer (override data from process_report).
- Stack size: 1 MB (wasm3 operand stack, not linear memory).
- Memory above `0x2000` is free for plugin use (globals, heap, etc.).

## Error Handling

- A wasm3 **trap** (out-of-bounds memory access, unreachable, stack overflow)
  causes the current frame to be skipped. padctl logs the error and continues.
- If traps exceed **10 per second**, the plugin is automatically unloaded and
  the device falls back to pure TOML parsing.

## Building a Plugin

Compile C, Rust, or Zig source to `wasm32-unknown-unknown` (no WASI needed).

### C (clang)

```sh
clang --target=wasm32 -nostdlib -O2 \
    -Wl,--no-entry -Wl,--export=init_device \
    -Wl,--export=process_report -Wl,--export=process_calibration \
    -Wl,--export=memory \
    -o my_plugin.wasm my_plugin.c
```

Include `padctl_plugin.h` from this directory for host function declarations.

### Zig

```sh
zig build-lib -target wasm32-freestanding -O ReleaseSafe \
    --export=init_device --export=process_report \
    -o my_plugin.wasm my_plugin.zig
```

### Rust

```sh
cargo build --target wasm32-unknown-unknown --release
```

Use `#[no_mangle] pub extern "C" fn` for exported functions and
`extern "C"` blocks for host imports.

## TOML Configuration

In your device config file:

```toml
[wasm]
plugin = "plugins/my_device.wasm"

[wasm.overrides]
process_report = true   # enable per-frame process_report hook
```

- `plugin` -- path to the `.wasm` file (relative to config directory).
- `process_report` -- must be explicitly `true` to activate the per-frame hook.
  When `false` or absent, `process_report` is never called even if exported.

## Example (WAT)

Minimal echo plugin that copies input report to output unchanged:

```wat
(module
  (memory (export "memory") 1)
  (export "init_device" (func $init))
  (export "process_report" (func $report))

  (func $init (result i32)
    i32.const 0)          ;; return 0 = success

  (func $report (param i32 i32 i32 i32) (result i32)
    local.get 2           ;; out_ptr
    local.get 0           ;; raw_ptr
    local.get 1           ;; raw_len
    memory.copy           ;; copy raw -> out (requires bulk-memory; wasm3 support depends on build config)
    i32.const 0))         ;; return 0 = override with output
```

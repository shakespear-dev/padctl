# Phase 4 Design: Community Configs, Docs Site, WASM Plugin, Packaging

## Design Decisions

| # | Decision | Resolution | Rationale |
|---|----------|-----------|-----------|
| D1 | Community config repo model | QMK monorepo (`devices/<vendor>/`) | TOML files are pure data (~100–300 lines each); central CI quality gate; distributed ZMK-style module repos have poor discoverability and no unified validation |
| D2 | `--validate` check set | Syntax + schema (required fields) + offset bounds + field name uniqueness + button_group bit range + match non-overlap + checksum algo legality | Deterministic static checks, no real device needed; mirrors `qmk lint` scope |
| D3 | WASM runtime | wasm3 (primary); wasmtime C API (build-option fallback) | wasm3: ~100 KB pure C, <20 ms cold start, `@cImport` zero-binding; wasmtime: ~5–10 MB, JIT, WASI — overkill for short init/calibration sequences; wasm3 satisfies P5 single-binary constraint |
| D4 | WASM plugin ABI | Three progressive hooks: `init_device` / `process_calibration` / `process_report`; `process_report` only active when `[wasm.overrides] process_report = true` | Most devices need only TOML; stateful handshake adds `init_device`; calibration adds `process_calibration`; full override is the exception |
| D5 | WASM sandbox parameters | 1 MB memory cap + execution timeout (init 5 s / process 1 ms) + no WASI | WASM spec-level memory isolation; deny-by-default syscalls via no-WASI policy; superior to Lua manual stdlib removal |
| D6 | Docs tool | mdbook | Single binary, Markdown-native, no Node/Python dep; same tool as Zig, Wasmtime, and Zola official docs |
| D7 | `--doc-gen` design | Shares TOML parser with `--validate`; outputs Markdown device reference page (field table + button map + command templates + WASM note) | No duplicated parse logic; validate → doc-gen → mdbook build run serially in CI |
| D8 | Distribution priority | GitHub Release (P0) + AUR PKGBUILD + padctl-bin (P0); Nix flake (P1) | Arch Linux is padctl's primary user base; Zig native cross-compilation produces musl static binaries with zero toolchain setup |
| D9 | Output DSL emulate | `[output] vid/pid/name` + `[output.capabilities]` in device TOML | Steam game-compatibility via controller identity spoofing; capabilities override the values inferred from `[input]` section |

## Architecture

### `padctl --validate`: Static Checker

`src/tools/validate.zig` reuses the existing `config.device` TOML parser. After successful parse it runs seven deterministic passes:

```
Pass 1  TOML syntax          — parser returns error.InvalidToml on bad syntax
Pass 2  Schema compliance     — [device] name/vid/pid present + ≥1 [[report]]
Pass 3  Offset bounds         — each field: offset + sizeof(type) ≤ report.size
Pass 4  Field name uniqueness — no two fields in same [[report]] share a name
Pass 5  Button_group bit range — bit_index < 8 * field_size for every declared button
Pass 6  Match non-overlap     — for same report id, no two [[report]] match conditions can simultaneously be satisfied by any byte sequence
Pass 7  Checksum algo legality — algo ∈ {crc32, crc8, xor, none}
```

Exit codes: 0 = valid; 1 = validation errors (printed to stderr with file:line); 2 = I/O / parse error.

CLI:
```
padctl --validate [<file> ...]
padctl --validate devices/**/*.toml   # glob expanded by shell
```

### Device Config Directory Layout

```
devices/
├── flydigi/vader5.toml        (relocated from devices/ root)
├── sony/
│   ├── dualsense.toml
│   └── dualsense.wasm         (reference WASM plugin, built from sdk/ example)
├── nintendo/switch-pro.toml
├── 8bitdo/ultimate.toml
└── microsoft/xbox-elite.toml
```

### `padctl --doc-gen`: Reference Page Generator

`src/tools/docgen.zig` reads one or more TOML files (same parse path as validate) and writes `docs/src/devices/<vendor>-<model>.md` for each. Page structure:

```markdown
# <device.name> (VID:PID)

## Interfaces
| ID | Class |

## Reports
### <report.name>
| Field | Offset | Type | Transform | Notes |
...
## Buttons
| Bit | Name |
...
## Commands
### <command_name>
Template: `...`
## WASM Plugin
Plugin: `<wasm.plugin>` — overrides: <list>
```

`[report.button_group]` bit positions are expanded into individual rows using `bits` declarations within the TOML. For buttons without explicit names, the bit index is used as the name.

CI pipeline:
```
padctl --validate devices/**/*.toml
  └─► padctl --doc-gen devices/**/*.toml --output docs/src/devices/
        └─► mdbook build docs/
              └─► gh-pages deploy
```

### WASM Plugin Runtime

#### Component layout

```
src/wasm/
├── runtime.zig         wasm3 init/deinit, module load, memory limit
├── host_functions.zig  host → WASM function table registration
└── plugin.zig          plugin lifecycle: load → init_device → per-report dispatch
```

#### wasm3 integration in build.zig

wasm3 is a C library added as a build dependency via `b.dependency("wasm3", ...)`. `runtime.zig` wraps it via `@cImport`. When the `wasm3` build option is disabled, the `[wasm]` TOML section is accepted but ignored (graceful degradation).

#### Host function ABI (padctl → WASM)

Import module: `"env"`.

| Host Function | Signature | Semantics |
|---|---|---|
| `device_read` | `(report_id: i32, buf_ptr: i32, buf_len: i32) -> i32` | Read Feature Report; returns actual byte count, <0 on error |
| `device_write` | `(buf_ptr: i32, buf_len: i32) -> i32` | Write Output Report; returns bytes written, <0 on error |
| `log` | `(level: i32, msg_ptr: i32, msg_len: i32) -> void` | Write log; level 0=debug, 1=error; host truncates overlong messages |
| `get_config` | `(key_ptr: i32, key_len: i32, val_ptr: i32, val_cap: i32) -> i32` | Read device config field value as UTF-8 string; returns actual byte count |
| `set_state` | `(key_ptr: i32, key_len: i32, val_ptr: i32, val_len: i32) -> void` | Write cross-frame persistent key-value; host maintains per-plugin map |
| `abort` | `(msg_ptr: i32, msg_len: i32) -> void` | Plugin self-terminates (wasm3 trap); host records reason then unloads |

All `ptr` parameters are offsets into the plugin's linear memory. The host validates `ptr + len ≤ memory_size` before any access; out-of-bounds triggers a trap.

#### Plugin export hooks (WASM → padctl)

```
init_device() -> i32
  Called once after [device.init] commands complete.
  Returns 0 on success, negative on error.
  Timeout: 5 s.

process_calibration(cal_buf_ptr: u32, cal_buf_len: u32) -> i32
  Called with Feature Report bytes.
  Plugin reads calibration values and caches them internally.
  Returns 0 on success.

process_report(raw_ptr: u32, raw_len: u32, out_ptr: u32, out_len: u32) -> i32
  Only active when TOML declares [wasm.overrides] process_report = true.
  Plugin writes override field values into out buffer.
  Returns number of bytes written; 0 = no override.
  Timeout: 1 ms.
```

Missing exports degrade gracefully: if `init_device` is absent, padctl skips the hook and proceeds in pure-TOML mode. If `process_report` is absent but declared in TOML, it is treated as a TOML validation warning.

#### Sandbox enforcement

- Memory: wasm3 `M3Runtime` `memoryLimit` = 1 MB. Any allocation attempt beyond this causes a wasm3 trap.
- Timeout: a dedicated `timerfd` + thread cancellation watchdog. Timeout fires → runtime force-terminates WASM execution → padctl logs error and either retries (init) or drops the frame (process_report).
- No WASI: host function table contains only the six functions above. WASM modules attempting undeclared imports fail to load.

#### TOML WASM declaration

```toml
[wasm]
plugin = "devices/sony/dualsense.wasm"

[wasm.overrides]
process_report = true    # optional; default false
```

#### Timeout watchdog

`process_report` 1 ms timeout uses a `timerfd` + dedicated watchdog thread: timerfd set before each call; on expiry watchdog checks an `atomic_flag`; if execution is still IN_PROGRESS it sets `should_abort`, which wasm3 checks at its next instruction checkpoint (`IM3Runtime->abort` callback). `init_device` uses the same mechanism with 5 s threshold. `process_calibration` has no hard timeout (low-frequency operation) but its duration is logged.

#### Plugin SDK

`sdk/plugin.h` — C header declaring all host function prototypes and hook signatures. Distributed with each release so contributors can write plugins in C, Zig, or any WASM-targeting language.

### Output DSL Emulate Extension

`src/output.zig` gains emulate fields read from `[output]` section:

```toml
[output]
vid  = 0x054c
pid  = 0x0ce6
name = "DualSense"

[output.capabilities]
axes    = ["ABS_X", "ABS_Y", "ABS_RX", "ABS_RY", "ABS_Z", "ABS_RZ"]
buttons = ["BTN_SOUTH", "BTN_EAST", "BTN_NORTH", "BTN_WEST"]
rumble  = true
```

When `[output]` is present, uinput device creation uses the declared VID/PID/name instead of defaults. When `[output.capabilities]` is present, its axis and button lists replace the inferred capabilities. Absent `[output]` → behaviour identical to pre-Phase-4 (regression-safe).

### Packaging

#### GitHub Release CI (`.github/workflows/release.yml`)

Triggered on `v*` tag push. Matrix: `[x86_64-linux-musl, aarch64-linux-musl]`.

```
zig build -Doptimize=ReleaseSafe -Dtarget=${{ matrix.target }}
strip zig-out/bin/padctl
tar czf padctl-$VERSION-$TARGET.tar.gz -C zig-out/bin padctl
gh release upload $TAG padctl-$VERSION-$TARGET.tar.gz
```

Includes `devices/`, `contrib/`, and `sdk/plugin.h` in the tarball.

#### AUR PKGBUILD (`contrib/aur/PKGBUILD`)

- `makedepends=('zig')`, no runtime deps.
- `package()` installs: `padctl` binary + `padctl@.service` + `80-padctl.rules` + `devices/`.
- `padctl-bin/PKGBUILD` fetches prebuilt binary from Release tarball, skips compile step.

#### Nix flake (`flake.nix`)

Based on `zig2nix`. Supports `x86_64-linux` and `aarch64-linux`. `packages.default` and `devShells.default` both defined.

## Data Flow

### validate pipeline

```
TOML file(s)  →  config.device.parse()  →  7 check passes  →  error list  →  stderr + exit code
```

### doc-gen pipeline

```
TOML file  →  config.device.parse()  →  Markdown template render  →  docs/src/devices/*.md
```

### WASM plugin dispatch

```
DeviceInstance.run():
  on open:  plugin.load(path) → register host fns → init_device()
  on Feature Report:  process_calibration(buf)
  on Input Report:
    if wasm.overrides.process_report:
      process_report(raw, out) → merge overrides into GamepadState
    else:
      interpreter.processReport(raw) → GamepadState
```

### emulate output path

```
[output] section parsed by config.device  →  stored in DeviceConfig.output
DeviceInstance.initUinput():
  vid/pid/name  ←  output.vid/pid/name ?? defaults
  capabilities  ←  output.capabilities ?? inferred from [input]
```

## Edge Cases

| Case | Handling |
|------|----------|
| `--validate` glob produces zero matches | Exit 0 with info message; not an error |
| WASM plugin file missing at runtime | Log error; fall back to pure-TOML mode; continue |
| `init_device` returns non-zero | Log error with return value; device init fails; DeviceInstance exits |
| `process_report` timeout (1 ms) | Drop current frame; log warning; increment timeout counter; no crash |
| WASM module has no exports at all | Loads successfully; no hooks called; operates in TOML mode |
| `[output.capabilities]` declares axis not in kernel's EV_ABS table | `uinput` ioctl returns EINVAL; DeviceInstance logs and exits |
| Validate pass 6 (match overlap): two `[[report]]` with no `match` | Second entry is flagged as unreachable (first always wins) |
| `--doc-gen` on TOML with no `[report.button_group]` | Button section omitted from output Markdown; no error |
| aarch64 cross-compile with wasm3 C lib | wasm3 is pure C with no arch-specific asm; cross-compiles cleanly via Zig's bundled clang |

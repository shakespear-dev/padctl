# Phase 4 Test Plan

## Test Layers

| Layer | Description | CI |
|-------|-------------|-----|
| L0 | Pure functions / static files — no fd, no kernel | Yes |
| L1 | Mock fd / injected bytes — no `/dev/hidraw`, no real hardware | Yes |
| L2 | Real devices — physical controller, `/dev/uinput` available | Manual only |

All L0 + L1 tests live under `zig build test` and must pass in CI.

---

## T1: Community Device Configs + `padctl --validate` (L0/L1)

### Validate pass 1–2: syntax and schema

| # | Input | Expected |
|---|-------|----------|
| 1 | Valid TOML with `[device] name/vid/pid` + one `[[report]]` | 0 errors, exit 0 |
| 2 | TOML missing `[device] pid` | schema error reported, exit 1 |
| 3 | TOML with no `[[report]]` section | schema error: at least one report required, exit 1 |
| 4 | Syntactically invalid TOML (unclosed bracket) | parse error, exit 2 |

### Validate pass 3: offset bounds

| # | Input | Expected |
|---|-------|----------|
| 5 | `offset = 60, type = "u32le"` in 64-byte report | pass (60+4=64, boundary OK) |
| 6 | `offset = 61, type = "u32le"` in 64-byte report | offset-bounds error: 61+4=65 > 64 |
| 7 | `offset = 0, type = "u8"` in 1-byte report | pass (0+1=1, exact boundary) |

### Validate pass 4: field name uniqueness

| # | Input | Expected |
|---|-------|----------|
| 8 | Two fields with name `"left_x"` in same `[[report]]` | uniqueness error |
| 9 | Two fields with name `"left_x"` in different `[[report]]` blocks | pass (uniqueness is per-report) |

### Validate pass 5: button_group bit range

| # | Input | Expected |
|---|-------|----------|
| 10 | Button with `bit_index = 7` in single-byte group | pass (7 < 8×1) |
| 11 | Button with `bit_index = 8` in single-byte group | bit-range error (8 ≥ 8×1) |
| 12 | Button with `bit_index = 15` in two-byte group | pass (15 < 8×2) |

### Validate pass 6: match non-overlap

| # | Input | Expected |
|---|-------|----------|
| 13 | Two `[[report]]` with identical `match` bytes | overlap error |
| 14 | Two `[[report]]` with no `match` (id only) | second entry flagged unreachable |
| 15 | Two `[[report]]` with disjoint `match` bytes | pass |

### Validate pass 7: checksum algo legality

| # | Input | Expected |
|---|-------|----------|
| 16 | `checksum.algo = "crc32"` | pass |
| 17 | `checksum.algo = "md5"` | unknown-algo error |
| 18 | No `[checksum]` section | pass (optional) |

### CLI exit codes

| # | Scenario | Expected exit code |
|---|----------|-------------------|
| 19 | All files valid | 0 |
| 20 | At least one validation error | 1 |
| 21 | File not found | 2 |
| 22 | Glob produces zero matches | 0 (info message to stderr) |

### Report parse (L1)

| # | Input | Expected |
|---|-------|----------|
| 23 | DualSense 64-byte USB report (byte 0 = 0x01, stick bytes, trigger bytes, button bytes, IMU bytes) | `interpreter.processReport()` returns delta with correct `left_x`, `gyro_x`, button bits |
| 24 | Switch Pro BT report (49 bytes, report id 0x30) | all declared button and axis fields parse correctly |

---

## T2: Docs Site + `padctl --doc-gen` (L0)

### Page structure

| # | Input | Expected |
|---|-------|----------|
| 1 | `generateDevicePage` with DualSense config | output contains `0x054c:0x0ce6` in header |
| 2 | Config with 6 fields in a report | field table has exactly 6 data rows |
| 3 | Config with 4 buttons in a button_group | button section has exactly 4 rows |
| 4 | Config with no `[wasm]` section | no WASM section in generated Markdown |
| 5 | Config with `[wasm] plugin = "..."` | WASM section present; plugin path mentioned |

### CLI output path

| # | Scenario | Expected |
|---|----------|----------|
| 6 | `--doc-gen devices/sony/dualsense.toml` | output file at `docs/src/devices/sony-dualsense.md` |
| 7 | `--doc-gen devices/nintendo/switch-pro.toml` | output file at `docs/src/devices/nintendo-switch-pro.md` |

### mdbook integration

| # | Scenario | Expected |
|---|----------|----------|
| 8 | `mdbook build docs/` on generated pages | exits 0; no warnings |
| 9 | `SUMMARY.md` includes generated device pages | mdbook build resolves all links |

---

## T3: Packaging Infrastructure (L0)

### Cross-compilation

| # | Command | Expected |
|---|---------|----------|
| 1 | `zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe` | exits 0; binary produced |
| 2 | `zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe` | exits 0; binary produced |
| 3 | `zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall` | binary size increment vs Phase 3 baseline ≤ 200 KB (wasm3 linkage cost) |

### AUR PKGBUILD

| # | Check | Expected |
|---|-------|----------|
| 4 | `namcap contrib/aur/PKGBUILD` | exits 0; no errors |
| 5 | PKGBUILD `package()` installs binary + service + udev rules + devices/ | install paths match FHS (`/usr/bin`, `/usr/lib/systemd/system/`, `/usr/lib/udev/rules.d/`, `/usr/share/padctl/devices/`) |
| 6 | `padctl-bin/PKGBUILD` specifies no `makedepends` | absent (binary package; no compile step) |

### Release tarball

| # | Check | Expected |
|---|-------|----------|
| 7 | Release CI matrix produces two tarballs | `padctl-*-x86_64-linux-musl.tar.gz` + `padctl-*-aarch64-linux-musl.tar.gz` both non-empty |
| 8 | Tarball contents | includes `padctl` binary, `devices/`, `contrib/`, `sdk/plugin.h` |

---

## T4: WASM Plugin Runtime (L1)

### Happy-path init

| # | Input | Expected |
|---|-------|----------|
| 1 | Minimal WASM module exporting `init_device` returning 0 | `Plugin.initDevice()` returns ok |
| 2 | WASM module with no exports | `Plugin.load()` succeeds; `initDevice()` is a no-op; no error |
| 3 | WASM module with `process_calibration` only | `initDevice()` no-op; `processCalibration()` called successfully |

### Timeout enforcement

| # | Scenario | Expected |
|---|----------|----------|
| 4 | WASM `init_device` contains infinite loop | watchdog fires within 5 s + 100 ms margin; `initDevice()` returns error; padctl does not hang |
| 5 | WASM `process_report` contains infinite loop | watchdog fires within 1 ms + 0.5 ms margin; frame dropped; padctl does not hang |

### Memory safety

| # | Scenario | Expected |
|---|----------|----------|
| 6 | WASM module writes to address 2 MB (beyond 1 MB limit) | wasm3 trap; `processReport()` returns error; no crash; no host memory corruption |
| 7 | WASM `get_config` called with `ptr + len` spanning beyond linear memory | host returns -1; no trap needed; no host memory read |

### Trap handling

| # | Scenario | Expected |
|---|----------|----------|
| 8 | WASM executes `unreachable` instruction | wasm3 trap captured; frame skipped; error logged |
| 9 | Continuous traps: >10 per second for `process_report` | plugin unloaded; padctl continues in pure-TOML mode; warning logged |
| 10 | `abort()` host function called by plugin | plugin unloaded; reason logged; padctl continues |

### Missing export declared in TOML

| # | Scenario | Expected |
|---|----------|----------|
| 11 | `[wasm.overrides] process_report = true` but export absent | warning logged at startup; TOML-only processing used for input reports |

### Host function correctness

| # | Scenario | Expected |
|---|----------|----------|
| 12 | `process_calibration` hook calls `get_config("gyro_x.offset", ...)` | returns string matching field offset in device config |
| 13 | `set_state` stores key; subsequent `get_config` call in same frame | state persists across hook invocations within session |

### Performance benchmarks (L1, pass/fail thresholds)

| # | Scenario | Threshold |
|---|----------|-----------|
| 14 | `init_device` no-op cold start | ≤ 20 ms |
| 15 | `process_report` no-op single call | ≤ 0.5 ms |

---

## T5: Output DSL Emulate Extension (L1)

### VID/PID substitution

| # | Input | Expected |
|---|-------|----------|
| 1 | `[output] vid = 0x054c, pid = 0x0ce6` | `uinput_setup.id.vendor = 0x054c`, `id.product = 0x0ce6` |
| 2 | `[output] name = "DualSense"` | `uinput_setup.name` contains `"DualSense"` |

### Capabilities override

| # | Input | Expected |
|---|-------|----------|
| 3 | `[output.capabilities] axes = ["ABS_X"]` | `UI_SET_ABSBIT` called only for `ABS_X`; no other axes registered |
| 4 | `[output.capabilities] buttons = ["BTN_SOUTH", "BTN_EAST"]` | `UI_SET_KEYBIT` called for `BTN_SOUTH` and `BTN_EAST` only |
| 5 | `[output.capabilities] rumble = true` | `UI_SET_FFBIT` registered |

### Preset convenience

| # | Input | Expected |
|---|-------|----------|
| 6 | `[output] emulate = "xbox-elite2"` | VID/PID/name populated with Xbox Elite Series 2 values |
| 7 | `[output] emulate = "dualsense"` | VID/PID/name populated with DualSense values |
| 8 | `[output] emulate = "unknown-preset"` | config load fails with descriptive error; no crash |

### Regression guard

| # | Input | Expected |
|---|-------|----------|
| 9 | TOML without `[output]` section | uinput setup identical to Phase 3 baseline; no behaviour change |

---

## T6: End-to-end Validation (L0/L1/L2)

### CI suite (L0/L1)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | All T1 validate tests | pass |
| 2 | All T1 report-parse tests | pass |
| 3 | All T2 doc-gen tests | pass |
| 4 | All T3 cross-compile checks | pass |
| 5 | All T4 WASM runtime tests | pass |
| 6 | All T5 output emulate tests | pass |
| 7 | `zig build test` | exits 0; all L0 + L1 cases pass |

### Manual validation (L2, local device required)

| # | Scenario | Pass Condition |
|---|----------|----------------|
| 8 | Load `devices/sony/dualsense.toml` + `dualsense.wasm` | `init_device` returns 0; `padctl-debug` shows calibrated gyro values |
| 9 | `padctl --validate devices/**/*.toml` on full device directory | exit 0; no errors for any shipped config |
| 10 | `padctl-capture` on Switch Pro → apply `--validate` to generated skeleton | exit 0; skeleton passes all 7 passes |
| 11 | `zig build -Dtarget=aarch64-linux-musl` → copy binary to ARM device → `padctl --validate` | exits 0; binary executes natively |
| 12 | `mdbook serve docs/` → open DualSense device page | field table row count matches declared fields; no broken links |

L2 tests use `error.SkipZigTest` guard when no real hidraw device is present.

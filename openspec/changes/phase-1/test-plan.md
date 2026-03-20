# Test Plan: padctl Phase 1

## Test Layer Definitions

| Layer | Description | CI |
|-------|-------------|-----|
| L0 (Unit) | Pure functions, no I/O, no fds, no kernel modules | Always |
| L1 (Mock Integration) | MockDeviceIO + MockOutput vtables, socketpair, no real devices | Always |
| L2 (E2E) | UHID virtual device or real hardware; `zig build test-e2e` | Local manual only |

L2 tests use `error.SkipZigTest` when `/dev/uhid` is absent. Manual verification
points are labeled **[manual]** and triggered pre-release.

`zig build test` = L0 + L1 only.

---

## Layer 0: Unit Tests

### T0 — TOML Spike (spike/toml_spike.zig)

| Test | What | Pass Condition |
|------|------|---------------|
| spike-array-of-tables | Parse `[[report]]` with nested `[report.fields]` sub-table | Struct fields match expected constants |
| spike-hex-match | Parse `match = { offset = 0, expect = [0x5a, 0xa5, 0xef] }` | Hex literals decoded correctly |
| spike-dynamic-keys | Parse `[commands.rumble]` + `[commands.led]` into `StringHashMap` | Both keys accessible |
| spike-optional-nested | Parse `[report.checksum]` as optional nested struct | Struct present with correct algo field |

All four must pass before proceeding to T1/T2.

### T3 — DeviceConfig Schema

| Test | What | Pass Condition |
|------|------|---------------|
| device-config-load-valid | Load well-formed config | Returns `DeviceConfig` without error |
| device-config-offset-oob | Field offset + sizeof exceeds report.size | `error.InvalidConfig` |
| device-config-dup-field | Two fields with identical name in one report | `error.InvalidConfig` |
| device-config-bits-overflow | `bits` start+len > 8 | `error.InvalidConfig` |
| device-config-bad-transform | Transform expression `$val * 2` (arbitrary expr) | `error.InvalidConfig` |
| device-config-checksum-range | Checksum range extends past report.size | `error.InvalidConfig` |
| device-config-commands-template | `[commands.rumble]` template `{strong:u8} {weak:u8}` | Placeholder types parsed correctly |
| device-config-response-prefix | `[device.init].response_prefix` field present | Field loaded as `[]const u8` |

### T4 — OutputConfig Code Resolution

| Test | What | Pass Condition |
|------|------|---------------|
| abs-code-known | `resolveAbsCode("ABS_X")` | Returns correct integer code |
| abs-code-unknown | `resolveAbsCode("INVALID_CODE")` | `error.UnknownAbsCode` |
| btn-code-known | `resolveBtnCode("BTN_SOUTH")` | Returns correct integer code |
| btn-code-unknown | `resolveBtnCode("INVALID_BTN")` | `error.UnknownBtnCode` |

### T5 — hidraw HIDIOCGRAWPHYS Parsing

| Test | What | Pass Condition |
|------|------|---------------|
| hidraw-phys-parse | Extract interface number from `HIDIOCGRAWPHYS` physpath string | Correct interface id for given physpath |
| hidraw-sysfs-parse | Parse sysfs tree rooted at mock tmpdir for `hidrawN/device/input/inputM/eventK` | Returns correct `/dev/input/eventK` paths |

### T6 — RingBuffer

| Test | What | Pass Condition |
|------|------|---------------|
| ring-push-pop | Push then pop single item | Item retrieved correctly |
| ring-overflow | Push `capacity + 1` items | Oldest item dropped; warning logged; newest items intact |
| ring-empty-pop | Pop from empty buffer | Returns null |

### T7 — Protocol Interpreter

| Test | What | Pass Condition |
|------|------|---------------|
| interp-vader5-if1 | 32-byte Vader 5 IF1 sample (magic `5a a5 ef`) | All fields correct: left_x/y, right_x/y, LT/RT, gyro_x/y/z, accel_x/y/z; Y axes negated |
| interp-button-bitfield | Button group extraction from IF1 byte[11-14] | A/B/X/Y/LB/RB and extended buttons at correct bit positions |
| interp-checksum-mismatch | Valid report with corrupted checksum byte | `ProcessError.ChecksumMismatch` |
| interp-raw-too-short | `raw.len < report.size` | Returns `null` |
| interp-no-match | bytes not matching any report rule | Returns `null` |
| interp-crc32-seed | CRC32 with seed=0xa1 using DualSense public test vector | Computed checksum matches expected value |
| interp-sum8 | sum8 checksum on known byte sequence | Correct 8-bit sum |
| interp-xor | xor checksum on known byte sequence | Correct XOR result |
| interp-transform-negate | Field with `transform = "negate"` | Value negated |
| interp-transform-scale | Field with `transform = "scale(0, 1023)"` | Value scaled to target range |
| interp-transform-chain | `"scale(-32768, 32767), negate"` applied left-to-right | Both transforms applied in order |
| interp-lookup-hit | lookup transform with matching entry | Mapped value returned |
| interp-lookup-miss | lookup transform with no matching entry | Original value retained |
| interp-and-match | Report with `match` as array (AND semantics) | Both conditions must be satisfied |
| interp-interface-filter | IF1 report rule does not match IF0 data | Returns `null` |
| interp-stateless | Same input called twice | Identical results |

### T10 — Vader 5 Device Config (L0)

| Test | What | Pass Condition |
|------|------|---------------|
| vader5-config-load | `DeviceConfig.load("devices/flydigi-vader5.toml")` | No error; returns DeviceConfig |
| vader5-config-fields | All offset/bits/transform pass load-time validation | No `error.InvalidConfig` |
| vader5-commands | `[commands.rumble]` placeholder types parsed | `strong` and `weak` correctly typed as u8 |

---

## Layer 1: Mock Integration Tests

### T5 — MockDeviceIO Behavior

| Test | What | Pass Condition |
|------|------|---------------|
| mock-read-frames | Create MockDeviceIO with 3 pre-recorded frames; call read() 4 times | First 3 calls return frames; 4th returns `ReadError.Again` |
| mock-write-log | Call write() with known bytes | Bytes appear in `write_log` |
| mock-pollfd | Write 1 byte to control pipe; ppoll on MockDeviceIO.pollfd() | ppoll returns POLLIN ready |

### T6 — libusb Error Handling

| Test | What | Pass Condition |
|------|------|---------------|
| usbraw-claim-busy | Mock libusb returning EBUSY on claim_interface | `error.Busy` returned |

### T8 — UinputDevice + MockOutput

| Test | What | Pass Condition |
|------|------|---------------|
| uinput-emit-no-dup | Call emit() twice with identical GamepadState | MockOutput receives event sequence only once (first call) |
| uinput-emit-changed | Call emit() with changed left_x value | MockOutput receives EV_ABS + ABS_X event |
| uinput-create-eperm | Mock UI_DEV_CREATE returning EPERM | `error.PermissionDenied` |
| aux-capability-infer | MappingConfig with `M1 → KEY_F13` | AuxDevice capability set includes KEY_F13 |
| aux-no-create-empty | MappingConfig with no key/mouse_button remap targets | AuxDevice not created |

### T9a — Event Loop

| Test | What | Pass Condition |
|------|------|---------------|
| event-loop-dispatch | ppoll over mock fd set; write to one fd | Correct fd identified and dispatched |
| event-loop-signalfd | Send SIGTERM via signalfd | runEventLoop returns without error |
| event-loop-timerfd-slot | Increase nfds by 1 (activate timer slot) | ppoll does not crash |

### T9b — CLI + Handshake

| Test | What | Pass Condition |
|------|------|---------------|
| validate-valid | `--validate` with well-formed config | Exits 0 |
| validate-invalid | `--validate` with malformed config | Exits 1; error printed |
| handshake-ok | MockDeviceIO returns response_prefix bytes after each command | `runInitSequence` completes without error; write_log contains all 4 commands |
| handshake-retry | MockDeviceIO returns non-matching bytes for first 3 reads, then correct | `runInitSequence` succeeds after retries |
| handshake-fail | MockDeviceIO never returns response_prefix | `error.InitFailed` after max retries |
| reconnect-retry | open() fails; verify 3 retries with correct backoff intervals | 3 attempts made; exits with error after exhausting retries |

### T9c — Full Pipeline

| Test | What | Pass Condition |
|------|------|---------------|
| pipeline-if1-sample | Inject known IF1 32-byte bytes via MockDeviceIO | MockOutput receives GamepadState with correct joystick and button values |
| pipeline-unknown-report | Inject bytes matching no report rule | `OutputDevice.emit` not called |
| pipeline-checksum-fail | Inject IF1 bytes with bad checksum | `OutputDevice.emit` not called |
| pipeline-sigterm | Trigger signalfd SIGTERM | Event loop exits; all fds closed without leak |

### T11 — Integration E2E (L1 path)

| Test | What | Pass Condition |
|------|------|---------------|
| e2e-if1-full | Inject IF1 sample via MockDeviceIO through full stack | MockOutput.gamepad_states contains expected final GamepadState |
| e2e-if0-buttons | Inject IF0 standard 20-byte report | Button bitfield decoded correctly in MockOutput |
| e2e-checksum-drop | IF1 sample with bad CRC | emit not called |

### T12 — Button Remap

| Test | What | Pass Condition |
|------|------|---------------|
| remap-m1-key | MappingConfig: `M1 → KEY_F13`; inject M1 press | MockAuxDevice receives `AuxEvent.key{KEY_F13, pressed=true}` |
| remap-m1-release | MappingConfig: `M1 → KEY_F13`; inject M1 release | MockAuxDevice receives `AuxEvent.key{KEY_F13, pressed=false}` |
| remap-disabled | MappingConfig: `M2 = "disabled"`; inject M2 press | Neither MockOutput nor MockAuxDevice receives M2 event |
| remap-passthrough | Button not in remap config; inject press | MockOutput receives button event unchanged |
| remap-no-main-output | `M1 → KEY_F13`; inject M1 press | MockOutput does NOT receive M1 gamepad button event |

---

## Layer 2: E2E / Manual Tests

### UHID Path (`zig build test-e2e`)

| Test | What | Condition |
|------|------|-----------|
| uhid-discover | UHID creates virtual Vader 5 (VID/PID, phys with "input1"); padctl discover() locates it | Requires `/dev/uhid` |
| uhid-open | padctl open() succeeds on UHID device | Requires `/dev/uhid` |
| uhid-read | Inject pre-recorded IF1 frames via UHID; evdev reader sees uinput events | Requires `/dev/uhid` |

### Manual Verification (pre-release)

| Check | Tool | Expected |
|-------|------|---------|
| Virtual gamepad visible | `jstest --normal /dev/input/jsN` | Axes and buttons listed |
| Events produced | `evtest /dev/input/eventN` | EV_ABS and EV_KEY events on physical input |
| VID/PID match | `evtest` or `udevadm` | Matches `[output]` declaration |
| Vader 5 IF0 claim | Connect real device; inspect logs | `libusb_claim_interface` succeeds on IF0 |
| Vader 5 hidraw discovery | Connect real device; inspect logs | Correct `/dev/hidrawN` found for IF1 |
| Handshake completes | Connect real device; inspect logs | All 4 init commands acknowledged |
| Clean exit | `kill -SIGTERM $(pidof padctl)` | No fd leak; process exits 0 |

---

## Mapping to Success Criteria

| Brief SC# | Test Coverage |
|-----------|--------------|
| SC1 (zig build) | CI workflow (T1) |
| SC2 (CI passes) | GitHub Actions (T1) |
| SC3 (flydigi-vader5.toml loads) | vader5-config-load, vader5-config-fields, vader5-commands |
| SC4 (processReport IF1) | interp-vader5-if1, interp-button-bitfield |
| SC5 (handshake via mock) | handshake-ok, handshake-retry, handshake-fail |
| SC6 (ppoll + signalfd clean exit) | event-loop-signalfd, pipeline-sigterm |
| SC7 (config-driven output, no hardcoding) | uinput-create-eperm, abs-code-known (code comes from config) |
| SC8 (conditional fields via multi-report) | pipeline-if1-sample, e2e-if0-buttons |
| SC9 (commands template) | device-config-commands-template, vader5-commands |
| SC10 (M1 → KEY_F13) | remap-m1-key, remap-m1-release, remap-no-main-output |
| SC11 (zig build test all pass) | All L0+L1 tests |
| SC12 (hidraw discover) | uhid-discover [L2 manual] |
| SC13 (usbraw claim IF0) | Vader 5 IF0 claim [manual] |
| SC14 (evtest recognizes device) | Virtual gamepad visible [manual] |
| SC15 (button mapping) | Events produced [manual] |

# Design: Phase 7 — Fuzzing, Concurrency Tests, Doc Sync, Device Completion

## Files

| File | Role |
|------|------|
| `src/core/interpreter.zig` | Add fuzz test block for `processReport` |
| `src/config/device.zig` | Add fuzz test block for `loadFromBytes` |
| `src/io/usbraw.zig` | Add concurrent push/pop test for `RingBuffer` |
| `src/test/mock_output.zig` | Extend `MockOutput` with `EmitDiff` recording |
| `src/test/phase7_e2e_test.zig` | Rewrite integration assertions using diff interface |
| `docs/src/engineering/mapper.md` | Remove Phase-placeholder comments |
| `docs/src/engineering/output.md` | Remove Phase-placeholder comments |
| `docs/src/engineering/wasm.md` | Remove Phase-placeholder comments |
| `docs/src/architecture.md` | Full rewrite: CLI modules, directory tree, 10-device table |
| `docs/src/engineering/index.md` | Add Phase 5.1 and Phase 6 spec file references |
| `CONTRIBUTING.md` | Add vendor directory and device TOML contribution guidance |
| `devices/sony/dualsense.toml` | Add BT input report (id=0x31) |
| `devices/microsoft/xbox-elite.toml` | Split Paddle buttons into independent P1–P4 entries |
| `devices/hori/horipad-steam.toml` | Correct M3 button bit offsets |
| `devices/valve/steam-deck.toml` | Declare touchpad axes (left_pad / right_pad) |

## Architecture

### Wave 1 — Test hardening (T4–T7)

**T4: interpreter fuzzing**

`std.testing.fuzz` drives `Interpreter.processReport` with arbitrary byte slices. The test
initialises a real `Interpreter` with a known device config (vader5), then calls `processReport`
for every fuzz iteration. Any panic or safety-check trap is a failure; returning an error or null
is acceptable.

Edge cases exercised by the fuzzer corpus seed:
- payload shorter than `match.offset + match.expect.len`
- checksum field where `offset + size > raw.len`
- extreme `offset` values in every field type

`build.zig` gains a `test-fuzz` step that runs fuzz tests with `-Dfuzz-iterations=10000`.

**T5: config parsing fuzzing**

`std.testing.fuzz` drives `DeviceConfig.loadFromBytes` with arbitrary byte slices. Malformed or
non-UTF-8 input must return an error, never panic. Corpus seeds: empty input, NUL bytes, deeply
nested TOML tables, unclosed strings.

**T6: RingBuffer concurrency**

```
producer thread → RingBuffer.push × 1000
consumer thread → RingBuffer.pop until empty
join both threads
assert: push_count >= pop_count (overflow-drop is allowed)
assert: each successfully popped frame is byte-identical to the pushed frame
```

Run with `-Dsan=thread` (ThreadSanitizer) in CI to detect data races. The test lives directly in
`src/io/usbraw.zig` alongside the existing single-threaded tests.

**T7: EmitDiff interface for MockOutput**

```zig
pub const EmitDiff = struct {
    changed_axes:    []const struct { code: u16, value: i32 },
    changed_buttons: []const struct { code: u16, pressed: bool },
    rel_events:      []const struct { code: u16, value: i32 },
};
```

`MockOutput` maintains a `prev_state: GamepadState` and on each `emit()` call computes the diff
before storing it. Tests obtain the diff slice via `mockOutput.emitDiffs()`. Existing integration
tests in `src/test/phase*_e2e_test.zig` are updated where needed so they assert only the changed
fields; unrelated field additions no longer break them.

### Wave 2 — Doc sync (T8–T10)

**T8: Phase-marker cleanup**

Scan `docs/src/engineering/mapper.md`, `output.md`, `wasm.md` for:
- `# Phase N 预留` section headers / inline comments
- `TODO: Phase N` annotations whose phase is already shipped
- `defer to Phase N` notes for already-implemented features

Remove matched lines. Preserve substantive design notes and architecture rationale.

**T9: architecture.md full rewrite**

Update `docs/src/architecture.md` to cover:

| Section | Content |
|---------|---------|
| CLI module table | install / scan / reload / config (init, list, edit, test) / validate / doc-gen |
| Directory tree | `src/cli/`, `contrib/aur/`, `contrib/copr/`, `devices/<vendor>/` sub-layout |
| Device table | All 10 devices with VID/PID and report format note |
| Data-flow diagram | XDG three-layer path resolution → interpreter → uinput; `padctl install` flow |

**T10: engineering/index.md + CONTRIBUTING.md**

`docs/src/engineering/index.md`: add rows for every spec file added in Phase 5.1 and Phase 6.

`CONTRIBUTING.md` additions:
- Vendor directory table (zig-toml, wasm3: upstream URL + update procedure)
- New device TOML guide pointer (`docs/src/contributing/device-toml-from-inputplumber.md`)
- `padctl --validate` requirement for all new device TOMLs

### Wave 3 — Device completion (T11–T13)

**T11: DualSense BT report**

DualSense BT uses report_id `0x31` with a 78-byte payload. Compared to the USB report (id=0x01,
64B) all field offsets shift by +2 to account for a 2-byte BT protocol header. CRC32 seed is
`0xa1`; the interpreter's checksum logic already supports this via the `crc_seed` field.

New section in `devices/sony/dualsense.toml`:

```toml
[[input_report]]
id = 0x31
length = 78
crc_seed = 0xa1      # BT extended report: last 4 bytes are CRC32
# sticks / triggers / buttons: USB offsets + 2
```

Field layout (offsets relative to report start, after id byte):

| Field | USB offset | BT offset |
|-------|-----------|-----------|
| LX | 1 | 3 |
| LY | 2 | 4 |
| RX | 3 | 5 |
| RY | 4 | 6 |
| LT | 5 | 7 |
| RT | 6 | 8 |
| Buttons (3B) | 8–10 | 10–12 |

**T12: Xbox Elite Paddle split**

The Xbox Elite report exposes four Paddle buttons as individual bits. Current TOML groups them
under a single `button_group` entry. The fix creates four independent entries:

```toml
[[button]]
name = "P1"
byte = <paddle_byte>
bit  = 0   # exact bit positions from Elite HID descriptor

[[button]]
name = "P2"
# ...
```

`[output]` maps P1–P4 to `BTN_TRIGGER_HAPPY1`–`BTN_TRIGGER_HAPPY4` (or configurable via
mapping TOML).

**T13: Horipad M3 fix + Steam Deck touchpad**

*Horipad M3*: The M3 button group currently uses incorrect bit offsets. Correct values sourced
from the InputPlumber Rust descriptor. Patch the `bit` fields for the four M-buttons.

*Steam Deck touchpad*: Declare left and right pad axes as `type = "touch_pad"` entries. Each pad
has `x: i16le`, `y: i16le`, and a `touched` bit. Force sensor and capacitive zones are not
expressible in the current DSL and are deferred to Phase 8 with inline `# deferred: Phase 8`
comments.

## Key Design Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | EmitDiff stored alongside full state in MockOutput | Diff is cheap to compute at emit time; tests that need full state still have it |
| D2 | Fuzz tests in same file as production code | Zig convention; avoids separate test-only build targets for most cases |
| D3 | `test-fuzz` step separate from `zig build test` | Fuzz runs are deterministic-corpus in CI (fast); libFuzzer/AFL modes remain opt-in |
| D4 | TSan via `-Dsan=thread` in concurrency test CI step | Compiler-level race detection; no runtime overhead outside that step |
| D5 | BT report in same TOML file as USB report | One device file per physical device; report_id discriminates at runtime |
| D6 | Paddle buttons as independent `[[button]]` entries | Enables per-paddle remapping in user mapping TOML; no functional change to other buttons |
| D7 | Steam Deck touchpad declared but force/zone deferred | DSL coverage is honest about limits; deferred items are marked inline |

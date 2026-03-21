# Phase 7: Test Plan — Fuzzing, Concurrency Tests, Doc Sync, Device Completion

Each test maps to a success criterion in `brief.md`.

## Unit Tests

- [ ] TP1: `zig build test-fuzz` (T4) — `processReport` fuzz runs 10,000 iterations with corpus
  seeds (empty, short, checksum OOB, extreme offsets); zero panics or safety-check traps.
  validates: T4 success criterion

- [ ] TP2: `zig build test-fuzz` (T5) — `DeviceConfig.loadFromBytes` fuzz runs 10,000 iterations
  with corpus seeds (empty, NUL bytes, deeply nested TOML, unclosed string); returns error on
  every malformed input; zero panics.
  validates: T5 success criterion

- [ ] TP3: `zig build test -Dsan=thread` (T6) — RingBuffer concurrent push/pop test completes
  with `push_count >= pop_count`; ThreadSanitizer reports no data races.
  validates: T6 success criterion

- [ ] TP4: `MockOutput.emitDiffs()` (T7) — after two `emit()` calls that change only `LX` axis,
  `diffs[1].changed_axes` contains exactly one entry with code=`ABS_X`; unchanged buttons and
  rel events are absent from the diff.
  validates: T7 EmitDiff correctness

- [ ] TP5: `MockOutput.emitDiffs()` (T7) — adding a new unrelated axis field to `GamepadState`
  does not cause any existing test assertion to fail (regression guard for diff isolation).
  validates: T7 robustness goal

- [ ] TP6: DualSense BT parse (T11) — synthesize a 78-byte buffer with id=0x31, known LX/RY
  values at BT offsets (3/6), valid CRC32 appended; `processReport` returns correct axis values.
  validates: T11 field-offset correctness

- [ ] TP7: DualSense BT parse (T11) — same buffer with a corrupted CRC32; `processReport` returns
  `error.ChecksumMismatch` or equivalent; no panic.
  validates: T11 checksum enforcement

- [ ] TP8: Xbox Elite Paddle (T12) — parse a report byte with only P1 bit set; verify P1=pressed,
  P2–P4=released. Repeat for each individual paddle.
  validates: T12 independent-bit correctness

- [ ] TP9: Xbox Elite Paddle (T12) — parse a report byte with all four Paddle bits set; verify
  P1=P2=P3=P4=pressed and no other button state affected.
  validates: T12 no cross-contamination

- [ ] TP10: Horipad M3 fix (T13) — parse a report byte with corrected M-button bit positions;
  verify each M-button pressed state is correct under new offsets.
  validates: T13 M3 fix

## Integration Tests

- [ ] TP11: `zig build test` (T7) — all existing `phase*_e2e_test.zig` integration tests pass
  under the new EmitDiff interface without modification to test intent.
  validates: T7 backward compatibility

- [ ] TP12: `grep -r "Phase [0-9] 予留" docs/src/engineering/` (T8) — empty result.
  validates: T8 success criterion

- [ ] TP13: `grep -r "TODO: Phase" docs/src/engineering/` (T8) — empty result.
  validates: T8 success criterion

- [ ] TP14: `padctl --validate devices/sony/dualsense.toml` (T11) — exits 0 with both USB
  (id=0x01) and BT (id=0x31) reports present.
  validates: T11 success criterion

- [ ] TP15: `padctl --validate devices/microsoft/xbox-elite.toml` (T12) — exits 0 with P1–P4
  paddle entries declared.
  validates: T12 success criterion

- [ ] TP16: `padctl --validate devices/hori/horipad-steam.toml` (T13) — exits 0 after M3 button
  offset correction.
  validates: T13 Horipad success criterion

- [ ] TP17: `padctl --validate devices/valve/steam-deck.toml` (T13) — exits 0 with left_pad and
  right_pad touchpad entries declared.
  validates: T13 Steam Deck success criterion

- [ ] TP18: `padctl --validate devices/**/*.toml` (T14) — all 10 device TOML files exit 0.
  validates: T14 success criterion

- [ ] TP19: CI three jobs (`lint`, `test`, `cross-compile`) all green on `feat/phase-7` branch
  (T14).
  validates: T14 CI success criterion

- [ ] TP20: `architecture.md` directory tree cross-checked against `ls` of code-repo `src/cli/`,
  `contrib/aur/`, `contrib/copr/`, `devices/` — no phantom or missing entries (T9).
  validates: T9 success criterion

- [ ] TP21: `docs/src/engineering/index.md` contains rows for all spec files from Phase 5.1 and
  Phase 6 (T10); `CONTRIBUTING.md` contains vendor table and device TOML section (T10).
  validates: T10 success criterion

## Manual Tests (hardware required, CI skipped)

- [ ] TP22: DualSense connected via Bluetooth — `padctl scan` identifies device via BT interface;
  daemon processes BT reports without error or dropped frames.
  validates: T11 end-to-end

- [ ] TP23: Xbox Elite connected — all four Paddle buttons produce independent `BTN_TRIGGER_HAPPY*`
  events in `evtest` output; no cross-firing between paddles.
  validates: T12 end-to-end

- [ ] TP24: Horipad Steam connected — M-buttons produce correct key events; no phantom presses
  compared to pre-fix behaviour.
  validates: T13 Horipad end-to-end

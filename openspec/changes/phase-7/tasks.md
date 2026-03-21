# Tasks: Phase 7 — Fuzzing, Concurrency Tests, Doc Sync, Device Completion

Branch: `feat/phase-7`
Commit: (leave blank — filled after implementation)

## Execution plan

Wave 0 (T1–T3) already complete. Wave 1 (T4–T7) parallel; Wave 2 (T8–T10) parallel; Wave 3
(T11–T13) parallel; all three waves run concurrently after Wave 0. Wave 4 (T14) after Waves
1–3.

---

## Wave 1 — Test hardening

### T4: Interpreter fuzzing

- [ ] In `src/core/interpreter.zig`, add:
  ```zig
  test "fuzz processReport" {
      const input = std.testing.fuzzInput(.{});
      var interp = try Interpreter.init(testing.allocator, vader5_config);
      defer interp.deinit();
      _ = interp.processReport(0, input) catch {};
  }
  ```
- [ ] Add corpus seed files: empty slice, 1-byte slice, slice shorter than minimum report length
- [ ] Add `test-fuzz` step to `build.zig` running with `-Dfuzz-iterations=10000`
- [ ] Confirm no panic across: short payload, checksum offset OOB, extreme field offsets

### T5: Config parsing fuzzing

- [ ] In `src/config/device.zig`, add:
  ```zig
  test "fuzz parseString" {
      const input = std.testing.fuzzInput(.{});
      _ = DeviceConfig.loadFromBytes(testing.allocator, input) catch {};
  }
  ```
- [ ] Corpus seeds: empty slice, NUL bytes, `[[[` (deeply nested), unclosed string `key = "abc`
- [ ] Verify returns `error.InvalidConfig` or TOML parse error on all corpus seeds; no panic

### T6: RingBuffer concurrency

- [ ] In `src/io/usbraw.zig`, add `test "RingBuffer concurrent push/pop"`:
  - Spawn producer thread: call `RingBuffer.push` 1000 times with distinct payloads
  - Spawn consumer thread: call `RingBuffer.pop` in a loop until join signal; collect results
  - `producer.join()` then `consumer.join()`
  - Assert `push_count >= pop_count` (overflow-drop permitted)
  - Assert each popped frame is byte-identical to the corresponding pushed frame
- [ ] Add CI step: `zig build test -Dsan=thread` (ThreadSanitizer pass)

### T7: MockOutput EmitDiff

- [ ] In `src/test/mock_output.zig`:
  - Add `EmitDiff` struct with `changed_axes`, `changed_buttons`, `rel_events` slices
  - Add `prev_state: GamepadState` field to `MockOutput`
  - Compute diff in `emit()` before updating `prev_state`; append to `diffs` ArrayList
  - Expose `emitDiffs() []EmitDiff` accessor
- [ ] Update `src/test/phase*_e2e_test.zig` assertion sites to use `emitDiffs()` where only
  changed fields matter; retain full-state assertions only where semantically required
- [ ] Run `zig build test` — all existing integration tests pass under new interface

---

## Wave 2 — Doc sync

### T8: Phase-marker cleanup

- [ ] In `docs/src/engineering/mapper.md`: remove all `# Phase N 预留`, `TODO: Phase N`,
  `defer to Phase N` lines/comments for phases already shipped (Phase 1–6)
- [ ] In `docs/src/engineering/output.md`: same cleanup
- [ ] In `docs/src/engineering/wasm.md`: same cleanup
- [ ] Verify: `grep -r "Phase [0-9] 预留" docs/src/engineering/` → empty
- [ ] Verify: `grep -r "TODO: Phase" docs/src/engineering/` → empty

### T9: architecture.md full rewrite

- [ ] Rewrite `docs/src/architecture.md`:
  - CLI module table: install / scan / reload / config (init, list, edit, test) / validate / doc-gen
  - Directory tree: update `src/cli/`, `contrib/aur/`, `contrib/copr/`, `devices/<vendor>/` layout
  - Device table: all 10 devices with VID/PID columns (Vader 5 Pro, DualSense, Switch Pro,
    8BitDo Ultimate, Xbox Elite, Legion Go, Steam Deck, Horipad Steam, Vader 4 Pro, Xbox xpad_uhid)
  - Data-flow diagram: XDG three-layer resolution → interpreter → uinput output
- [ ] Cross-check directory tree against `ls` of code-repo; no phantom entries

### T10: engineering/index.md + CONTRIBUTING.md

- [ ] In `docs/src/engineering/index.md`: add table rows for all spec files added in Phase 5.1
  and Phase 6 (paths + one-line function summaries)
- [ ] In `CONTRIBUTING.md`:
  - Add vendor directory table (zig-toml, wasm3): upstream URL, current commit, update command
  - Add "New device TOML" section pointing to `docs/src/contributing/device-toml-from-inputplumber.md`
  - Document `padctl --validate <file>` as required before submitting a device TOML PR

---

## Wave 3 — Device completion

### T11: DualSense BT report

- [ ] In `devices/sony/dualsense.toml`, add `[[input_report]]` section for id=0x31 (length=78,
  crc_seed=0xa1)
- [ ] Set field offsets to USB values + 2 for all axes and buttons
  - LX=3, LY=4, RX=5, RY=6, LT=7, RT=8, button bytes 10–12
- [ ] Run `padctl --validate devices/sony/dualsense.toml` — exits 0
- [ ] Add L0 unit test: parse a synthetic 78-byte BT report; verify LX/RX/button fields decoded
  correctly

### T12: Xbox Elite Paddle split

- [ ] In `devices/microsoft/xbox-elite.toml`, replace bundled Paddle group with four independent
  `[[button]]` entries named P1, P2, P3, P4 using correct bit positions from Elite HID descriptor
- [ ] Map P1→`BTN_TRIGGER_HAPPY1`, P2→`BTN_TRIGGER_HAPPY2`, P3→`BTN_TRIGGER_HAPPY3`,
  P4→`BTN_TRIGGER_HAPPY4` in `[output]`
- [ ] Run `padctl --validate devices/microsoft/xbox-elite.toml` — exits 0
- [ ] Add L0 unit test: parse a report byte with various Paddle bit combinations; verify each Pn
  maps to correct pressed state

### T13: Horipad M3 fix + Steam Deck touchpad

- [ ] In `devices/hori/horipad-steam.toml`: patch `bit` fields for the four M-buttons to correct
  values sourced from InputPlumber Rust descriptor
- [ ] Run `padctl --validate devices/hori/horipad-steam.toml` — exits 0
- [ ] Add L0 unit test: parse report byte with corrected M-button positions; verify pressed states
- [ ] In `devices/valve/steam-deck.toml`: declare `left_pad` and `right_pad` touch_pad entries
  (x: i16le, y: i16le, touched: bool bit); add `# deferred: Phase 8` comments on force/zone fields
- [ ] Run `padctl --validate devices/valve/steam-deck.toml` — exits 0

---

## Wave 4 — Regression + review

### T14: Full regression + code review

- [ ] `zig build test` — full suite green (including Wave 1–3 new tests)
- [ ] `zig build test-fuzz` — 10k iterations, no panic (T4/T5)
- [ ] `zig build test -Dsan=thread` — TSan clean (T6)
- [ ] `padctl --validate devices/**/*.toml` — all 10 device files exit 0
- [ ] CI three jobs (`lint`, `test`, `cross-compile`) all green
- [ ] Reviewer (Opus model) reviews Wave 1–3 diffs; no BLOCKING findings

---

## Post-merge wrap-up

- [ ] Archive this OpenSpec
- [ ] Update `planning/roadmap.md` Phase 7 status

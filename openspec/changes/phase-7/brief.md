# Brief: Phase 7 — Fuzzing, Concurrency Tests, Doc Sync, Device Completion

## Why

Phase 6 left padctl feature-complete for v1.0 release candidates but several quality gaps
remain: the interpreter and config parser have never been fuzz-tested, the RingBuffer has no
multi-threaded verification, E2E tests assert full state snapshots that break on unrelated field
changes, documentation still contains Phase 1 placeholder comments, and three devices are
missing or incomplete (DualSense BT mode, Xbox Elite Paddle buttons, Horipad M3 button offsets
and Steam Deck touchpad declaration). Phase 7 closes all these gaps without adding new features.

## Problem Scope

- `processReport` and `DeviceConfig.loadFromBytes` have zero fuzzing coverage; malformed input
  could trigger panics or UB in production
- `RingBuffer` (in `src/io/usbraw.zig`) has only single-threaded tests; concurrent push/pop
  correctness is unverified
- E2E MockOutput tests perform full-state snapshot assertions; any new output field addition
  breaks unrelated tests
- `engineering/mapper.md`, `engineering/output.md`, `engineering/wasm.md` contain "Phase 1
  预留" placeholder comments and `TODO: Phase N` inline items that were completed in earlier phases
- `design/architecture.md` predates the CLI modules added in Phase 6 and does not list the
  current 10-device library or updated directory structure
- `engineering/index.md` does not reference Phase 5.1 and Phase 6 spec files; `CONTRIBUTING.md`
  lacks vendor directory guidance
- `devices/sony/dualsense.toml` only covers USB HID report; DualSense BT (report_id=0x31) is
  not supported
- `devices/microsoft/xbox-elite.toml` bundles all four Paddle buttons without independent bit
  mappings
- `devices/hori/horipad-steam.toml` has incorrect M3 button bit offsets;
  `devices/valve/steam-deck.toml` does not declare the touchpad axes

## Out of Scope

- inotify config hot-reload (Phase 8)
- DualShock 4 device TOML (Phase 8 — insufficient protocol data)
- Switch Pro BT mode (Phase 8 — protocol not fully reversed)
- Steam Deck touchpad force sensor (Phase 8 — not DSL-expressible)
- nixpkgs upstream submission (Future, post-v1.0)

## References

- Phase plan: `planning/phase-7.md`
- Prior openspec: `openspec/changes/phase-6/`
- Research: `research/调研-padctl技术选型与DSL设计.md` §DualSense BT protocol
- Research: `research/调研-Phase4-生态与扩展.md` §Xbox Elite protocol
- Engineering specs: `engineering/mapper.md`, `engineering/output.md`, `engineering/wasm.md`

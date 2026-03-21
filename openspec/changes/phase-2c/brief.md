# Phase 2c Brief: Multi-device Supervisor, MacroPlayer, Auto-discover, Hot-reload

## What

Extend padctl from single-device to multi-device operation with a macro system and zero-downtime config reload:

1. **DeviceInstance encapsulation** — extract the per-device runtime (EventLoop + Interpreter + Mapper + Output) into a self-contained `DeviceInstance` struct; each instance runs in its own OS thread.
2. **Supervisor** — main-thread manager that spawns/joins DeviceInstance threads, handles signals via signalfd, and drives exponential-backoff reconnection on device disconnect.
3. **Macro system** — `[[macro]]` TOML blocks define step sequences (`tap/down/up/delay/pause_for_release`); `macro:name` remap target; `MacroPlayer` timerfd state machine executes steps without blocking the EventLoop.
4. **Auto-discover** — `--config-dir` loads all `*.toml` files and matches each by VID/PID to live `/dev/hidraw*` nodes; physical path (`HIDIOCGRAWPHYS`) disambiguates same-model duplicates.
5. **SIGHUP hot-reload** — Supervisor re-scans config on SIGHUP; new configs spawn new instances, removed configs stop them, changed mappings are applied via atomic pointer swap with no DeviceInstance restart.

## Why

Phase 2b delivered full single-device feature parity with Vader 5. Phase 2c unlocks the real-world use case: multiple controllers simultaneously (e.g., Vader 5 + DualSense), macro sequences for complex in-game actions, and live config editing without restarting the daemon. The multi-thread architecture reuses the existing EventLoop unchanged — each device gets a fully isolated runtime with its own state.

## Scope

| Area | Files |
|------|-------|
| Per-device runtime encapsulation | `src/device_instance.zig` (new), `src/main.zig` (refactor) |
| Macro config + types | `src/core/macro.zig` (new), `src/config/mapping.zig` (extend) |
| Supervisor thread management | `src/supervisor.zig` (new), `src/main.zig` (refactor) |
| MacroPlayer + TimerQueue | `src/core/macro_player.zig` (new), `src/core/timer_queue.zig` (new), `src/core/mapper.zig` (integrate) |
| Auto-discover | `src/io/hidraw.zig` (extend), `src/main.zig` (extend) |
| SIGHUP hot-reload | `src/supervisor.zig` (extend), `src/device_instance.zig` (extend) |
| Integration tests | `src/test/phase2c_e2e_test.zig` (new) |

## Out of Scope

- netlink uevent hot-plug (udev add/remove auto-respawn) — Phase 3
- inotify automatic config-change detection — Phase 3
- `gyro.activate` toggle semantics — Phase 3
- `fillTemplate` u16le/u16be types — Phase 3
- Cross-device macro triggers (device A fires action on device B) — Phase 4

## Success Criteria

- Two devices run simultaneously: independent threads, independent uinput outputs, no interference (L1)
- `[[macro]]` TOML parsed: all five primitives (`tap/down/up/delay/pause_for_release`) correct (L0)
- Macro playback end-to-end: trigger → delay via timerfd → subsequent steps execute, EventLoop not blocked (L1)
- `pause_for_release`: macro pauses while trigger is held, resumes on trigger release (L0)
- Layer switch immediately cancels all active macros, no residual key-down events (L0)
- SIGHUP hot-reload: mapping atomic swap, DeviceInstance not restarted, effective within one ppoll cycle (L1)
- `--config-dir` loads all `*.toml`, matches by VID/PID (L1)
- Same-model multi-device (same VID/PID, different physical path) → two independent instances (L1)
- `zig build test` (L0 + L1) all pass, CI-runnable

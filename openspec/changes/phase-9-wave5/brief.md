# Brief: Phase 9 Wave 5 — inotify Hot-Reload + Battery Extraction (T17/T19a)

## Why

Two independent system-integration features that close Phase 9:

1. **T17 — inotify config hot-reload**: Currently config reload requires manually sending
   SIGHUP to the daemon (`kill -HUP <pid>`). This is unfriendly and error-prone. Linux
   inotify watches `~/.config/padctl/` for file changes and triggers reload automatically.
   inotify is a kernel syscall — zero external dependencies (P5 compliant). A 500ms timerfd
   debounce coalesces rapid saves (editor write-rename patterns, multiple file edits).

2. **T19a — battery level extraction**: DualSense already declares `battery_raw` at offset 53
   in `dualsense.toml`, but the interpreter maps it to `FieldTag.unknown` — the value is
   parsed then silently discarded. This task adds `battery_level` to `GamepadState` /
   `GamepadStateDelta` and a `battery_level` FieldTag so the interpreter writes the extracted
   value into state. Pure field extraction via existing DSL — no UPower, no DBus (T19b deleted).

## Scope

| Task | Description | Dependencies |
|------|-------------|-------------|
| T17 | inotify on `~/.config/padctl/`, timerfd 500ms debounce, replaces SIGHUP trigger | Phase 8 complete |
| T19a | Add `battery_level` field to GamepadState, map `battery_level` TOML field name | Phase 8 complete |

## Success Criteria

- inotify fd added to Supervisor ppoll loop alongside existing stop/hup/netlink fds
- IN_CLOSE_WRITE and IN_MOVED_TO events on config dir trigger reload after 500ms debounce
- Multiple rapid file changes produce exactly one reload call
- SIGHUP path remains functional (backward compatible)
- `battery_level` field in GamepadState populated from HID report
- DualSense TOML uses `battery_level` field name with appropriate transform
- `zig build test` passes all new + existing tests (Layer 0+1, zero privileges)

## Out of Scope

- UPower/DBus battery exposure (T19b deleted — VIOLATION P5)
- Battery charging state extraction (future: separate `battery_charging` bool field)
- Recursive subdirectory watching (only the config dir itself)
- Watching device TOML dirs (`devices/`) — only user mapping config dir
- inotify on individual files (watch the directory, not specific filenames)

## References

- Phase plan: `planning/phase-9.md` (docs-repo, Wave 5, T17/T19a)
- Design principles: `design/principles.md` (P5 single binary, P9 testable)
- Supervisor: `src/supervisor.zig` (SIGHUP reload via signalfd + ppoll)
- GamepadState: `src/core/state.zig` (current fields, no battery_level)
- Interpreter field tags: `src/core/interpreter.zig` (FieldTag enum, parseFieldTag, applyFieldTag)
- DualSense TOML: `devices/sony/dualsense.toml` (battery_raw at offset 53)

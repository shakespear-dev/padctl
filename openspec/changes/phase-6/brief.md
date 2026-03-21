# Brief: Phase 6 — Install CLI, XDG Paths, InputPlumber Devices, COPR, Config UX

## Why

padctl currently requires users to manually copy four files and run three separate commands to
install. There is no XDG-aware config discovery, no structured CLI for managing configs, and
only two device TOML files exist (Steam Deck, Legion Go). Phase 6 completes these gaps so padctl
is a credible v1.0 release candidate: installable, discoverable, configurable, and packaged for
Fedora/Bazzite users.

## Problem Scope

- `install/README.md` documents a four-step manual install with no automation path
- `padctl` requires `--config` or `--config-dir` explicitly; bare invocation fails to discover
  user configs in `~/.config/padctl/`
- No `padctl scan`, `padctl reload`, or `padctl config` subcommands exist
- Device library covers only two devices; Legion Go S, Horipad Steam, Vader 4 Pro, and Xbox
  xpad_uhid are unrepresented despite having complete InputPlumber protocol data available
- Release artifacts lack SHA256SUMS.txt and changelog; AUR is updated manually
- No Fedora RPM packaging; Bazzite/Legion Go users on Fedora have no supported install path
- Gyro curve applies exponent directly to raw absolute values (differs from vader5 algorithm)
- Horizontal scroll (`REL_HWHEEL`) is not emitted; only vertical scroll works
- CI only builds native; no cross-compile verification; Zig version differs between workflows

## Out of Scope

- inotify config hot-reload (Phase 7)
- Xbox Elite emulation / `emulate_elite` (Phase 7)
- `EVIOCGRAB` exclusive input (Phase 7)
- SteamDeck sysext packaging (Phase 7)
- DualShock 4 / Switch Pro device TOML (Phase 7 — insufficient InputPlumber data)
- DBus interface (Future)
- nixpkgs upstream submission (Future, post-v1.0)

## References

- Phase plan: `planning/phase-6.md`
- Research: `research/调研-安装与配置管理.md`
- Research: `research/调研-多平台构建与分发.md`
- Research: `research/调研-InputPlumber协议数据复用.md`
- Research: `research/调研-vader5-padctl-InputPlumber功能对比.md`
- ADR-006, ADR-007, ADR-008 (at code-repo@96134b7)

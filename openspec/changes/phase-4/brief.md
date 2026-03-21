# Phase 4 Brief: Community Configs, Docs Site, WASM Plugin, Packaging

## What

Deliver four capabilities that together make padctl community-extensible and distributable without compilation:

1. **Community device configs + `padctl --validate`** — four new device TOMLs (DualSense, Switch Pro, 8BitDo Ultimate, Xbox Elite) plus a static validator CLI backed by CI, enabling community contribution without real hardware.
2. **mdbook docs site + `padctl --doc-gen`** — documentation site auto-generated from device TOML, deployed to GitHub Pages. Device reference pages (field tables, button maps, command templates) generated automatically.
3. **WASM plugin runtime** — wasm3-backed escape hatch for devices whose protocol cannot be fully expressed in TOML (stateful init handshakes, calibration from Feature Report, custom report processing). Three-hook ABI: `init_device` / `process_calibration` / `process_report`.
4. **Packaging + distribution** — GitHub Release CI producing x86_64 + aarch64 musl static binaries, AUR PKGBUILD (source + prebuilt), Nix flake.

## Why

Phase 3 delivered padctl-capture and system integration. Phase 4 closes the remaining gaps: the DualSense GAPS document identifies three protocol features (BT seq_tag counter, CRC32 output, IMU calibration) that cannot be expressed declaratively — the WASM escape hatch resolves them. Community contribution requires a validator and defined contribution flow. Distribution requires packaging artifacts.

## Scope

| Area | Files |
|------|-------|
| Device configs | `devices/sony/dualsense.toml`, `devices/nintendo/switch-pro.toml`, `devices/8bitdo/ultimate.toml`, `devices/microsoft/xbox-elite.toml`, `devices/flydigi/vader5.toml` (relocated) |
| Validate CLI | `src/tools/validate.zig` (new), `build.zig` (extend), `.github/workflows/validate.yml` (new), `CONTRIBUTING.md` (new) |
| Doc-gen CLI | `src/tools/docgen.zig` (new), `build.zig` (extend) |
| Docs site | `docs/book.toml` (new), `docs/src/SUMMARY.md` (new), `docs/src/getting-started.md` (new), `docs/src/config-reference.md` (new), `docs/src/devices/` (generated), `.github/workflows/docs.yml` (new) |
| WASM runtime | `src/wasm/runtime.zig` (new), `src/wasm/host_functions.zig` (new), `src/wasm/plugin.zig` (new), `build.zig` (extend with wasm3), `sdk/plugin.h` (new) |
| Output DSL emulate | `src/output.zig` (extend), `engineering/output.md` (update) |
| Packaging | `.github/workflows/release.yml` (new), `contrib/aur/PKGBUILD` (new), `contrib/aur/padctl-bin/PKGBUILD` (new), `flake.nix` (new), `flake.lock` (new) |
| Phase 4 tests | `src/test/phase4_test.zig` (new) |

## Out of Scope

- NixOS module (systemd + udev declarative config) — Phase 5
- wasmtime as optional WASM backend — Phase 5 (wasm3 validates feasibility first)
- WASM plugin SDK multi-language examples (Rust/C++) — Phase 5 (C header + Zig reference sufficient)
- inotify automatic config-change detection — Phase 5 (SIGHUP sufficient)
- Copr/PPA (Fedora/Ubuntu) distribution — Phase 5
- Full HID report descriptor parsing — Phase 5 (statistical algorithm takes priority)

## Success Criteria

- `padctl --validate devices/**/*.toml` passes for all four new configs; CI runs automatically (L0)
- DualSense USB report (64 bytes) → `interpreter.processReport()` correctly extracts touchpad contact bytes, gyro/accel, triggers, buttons (L1)
- Switch Pro BT report → all button/axis fields parse correctly (L1)
- `padctl --doc-gen devices/sony/dualsense.toml` → valid Markdown with field table row count matching declared fields (L0)
- `mdbook build` exits 0; GitHub Pages CI deploys successfully (L0)
- wasm3 integration: DualSense `init_device` hook returns 0; timeout sandbox terminates within 5 s (L1)
- WASM linear memory out-of-bounds write → wasm3 trap captured; padctl does not crash (L1)
- `[output] vid/pid` substitution → uinput device created with declared VID/PID (L1)
- `zig build -Dtarget=aarch64-linux-musl` cross-compiles without error (L0)
- GitHub Release CI produces x86_64 + aarch64 binaries; `namcap PKGBUILD` exits 0 (L0)
- `zig build test` (L0 + L1) all pass, CI-runnable

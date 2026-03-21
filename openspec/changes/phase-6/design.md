# Design: Phase 6 — Install CLI, XDG Paths, InputPlumber Devices, COPR, Config UX

## Files

| File | Role |
|------|------|
| `src/cli/install.zig` | `padctl install` subcommand |
| `src/cli/scan.zig` | `padctl scan` subcommand |
| `src/cli/reload.zig` | `padctl reload` subcommand |
| `src/config/paths.zig` | XDG three-layer config discovery |
| `src/cli/config/init.zig` | `padctl config init` subcommand |
| `src/cli/config/list.zig` | `padctl config list` subcommand |
| `src/cli/config/edit.zig` | `padctl config edit` subcommand |
| `src/cli/config/test.zig` | `padctl config test` subcommand |
| `src/main.zig` | Register all new subcommands; XDG fallback for bare invocation |
| `src/stick_processor.zig` | Add `REL_HWHEEL` horizontal scroll |
| `src/gyro_processor.zig` | Normalized gyro curve (vader5 algorithm) |
| `devices/lenovo/legion-go-s.toml` | Legion Go S device config |
| `devices/hori/horipad-steam.toml` | Horipad Steam device config |
| `devices/flydigi/vader4-pro.toml` | Flydigi Vader 4 Pro device config |
| `devices/microsoft/xbox-xpad.toml` | Xbox xpad_uhid device config |
| `install/padctl.service` | Updated service file (PIDFile, remove `@` variant) |
| `docs/contributing/device-toml-from-inputplumber.md` | Rust→TOML transcription guide |
| `.github/workflows/ci.yml` | Three-job parallel CI (lint/test/cross-compile) |
| `.github/workflows/release.yml` | SHA256SUMS + git-cliff + AUR auto-push |
| `cliff.toml` | git-cliff conventional commit config |
| `contrib/aur/padctl-bin/PKGBUILD` | AUR PKGBUILD with padctl-capture/debug |
| `contrib/copr/padctl.spec` | Fedora RPM spec |
| `contrib/copr/README.md` | COPR setup guide for maintainers |

## Architecture

### Wave 0 — CLI subcommands (T1/T2/T3)

```
padctl install [--prefix /usr] [--destdir ""]
  1. assert UID=0
  2. copy binary → $DESTDIR$PREFIX/bin/padctl
  3. write embedded service string → $DESTDIR$PREFIX/lib/systemd/system/padctl.service
  4. copy devices/*.toml → $DESTDIR$PREFIX/share/padctl/devices/
  5. read installed TOML VID/PID → generate 99-padctl.rules → $DESTDIR$PREFIX/lib/udev/rules.d/
  6. if DESTDIR="": systemctl daemon-reload && udevadm control --reload-rules && udevadm trigger
  7. print install summary

padctl scan [--config-dir <dir>]
  1. enumerate /dev/hidraw* via HIDIOCGRAWINFO (VID/PID/name)
  2. HIDIOCGRAWPHYS → deduplicate multi-interface physical devices
  3. search XDG devices/ for VID/PID match (--config-dir overrides; T4 path reused after T4)
  4. print structured report; exit 0 even if some are unknown

padctl reload [--pid <pid>]
  PID lookup: --pid arg → /run/padctl.pid → pgrep -x padctl
  send SIGHUP → wait 500ms → ps -p confirms alive → print "Reloaded."
```

`padctl.service` gains `PIDFile=/run/padctl.pid`; `ExecStart` gains `--pid-file /run/padctl.pid`.
`padctl@.service` deleted (ADR-006).

### Wave 1 — XDG paths, device TOMLs, release, COPR (T4–T8)

**`src/config/paths.zig`** exports:

```zig
pub fn userConfigDir(allocator: Allocator) ![]u8      // $XDG_CONFIG_HOME/padctl or ~/.config/padctl
pub fn systemConfigDir() []const u8                   // /etc/padctl
pub fn dataDir() []const u8                           // /usr/share/padctl
pub fn searchDeviceConfigs(allocator: Allocator, out: *DeviceConfigList) !void
pub fn searchMappingConfig(allocator: Allocator, device_name: []const u8) !?[]u8
```

Priority (highest first): `~/.config/padctl/` → `/etc/padctl/` → `/usr/share/padctl/`

**Device TOMLs** (T5 guide → T6 manual transcription from InputPlumber Rust packed structs):

| Device | VID | PID | Input report |
|--------|-----|-----|-------------|
| Legion Go S | 0x1a86 | 0xe310/0xe311 | 32B gamepad (id=0x06) + 9B IMU (id=0x05) |
| Horipad Steam | 0x0f0d | 0x0196/0x01ab | 287B BT (id=0x07) |
| Vader 4 Pro | 0x04b4 | 0x2412 | 32B (id=0x04), gyro Y split-bytes |
| Xbox xpad_uhid | various | various | 16B DInput (id=0x11) / 17B XBox Series (id=0x01) |

**Release pipeline** changes:
- `release.yml`: build job uploads artifacts; checksum job downloads and runs `sha256sum`; both uploaded to GitHub Release
- `cliff.toml`: conventional commits grouped by feat/fix/doc/perf/refactor
- `update-aur` job: `archlinux-downgrade/aur-publish-action@v1`, requires `AUR_SSH_KEY` secret

**COPR** (`contrib/copr/padctl.spec`): precompiled static binary packaged into SRPM to bypass Zig compiler dependency on COPR build hosts (ADR-D5).

### Wave 2 — Config UX, scroll, gyro, CI (T9–T12)

**`padctl config` subcommands** (all depend on T4 XDG paths):

| Subcommand | Behavior |
|------------|----------|
| `list` | Scan XDG three-layer devices/ + mappings/; annotate `[running]` if daemon active |
| `init` | Interactive: detect connected device → select output preset → select mapping template → write `~/.config/padctl/mappings/<name>.toml` → `padctl --validate` |
| `edit` | Locate TOML via XDG priority (user layer preferred); open `$VISUAL > $EDITOR > vi`; validate on exit |
| `test` | Load mapping (no uinput); read hidraw; print mapped events live until Ctrl-C |

**Gyro curve normalization** (T11):
```
normalized = clamp((abs(raw) - deadzone) / (GYRO_MAX - deadzone), 0, 1)
curved     = pow(normalized, curve)
result     = copysign(curved * (GYRO_MAX - deadzone) + deadzone, raw)
```
Guard: when `GYRO_MAX == deadzone`, result = 0. `curve=1.0` produces same output as prior linear path.

**Horizontal scroll** (T10):
- `StickProcessor.processScrollMode` accumulates `scroll_accum_h` from `axis_x`
- Emits `AuxEvent{ .scroll_h = delta }` when threshold crossed
- `AuxDevice` registers `REL_HWHEEL` capability at creation

**CI restructure** (T12):
```yaml
jobs:
  lint:          # zig fmt --check src/ tools/
  test:          # zig build test (apt: libusb-1.0-0-dev)
  cross-compile: # matrix: [x86_64-linux-musl, aarch64-linux-musl]
                 # zig build -Dtarget=... -Dlibusb=false -Doptimize=ReleaseSafe
```
Zig version pinned to `0.15.2` via `mlugg/setup-zig@v2` in both `ci.yml` and `release.yml`.
`flake.nix` hardcoded `x86_64-linux-musl` target removed; use system-native target.

## Key Design Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | `padctl install` + `zig build install` in parallel | Self-describing binary install for end users; build system target for packagers |
| D2 | udev rules auto-generated from devices/*.toml VID/PID | New devices require no manual udev edits (ADR-008) |
| D3 | Delete `padctl@.service`, keep only daemon mode | Supervisor auto-discovers all devices; per-device service model is obsolete (ADR-006) |
| D4 | Bare `padctl` invocation triggers XDG search | Default UX for end users; explicit `--config` still takes precedence (ADR-007) |
| D5 | COPR: precompiled binary in SRPM | COPR build hosts have no Zig 0.15.2; cross-compiling static binary in release.yml is simpler |
| D6 | Manual Rust→TOML transcription for InputPlumber devices | No viable automated conversion; protocol facts are not copyright-protected |
| D7 | Gyro curve normalized over deadzone→max interval | Matches vader5 reference; `curve != 1.0` now produces expected response curve shape |

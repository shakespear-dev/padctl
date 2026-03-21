# padctl

Universal Linux gamepad compatibility layer.

padctl maps vendor-specific USB/HID reports from gamepads to standard Linux input events via uinput, using declarative TOML device configs — no kernel patches, no custom drivers.

## How it works

```
TOML device config
      │
      ▼
  padctl (userspace daemon)
      │  reads raw HID reports from /dev/hidraw*
      │  applies field mappings and transforms
      ▼
  /dev/uinput  →  standard evdev gamepad
```

Each device config declares report layout, field offsets, transforms, and button mappings. The same generic interpreter handles all devices.

## Features

- Declarative TOML config — add device support without recompiling
- Axes, buttons, triggers, IMU (gyro/accelerometer)
- Transform pipeline: scale, negate, deadzone, clamp
- Rumble/haptic feedback passthrough
- Daemon mode (netlink hotplug) and per-device mode (udev template)
- `padctl-capture` tool to generate TOML skeleton from live HID stream
- `padctl --validate` for CI-friendly config validation
- Zero runtime dependencies beyond libusb

## Quick start

### Install

Build from source (see [Building from source](#building-from-source)), then:

```sh
sudo cp zig-out/bin/padctl zig-out/bin/padctl-capture /usr/bin/
sudo cp install/padctl.service install/padctl@.service /etc/systemd/system/
sudo cp install/99-padctl.rules /etc/udev/rules.d/
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
```

### Configure

Place device configs in `/etc/padctl/devices.d/`. Configs for supported devices are in `devices/`.

```sh
sudo mkdir -p /etc/padctl/devices.d
sudo cp devices/sony/dualsense.toml /etc/padctl/devices.d/
```

### Run

```sh
# Daemon mode — manages all devices via netlink hotplug
sudo systemctl enable --now padctl.service

# Or per-device mode — udev starts one instance per device plug-in
sudo systemctl enable padctl@sony-dualsense.service
```

## Device config example

```toml
[device]
name = "Sony DualSense"
vid = 0x054c
pid = 0x0ce6

[[report]]
name = "usb"
interface = 3
size = 64

[report.match]
offset = 0
expect = [0x01]

[report.fields]
left_x  = { offset = 1, type = "u8", transform = "scale(-32768, 32767)" }
left_y  = { offset = 2, type = "u8", transform = "scale(-32768, 32767), negate" }
lt      = { offset = 5, type = "u8" }
cross   = { offset = 8, type = "bit", bit = 4 }
```

## Supported devices

| Vendor     | Model                  | Config                              |
|------------|------------------------|-------------------------------------|
| Sony       | DualSense (PS5)        | `devices/sony/dualsense.toml`       |
| Nintendo   | Switch Pro Controller  | `devices/nintendo/switch-pro.toml`  |
| 8BitDo     | Ultimate               | `devices/8bitdo/ultimate.toml`      |
| Microsoft  | Xbox Elite Series 2    | `devices/microsoft/xbox-elite.toml` |
| Flydigi    | Vader 5                | `devices/flydigi/vader5.toml`       |

## Building from source

**Requirements:** Zig 0.15+, libusb-1.0

```sh
# Debian/Ubuntu
sudo apt-get install libusb-1.0-0-dev

# Fedora/RHEL
sudo dnf install libusb1-devel

# Arch
sudo pacman -S libusb
```

```sh
zig build
# outputs: zig-out/bin/padctl  zig-out/bin/padctl-capture
```

```sh
zig build test
```

## systemd integration

Two service modes are provided in `install/`:

| Mode | Service | Trigger |
|------|---------|---------|
| Daemon | `padctl.service` | starts at boot, manages all devices via netlink |
| Per-device | `padctl@.service` | udev starts one instance per device plug-in |

Run one mode at a time. See [`install/README.md`](install/README.md) for full setup instructions.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add a device config or contribute code.

## License

MIT — see [LICENSE](LICENSE).

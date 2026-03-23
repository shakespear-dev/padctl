# Contributing

There are two main ways to contribute to padctl:

## Add Device Support

If you have a gamepad that padctl doesn't support yet, you can add it by creating a TOML device config. No code changes needed.

1. **Capture HID reports** — `padctl-capture --device /dev/hidrawN --duration 30`
2. **Write a device TOML** — see [Device Config Reference](../device-config.md)
3. **Test it** — `padctl-debug devices/vendor/model.toml`
4. **Submit a PR**

Two guides to help you get started:

- **[HID Reverse Engineering Guide](reverse-engineering.md)** — start from scratch with Wireshark, xxd, and padctl-capture. Covers the full process from plugging in an unknown gamepad to a working TOML config.
- **[Device TOML from InputPlumber](device-toml-from-inputplumber.md)** — if the device already has an InputPlumber driver, convert the Rust structs to padctl TOML.

## Code Contributions

See [CONTRIBUTING.md](https://github.com/BANANASJIM/padctl/blob/main/CONTRIBUTING.md) for:

- Fork + branch workflow
- Code style (`zig fmt`)
- Test requirements (`zig build check-all`)
- Build flags (`-Dlibusb=false`, `-Dwasm=false`)

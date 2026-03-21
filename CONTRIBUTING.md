# Contributing a Device Config

Three steps:

1. **Capture**: Run `padctl-capture` against the target device to produce a TOML skeleton.

   ```
   sudo ./zig-out/bin/padctl-capture /dev/hidraw0 > devices/<vendor>/<model>.toml
   ```

2. **Complete**: Fill in field names, button names, transform chains, and the `[output]` section.
   See existing configs in `devices/` for reference.

3. **Submit**: Open a pull request. CI runs `padctl --validate` automatically. Once the validator
   reports zero errors and a maintainer approves, the config is merged.

## Validator

Run locally before submitting:

```
zig build && ./zig-out/bin/padctl --validate devices/<vendor>/<model>.toml
```

Exit 0 = valid. Exit 1 = validation errors (fix them). Exit 2 = file not found or parse failure.

## Directory layout

```
devices/
├── sony/          Sony (DualSense, DualShock)
├── nintendo/      Nintendo (Switch Pro, Joy-Con)
├── 8bitdo/        8BitDo
├── microsoft/     Microsoft Xbox
└── flydigi/       Flydigi
```

Add a new vendor directory if the manufacturer is not listed.

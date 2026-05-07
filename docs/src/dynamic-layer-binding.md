# Dynamic Layer Binding

Bind a layer's activation trigger to any controller button **at runtime**, without editing your mapping file. Useful when every game uses a different aim button and you want gyro-aim to follow whichever button the current game expects.

> Source design: [`prd/dynamic-layer-binding.md`](https://github.com/anthropics/padctl/blob/main/prd/dynamic-layer-binding.md)

## What it does

A *dynamic layer* is a regular `[[layer]]` whose activation trigger can be reassigned at runtime via a button combination you define. The runtime-bound trigger and any static `trigger = "..."` both activate the layer (union semantics) so muscle memory keeps working alongside the per-game binding.

Key properties:

- **In-memory only** — bindings reset on `padctl reload`, mapping switch, and daemon restart. By design.
- **Single dynamic layer per mapping** — one layer is the runtime target.
- **Single live binding** — pressing the combo with a different button replaces; pressing with the currently bound button unbinds.
- **Trigger passthrough** — the runtime-bound button still reaches the virtual gamepad, so the game sees it normally even while the layer is also active.
- **Tactile feedback** — distinct rumble pulses for bind / unbind / replace / rejected.

## Quick start (Flydigi Vader 5 Pro)

The bundled `mappings/vader5.toml` ships with the feature pre-configured. Quick recap:

```toml
[[layer]]
name = "aim"
trigger = "LM"                          # static muscle-memory trigger
activation = "hold"
hold_timeout = 200
passthrough_trigger = "honor_timeout"   # let LM taps reach the game; suppress when layer is active

[layer.gyro]
mode = "mouse"
sensitivity = 60.0
# ...

[dynamic_bind]
target_layer = "aim"
modifier = ["O"]                        # Flydigi logo button, bottom-center (rarely bound by games)
hold_ms = 80
trigger_threshold = 200                 # only matters when bound to LT/RT
trigger_threshold_direction = "above"   # hard pull activates
release_threshold = 184                 # hysteresis cutoff (16 below threshold)
```

Workflow during gameplay:

1. **Bind** — hold **O**, then press the in-game aim button (e.g. **RT**). After ~80 ms a strong rumble pulse confirms the bind. RT now activates the gyro-aim layer.
2. **Use** — pull RT to aim. The layer activates, gyro maps to mouse, RT also reaches the game (so ADS still works in-engine).
3. **Replace** — different game uses **LB** to aim? Hold **O + LB**. The previous binding (RT) auto-clears, LB takes its place.
4. **Unbind** — hold **O + RT** again (the currently bound button). Two short pulses confirm unbind.

## Configuration reference

### `[[layer]]` additions

| Field | Type | Default | Effect |
|---|---|---|---|
| `passthrough_trigger` | enum | `"never"` | Gates whether the layer's trigger button reaches the virtual gamepad. See below. |
| `trigger` | string | required (legacy) — **now optional** | Omit to make the layer dynamic-only (only reachable via runtime binding). |

`passthrough_trigger` values:

- `"never"` (default) — trigger always consumed (legacy behavior). Existing mappings change nothing.
- `"always"` — trigger always reaches the game. Useful when the same button should both activate the layer AND fire its in-game action.
- `"honor_timeout"` — passthrough during the tap-hold *pending* window (before `hold_timeout` elapses), suppressed once the layer becomes *active*. Brief taps reach the game, long holds activate the layer cleanly.

### `[dynamic_bind]` section

| Field | Type | Default | Effect |
|---|---|---|---|
| `target_layer` | string | required | Name of the `[[layer]]` this combo controls. |
| `modifier` | array of strings | required | Buttons that must all be held to start the bind chord. Mirrors the `chord_switch.modifier` shape. |
| `hold_ms` | integer | `80` | Debounce window before a target-button press counts as a bind. |
| `trigger_threshold` | u8 (0–255) | none | When the bound button is analog (LT/RT), the analog cutoff for layer activation. Ignored for digital buttons. |
| `trigger_threshold_direction` | `"above"` \| `"below"` | `"above"` | `"above"`: hard pull activates. `"below"`: light press activates. |
| `release_threshold` | u8 (0–255) | `trigger_threshold ± 16` | Hysteresis cutoff. The layer stays active in the band between threshold and release_threshold; only crossing release_threshold flips state. |

Validation:
- Unknown modifier name → warning, feature disabled (mapping still loads).
- Unknown `target_layer` → warning, feature disabled.
- A `[[layer]]` with no `trigger` and no `[dynamic_bind]` reference → warning ("dead config"); mapping still loads.

## Variants

### A. With static trigger (Vader 5 default)

The layer keeps a static `trigger = "LM"` AND can be dynamically bound to a per-game button. Both activate the layer.

```toml
[[layer]]
name = "aim"
trigger = "LM"
activation = "hold"
passthrough_trigger = "honor_timeout"

[dynamic_bind]
target_layer = "aim"
modifier = ["O"]
trigger_threshold = 200
```

Best for: users who want a fallback/muscle-memory shortcut alongside per-game binding.

### B. Dynamic-only layer

Drop the static trigger entirely. The layer is reachable **only** when something is dynamically bound.

```toml
[[layer]]
name = "aim"
# no trigger field — dynamic-only
activation = "hold"
passthrough_trigger = "always"

[dynamic_bind]
target_layer = "aim"
modifier = ["O"]
trigger_threshold = 200
```

Best for: clean slate per game; no risk of accidental activation via a leftover static button.

### C. Inverse threshold (`direction = "below"`)

Layer activates on **light** press, deactivates on **hard** press. Useful for adaptive trigger play styles.

```toml
[dynamic_bind]
target_layer = "aim"
modifier = ["O"]
trigger_threshold = 100
trigger_threshold_direction = "below"
release_threshold = 116
```

Pulling RT lightly (any value in 1..99) activates aim; squeezing past 116 deactivates.

## Feedback channels

When a bind action fires, padctl emits four signals:

1. **Rumble** — distinct pulse shape per action (bound/replaced = strong-short, unbound = medium-medium, rejected = weak-short).
2. **journalctl / stderr** — `dynamic_bind: bound layer=aim button=RT` info-level line.
3. **Diagnostic dump** — same line tees to the daemon's log file when `padctl dump on` is enabled.
4. **Control socket broadcast** — `EVENT bind action=bound layer=aim button=RT` line pushed to every connected client. External tools (tray UIs, status overlays) can subscribe.

`padctl status` also shows the current binding:

```
STATUS device=Flydigi Vader 5 Pro state=active mapping=vader5 \
       dyn_bind=aim static=LM runtime=RT
```

## Troubleshooting

### Combo not firing
- Check the modifier name is in the device's button map. Run `padctl --validate mappings/vader5.toml` — a warning like `[dynamic_bind] modifier contains unknown button name` indicates a typo.
- Make sure you hold the modifier for the full `hold_ms` debounce window (default 80 ms) before pressing the target button.
- Check `padctl status` — if no `dyn_bind=...` line appears, the feature was disabled at load time. Look at journalctl for the warning.

### Binding doesn't survive reload
By design. Bindings are in-memory only. If you find yourself rebinding the same button repeatedly, just edit the mapping file and add a static `trigger`.

### Self-binding rejected
Pressing the modifier itself or the layer's static trigger as the target is rejected at runtime (a distinct rumble pattern signals the rejection). This prevents deadlock.

### Threshold flickers near the cutoff
Use a wider hysteresis: increase the gap between `trigger_threshold` and `release_threshold`. The default is 16 (~6% of the 0–255 range); 32–48 is fine for triggers with noisy analog readouts.

### Status doesn't show `dyn_bind=...`
Either the mapping has no `[dynamic_bind]` section, or it failed validation. Check `padctl status`'s mapping name and re-validate with `padctl --validate <path>`.

## Modifier choice notes

The default `modifier = ["O"]` works on the Vader 5 Pro because O (the Flydigi logo button at the bottom-center) is routed as `BTN_TRIGGER_HAPPY9` to the virtual gamepad — most games leave that button unbound, so holding O during normal gameplay has no effect. Other reasonable choices:

- `["M1"]` — rear-left paddle. Routed as `BTN_TRIGGER_HAPPY5`. Also rarely bound by games. Pick this if you'd rather press a paddle than a face button.
- `["LB", "RB"]` — both shoulder buttons. Two-button chord, harder to trigger accidentally, but conflicts with games that bind LB or RB.
- `["LM", "RM"]` — top paddles. Currently NOT routed to the virtual gamepad (`[output.buttons]` in the device config has them commented out), so they're game-invisible. Conflicts with the bundled `aim` layer's static trigger (LM); requires removing `trigger = "LM"` to use this combo.
- `["Turbo"]` — once the Vader 5 Pro Turbo button bit is captured (separate task; see PRD's Out-of-Scope section), `modifier = ["Turbo"]` becomes the truly inert default since the Turbo button is not exposed as a uinput button at all.

## Related issues / PRs

- [PRD: Dynamic Layer Binding](https://github.com/anthropics/padctl/blob/main/prd/dynamic-layer-binding.md)
- [Phased plan](https://github.com/anthropics/padctl/blob/main/plans/dynamic-layer-binding.md)
- Issue #183 — `chord_switch` for mapping switching (sibling feature, same chord-detection lineage)

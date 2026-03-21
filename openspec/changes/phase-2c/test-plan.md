# Phase 2c Test Plan

## Test Layers

| Layer | Description | CI |
|-------|-------------|-----|
| L0 | Pure functions — no fd, no kernel, no alloc side-effects | Yes |
| L1 | Mock vtable / mock fd — no `/dev/hidraw`, no `/dev/uinput` | Yes |
| L2 | Real devices — multiple controllers connected, `/dev/uinput` available | Manual only |

All L0 + L1 tests live under `zig build test` and must pass in CI.

---

## T1: DeviceInstance encapsulation (L0)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | `DeviceInstance.init` with valid config | all sub-components initialized; no error |
| 2 | `stop()` called before `run()` starts | stop_pipe written; `run()` exits on first ppoll return |
| 3 | `stop()` called while `run()` is blocked in ppoll | ppoll returns; `run()` exits cleanly |
| 4 | `updateMapping` called; next ppoll iteration begins | `pending_mapping` acquire-loaded; `mapper.replaceConfig` called before any fd is processed |
| 5 | `updateMapping` called twice without intervening ppoll | second write overwrites first (atomic store); only the latest mapping is applied |

---

## T2: MacroConfig TOML parsing (L0)

| # | Input | Expected |
|---|-------|----------|
| 1 | `[[macro]]` with all five step types | each step decoded to correct `MacroStep` variant |
| 2 | multiple `[[macro]]` blocks | all macros in `MappingConfig.macros`; names preserved |
| 3 | `M1 = "macro:dodge_roll"` in `[remap]` | `RemapTarget.macro("dodge_roll")` |
| 4 | `M1 = "macro:no_such"`, macro not declared | `error.UnknownMacro` at parse time |
| 5 | `steps = []` (empty macro) | valid; `Macro.steps.len == 0`; no error |
| 6 | `{ delay = 50 }` | `MacroStep.delay = 50` (milliseconds) |
| 7 | `{ pause_for_release = true }` | `MacroStep.pause_for_release` |
| 8 | `macro:name` in a layer remap (`[layer.aim.remap]`) | same `RemapTarget.macro` parsing applies |

---

## T3: Supervisor thread management (L1)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Two mock DeviceInstances spawned | both threads running; each processes its own injected events |
| 2 | Event injected into instance A | instance B state unchanged |
| 3 | `stop()` on instance A | A's thread exits; B continues running |
| 4 | SIGTERM delivered to Supervisor | `stop()` called on all instances; all threads joined; `Supervisor.run()` returns |
| 5 | SIGINT delivered to Supervisor | same as SIGTERM |
| 6 | Child thread exits (simulated device disconnect) | Supervisor detects join; schedules respawn with 1 s initial backoff |
| 7 | Child respawn fails four times | backoff sequence: 1 s → 2 s → 4 s → 8 s |
| 8 | Child respawn delay exceeds 30 s cap | capped at 30 s; does not grow further |

---

## T4: MacroPlayer + TimerQueue (L0/L1)

### MacroPlayer execution

| # | Scenario | Expected |
|---|----------|----------|
| 1 | `tap(B)` step | `press B` → sync → `release B` → sync; step_index advances; execution continues |
| 2 | `down(KEY_LSHIFT)` step | `press KEY_LSHIFT` → sync; step_index advances |
| 3 | `up(KEY_LSHIFT)` step | `release KEY_LSHIFT` → sync; step_index advances |
| 4 | `delay(50)` step | timerfd armed at `now + 50 ms`; `resume()` returns; called again after expiry; next step executes |
| 5 | `pause_for_release` step | `waiting_for_release = true`; `resume()` returns; no output until `notifyTriggerReleased()` |
| 6 | `notifyTriggerReleased()` after `pause_for_release` | `resume()` re-entered; execution continues from next step |
| 7 | Last step processed | player marked finished; caller removes from `active_macros` |
| 8 | Empty macro (`steps = []`) | `resume()` returns immediately; player finished |

### Layer switch macro cancellation

| # | Scenario | Expected |
|---|----------|----------|
| 9 | Layer switch while `active_macros` non-empty | up-event emitted for every held key; `active_macros` cleared |
| 10 | Layer switch with no active macros | no up-events; no error |

### Concurrent macros

| # | Scenario | Expected |
|---|----------|----------|
| 11 | Two MacroPlayers active simultaneously | each has independent `step_index`; steps advance independently |
| 12 | Player A at `delay(50)`, Player B at `tap(X)` | B's tap executes immediately; A's delay unaffected |

### TimerQueue

| # | Scenario | Expected |
|---|----------|----------|
| 13 | Tap-hold deadline + macro delay deadline inserted | timerfd armed to the earlier of the two |
| 14 | `drainExpired()` called when two deadlines have both passed | both entries dispatched in one call |
| 15 | `drainExpired()` called when no deadline has passed | no dispatch; no error |
| 16 | Deadline removed before expiry (tap-hold cancelled) | timerfd re-armed to next deadline; removed entry never dispatched |

---

## T5: Auto-discover (L1)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Two config files with distinct VID/PID; two matching hidraw nodes | two DeviceInstances created |
| 2 | One config; two hidraw nodes with same VID/PID, different physical paths | two DeviceInstances (different physical path keys) |
| 3 | Two config files both matching same VID/PID and same physical path | deduplication: one DeviceInstance created |
| 4 | Config directory contains no `*.toml` files | zero instances; Supervisor exits cleanly |
| 5 | `--config single.toml` (backward-compat path) | one DeviceInstance; behavior identical to Phase 2b |
| 6 | `discoverAll(vid, pid)` returns empty slice (device not connected) | no DeviceInstance created for that config; no error |

---

## T6: SIGHUP hot-reload (L1)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | SIGHUP; mapping section changed | new `MappingConfig` parsed; `DeviceInstance.updateMapping` called; instance not restarted |
| 2 | SIGHUP; mapping applied | effective within one ppoll cycle; old mapping never partially applied |
| 3 | SIGHUP; new config file added | new DeviceInstance spawned; existing instances unaffected |
| 4 | SIGHUP; config file removed | corresponding DeviceInstance stopped and joined; other instances unaffected |
| 5 | SIGHUP; no changes to config | Supervisor completes reload with no mutations |
| 6 | Two SIGHUPs delivered in quick succession | second reload begins only after first completes; no concurrent reload |

---

## T7: Integration (L0/L1/L2)

### Multi-device parallel (L1)

| # | Steps | Expected |
|---|-------|----------|
| 1 | Spawn two mock DeviceInstances; inject button press into A | only A's output sink receives event; B's sink unchanged |
| 2 | `stop()` instance A; inject event into B | B processes event normally; A thread is no longer running |

### Macro playback (L0/L1)

| # | Steps | Expected |
|---|-------|----------|
| 3 | `M1 = "macro:dodge_roll"` (tap B, delay 50, tap LEFT); press M1 | output: press B → release B → [50 ms timerfd] → press LEFT → release LEFT |
| 4 | `M2 = "macro:shift_hold"` (down LSHIFT, pause_for_release, up LSHIFT); hold M2 | output: press LSHIFT; no further output while M2 held |
| 5 | Release M2 after T7.4 | output: release LSHIFT |
| 6 | Layer switch while macro active | all held keys released; no further macro steps executed |

### Hot-reload (L1)

| # | Steps | Expected |
|---|-------|----------|
| 7 | Start with `M1 = "macro:dodge_roll"`; send SIGHUP; swap to `M1 = "KEY_A"` | next M1 press produces `KEY_A`; no macro steps |
| 8 | Measure time from SIGHUP to new mapping effective | less than one ppoll cycle |

### L2 Manual (local devices required)

| # | Scenario | Pass Condition |
|---|----------|----------------|
| 9 | Two controllers connected simultaneously | each appears as independent uinput node; neither interferes with the other's output |
| 10 | Macro `M1 = "macro:dodge_roll"` on controller A | correct key sequence emitted; controller B output unaffected |
| 11 | `padctl --config-dir /etc/padctl/devices.d/` with two device configs | both controllers active; each mapped independently |
| 12 | Edit mapping file while padctl running; send `kill -HUP` | new mapping active without restarting padctl |

L2 tests use `error.SkipZigTest` guard when no real hidraw device is present.

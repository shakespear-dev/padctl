# Tasks: padctl Phase 1

## Dependency Graph

```
Wave 0:
  T0

Wave 1 (depends: T0):
  T1, T2 (parallel)

Wave 2 (depends: T1, T2):
  T3, T4 (parallel)

Wave 3 (depends: T3):
  T5, T6 (parallel)

Wave 4 (depends: T3, T4):
  T7, T8 (parallel)

Wave 5 (depends: T5, T6, T7, T8):
  T9a → T9b → T9c  (serial)
  T10              (parallel with T9a)

Wave 6 (depends: T9a, T9b, T9c, T10):
  T11, T12 (parallel)
```

---

## T0: TOML Library Spike Validation

```yaml
id: T0
title: TOML library spike validation
description: >
  Validate sam701/zig-toml against a minimal flydigi-vader5.toml covering four
  structural cases: (1) [[report]] array-of-tables with nested [report.fields],
  (2) match field as single object with hex integer literals, (3) [commands.*]
  dynamic key-name sections deserializing to HashMap, (4) optional nested
  [report.checksum]. Each case must independently pass/fail. Any FAIL triggers
  the D10 fallback path (manual Value tree traversal, +2–3 days).
  Spike code goes to spike/toml_spike.zig and does NOT enter final code.
depends: []
context:
  - planning/phase-1.md §T0
  - _agent/state/needs-snapshot.md §DSL 完整参考
commit:
```

---

## T1: Zig Project Skeleton + build.zig + GitHub Actions CI

```yaml
id: T1
title: Zig project skeleton, build.zig, GitHub Actions CI
description: >
  Create build.zig using b.createModule() + b.addExecutable() (Zig 0.14+).
  Link linkSystemLibrary("usb-1.0") + linkLibC(). Register three test steps:
  test-unit (Layer 0), test-integration (Layer 1), test-e2e (Layer 2, local
  manual only); `zig build test` runs Layer 0+1. Directory layout follows
  needs-snapshot.md §模块结构 (src/core/, src/io/, src/config/).
  build.zig.zon sets minimum_zig_version = "0.14.0"; .zigversion contains
  "0.14.0". GitHub Actions CI: zig fmt --check src/ → zig build → zig build
  test; uses mlugg/setup-zig@v2 pinned at 0.14.0.
depends: [T0]
context:
  - planning/phase-1.md §T1
  - _agent/state/needs-snapshot.md §模块结构
commit:
```

---

## T2: TOML Parser Integration

```yaml
id: T2
title: Integrate sam701/zig-toml as build dependency
description: >
  Add dependency via `zig fetch --save git+https://github.com/sam701/zig-toml`.
  Wire into build.zig via exe_mod.addImport("toml", ...). Create
  src/config/toml.zig wrapping parse/free lifecycle so the allocator is
  reclaimed when the config is destroyed.
depends: [T0]
context:
  - planning/phase-1.md §T2
commit:
```

---

## T3: DeviceConfig Schema + Validation + Commands Template Schema

```yaml
id: T3
title: DeviceConfig schema, load-time validation, commands template schema
description: >
  Define DeviceConfig struct in src/config/device.zig covering all DSL fields:
  [device] (name/vid/pid), [[device.interface]] (id/class/ep_in/ep_out),
  [device.init] (commands/enable/disable/response_prefix), [[report]]
  (interface/match/size/fields/button_group/checksum), [commands.*] dynamic
  sections with {placeholder:type} syntax and optional per-command checksum.
  Load-time validation: offset bounds against report.size, bits start+len ≤ 8,
  transforms restricted to enumerated set (negate/abs/scale/clamp/deadzone/lookup),
  checksum range within report.size, no duplicate field_name, button names parsed
  to ButtonId enum. Validation failure returns error.InvalidConfig.
  Conditional fields are implemented via multi-report grouping (D9): no condition/
  when DSL keyword needed in Phase 1.
depends: [T1, T2]
context:
  - planning/phase-1.md §T3
  - engineering/interpreter.md §Config 加载时验证
  - engineering/interpreter.md §完整 Device Config 示例
  - _agent/state/needs-snapshot.md §DSL 完整参考
commit:
```

---

## T4: OutputConfig Schema + ABS/BTN Code Resolution

```yaml
id: T4
title: OutputConfig schema and uinput code resolution at load time
description: >
  Define OutputConfig + OutputAuxConfig structs in src/config/device.zig
  covering [output] section: name/vid/pid/axes/buttons/dpad/force_feedback/aux.
  resolveAbsCode / resolveBtnCode execute at config load time using a comptime
  table built from linux/input-event-codes.h via @cImport. Unknown code returns
  error.UnknownAbsCode / error.UnknownBtnCode. Phase 1 defines OutputAuxConfig
  schema but defers AuxDevice creation logic to T8.
depends: [T1, T2]
context:
  - planning/phase-1.md §T4
  - engineering/output.md §ABS/BTN Code 解析
  - engineering/output.md §Output DSL → uinput 创建流程
commit:
```

---

## T5: hidraw Backend + MockDeviceIO Test Infrastructure

```yaml
id: T5
title: hidraw backend, ioctl constants, MockDeviceIO
description: >
  src/io/ioctl_constants.zig: centralize all ioctl constants using
  std.os.linux.ioctl.IOR/IOW/IO (not hand-written magic numbers).
  src/io/hidraw.zig: implement DeviceIO vtable. discover(vid, pid, interface_id)
  iterates /dev/hidraw0..hidraw63, uses HIDIOCGRAWINFO to match VID/PID,
  HIDIOCGRAWPHYS (fixed 256B buffer) to extract interface number.
  grabAssociatedEvdev traverses sysfs path
  /sys/class/hidraw/hidrawN/device/input/inputM/eventK using
  std.fs.openDirAbsolute() + dir.iterate(); grabs all associated evdev fds.
  open() uses O_RDWR | O_NONBLOCK.
  src/test/mock_device_io.zig: MockDeviceIO implementing DeviceIO vtable.
  read() replays frames from []const []const u8; exhausted returns ReadError.Again.
  write() appends to write_log for test assertions.
  pollfd() returns socketpair pipe_r; test control side writes 1 byte to trigger.
depends: [T3]
context:
  - planning/phase-1.md §T5
  - engineering/device-io.md §hidraw 后端
  - engineering/device-io.md §ioctl 常量构造策略
commit:
```

---

## T6: usbraw/libusb Backend

```yaml
id: T6
title: usbraw backend with libusb, ring buffer, reader thread
description: >
  src/io/usbraw.zig: implement DeviceIO vtable for Vendor-class interfaces.
  open(): libusb_open_device_with_vid_pid → libusb_detach_kernel_driver (failure
  is normal, continue) → libusb_claim_interface (EBUSY → error.Busy).
  Reader thread: loops libusb_interrupt_transfer(ep_in, timeout=100ms); on
  success writes 1 byte to pipe; checks atomic should_stop flag after each
  timeout. close(): set should_stop=true, thread.join(), then close pipe fds.
  pollfd() returns pipe read end. read() consumes from ring buffer
  (capacity = max_report_size * 16; overflow drops oldest + logs warning).
  write(): synchronous libusb_interrupt_transfer to ep_out, 100ms timeout →
  WriteError.Io on timeout.
depends: [T3]
context:
  - planning/phase-1.md §T6
  - engineering/device-io.md §usbraw 后端
  - engineering/device-io.md §多 interface 协调
commit:
```

---

## T7: Protocol Interpreter

```yaml
id: T7
title: Protocol Interpreter — 5-step processReport pipeline
description: >
  src/core/interpreter.zig: implement Interpreter.processReport(interface_id, raw)
  following the 5-step pipeline: [1] report matching (filter by interface_id, then
  first-match within interface; AND semantics for array match), [2] checksum
  verification (sum8 / crc32 / xor; seed is prefix byte not initial value),
  [3] field extraction (offset+type with endianness, bits=[byte,start,len] LE bit
  numbering, button_group batch single-bit), [4] transform chain application
  (negate/abs/scale/clamp/deadzone/lookup; left-to-right), [5] GamepadStateDelta
  population (unknown field names silently ignored; Optional semantics for missing
  fields). raw.len < report.size returns null. Bits out of bounds returns
  ProcessError.MalformedConfig. processReport is stateless.
depends: [T3]
context:
  - planning/phase-1.md §T7
  - engineering/interpreter.md §核心接口
  - engineering/interpreter.md §数据流
  - engineering/interpreter.md §边界条件
  - engineering/interpreter.md §CRC32 seed 语义
commit:
```

---

## T8: UinputDevice + OutputDevice vtable + Minimal AuxDevice

```yaml
id: T8
title: UinputDevice creation, OutputDevice vtable, minimal AuxDevice skeleton
description: >
  src/io/uinput.zig: implement UinputDevice.create(cfg) 6-step flow:
  UI_SET_EVBIT → UI_SET_ABSBIT → UI_SET_KEYBIT → FF bit (if declared) →
  uinput_setup (VID/PID/BUS_VIRTUAL/ff_effects_max) → UI_ABS_SETUP per axis →
  UI_DEV_CREATE. UI_DEV_CREATE failure with EPERM → error.PermissionDenied.
  emit() diff-sends: only changed fields produce events; MAX_EVENTS=64.
  pollFf(): handles EV_UINPUT upload/play/erase events (UI_BEGIN/END_FF_UPLOAD,
  UI_BEGIN/END_FF_ERASE); Phase 1 returns FfEvent but play routing deferred.
  outputDevice() returns OutputDevice interface.
  Minimal AuxDevice: infer needed KEY_*/BTN_* codes from remap targets at config
  load; register only inferred capabilities; create only when remap targets exist.
  emitAux() supports AuxEvent.key and AuxEvent.mouse_button; REL events deferred
  to Phase 2a. auxOutputDevice() returns AuxOutputDevice interface.
  src/test/mock_output.zig: MockOutput implementing OutputDevice vtable, recording
  GamepadState sequence. MockAuxDevice implementing AuxOutputDevice vtable.
depends: [T3, T4]
context:
  - planning/phase-1.md §T8
  - engineering/output.md §Output DSL → uinput 创建流程
  - engineering/output.md §OutputDevice vtable（可 mock 接口）
  - engineering/output.md §差分事件发送
  - engineering/output.md §AuxDevice 事件发送
commit:
```

---

## T9a: ppoll Event Loop + signalfd Signal Handling

```yaml
id: T9a
title: ppoll event loop skeleton with signalfd
description: >
  src/main.zig: extract runEventLoop(fds: []pollfd, nfds: usize, ...) !void as
  a standalone function (not inlined in main()) to enable Layer 1 mock injection.
  signalfd setup: create sigset with SIGTERM+SIGINT, sigprocmask(SIG.BLOCK),
  std.posix.signalfd(-1, &mask, 0), add to ppoll set, read signalfd_siginfo on
  ready. ppoll fd array MAX_FDS=8: interface fds, signalfd, uinput FF fd,
  timerfd slot (reserved but nfds excludes it in Phase 1; slot exists to allow
  Phase 2a activation with nfds += 1 only).
depends: [T5, T6, T7, T8]
context:
  - planning/phase-1.md §T9a
  - engineering/device-io.md §多 interface 协调
  - engineering/mapper.md §Tap-Hold 定时器需求
commit:
```

---

## T9b: CLI Parsing + Config Loading + Handshake

```yaml
id: T9b
title: CLI argument parsing, config loading, interface initialization, handshake
description: >
  src/cli.zig: parse --config <device.toml>, --mapping <mapping.toml> (optional),
  --validate <device.toml> (load + validate only, no daemon start; exit 0 on
  success, exit 1 + error message on failure).
  main.zig assembly: load DeviceConfig, initialize each [[device.interface]] as
  hidraw or usbraw backend, run runInitSequence(io, cmds, response_prefix).
  runInitSequence: for each command, write then retry-read (max 10, 5ms interval)
  checking std.mem.startsWith against response_prefix; exhausted retries →
  error.InitFailed. Basic reconnect: open failure triggers exponential backoff
  retry (3 attempts, 1s/2s/4s intervals); failure logs error and exits.
depends: [T9a]
context:
  - planning/phase-1.md §T9b
  - engineering/device-io.md §初始化握手序列
commit:
```

---

## T9c: Full Pipeline Integration

```yaml
id: T9c
title: Full DeviceIO → Interpreter → OutputDevice pipeline in main loop
description: >
  src/main.zig: wire the complete pipeline. After ppoll returns, iterate revents,
  locate the corresponding interface by fd, call DeviceIO.read() for raw bytes,
  call Interpreter.processReport(interface_id, raw) for delta, call
  OutputDevice.emit(state) when delta is non-null. When FF fd is ready, call
  OutputDevice.pollFf(). main.zig holds OutputDevice interface (not UinputDevice
  directly) so Layer 1 tests can inject MockOutput. FF play routing (sending
  commands to device) is deferred to Phase 2b; Phase 1 discards play events after
  upload acknowledgement.
depends: [T9a, T9b]
context:
  - planning/phase-1.md §T9c
  - engineering/interpreter.md §核心接口
  - engineering/output.md §GamepadState → uinput 事件路径
commit:
```

---

## T10: Vader 5 Pro Device Config

```yaml
id: T10
title: Flydigi Vader 5 Pro TOML device config
description: >
  devices/flydigi-vader5.toml: complete config per needs-snapshot.md §DSL 完整参考.
  [device]: VID=0x37d7 PID=0x2401. [[device.interface]]: IF0 vendor class
  (ep_in=0x81, ep_out=0x05), IF1 hid class. [device.init]: 4 handshake commands
  + enable command with response_prefix. [[report]] extended: IF1, magic match
  [0x5a,0xa5,0xef], 32 bytes, all analog/button/IMU fields with transforms.
  [[report]] standard: IF0, AND match [offset=0,expect=[0x00]] +
  [offset=1,expect=[0x14]], 20 bytes. [commands.rumble]: Xbox 360 format 8B with
  {strong:u8} {weak:u8}. [output]: Xbox Elite Series 2 VID/PID, 6 analog axes,
  standard+extended buttons, dpad type=buttons, force_feedback type=rumble.
depends: [T3, T4]
context:
  - planning/phase-1.md §T10
  - _agent/state/needs-snapshot.md §Vader 5 Pro 协议参考（已逆向）
  - _agent/state/needs-snapshot.md §DSL 完整参考
commit:
```

---

## T11: End-to-End Validation

```yaml
id: T11
title: End-to-end validation (Layer 1 automated + Layer 2 UHID manual)
description: >
  src/test/integration/e2e.zig: Layer 1 automated path (CI mainline): inject
  IF1 32-byte sample via MockDeviceIO → interpreter → MockOutput; assert
  GamepadState fields (joystick values, button states). Also: IF0 standard report
  button bitfield parsing; checksum mismatch prevents emit call.
  Layer 2 UHID path (local manual): zig build test-e2e; UHID creates virtual
  Vader 5 (VID/PID/phys with "input1"); inject pre-recorded IF1 frames; padctl
  exercises full hidraw discover → open → read path; evdev reader asserts events.
  Tests that require /dev/uhid skip via error.SkipZigTest when not available.
  Manual verification points: jstest --normal /dev/input/jsN, evtest showing axes
  and key events, VID/PID matching [output] declaration.
depends: [T9a, T9b, T9c, T10]
context:
  - planning/phase-1.md §T11
commit:
```

---

## T12: Basic Button Remap

```yaml
id: T12
title: Basic button remap ([remap] section, no Layer/suppress/inject pipeline)
description: >
  src/core/remap.zig: Phase 1 simplified remap skeleton. Load [remap] section
  from mapping config: parse ButtonId string and RemapTarget (key/mouse_button/
  gamepad_button/disabled) with Linux input code resolution at load time.
  Per-frame application: for each declared remap, suppress source button and
  route target — key/mouse_button to AuxOutputDevice, gamepad_button to main
  OutputDevice, disabled suppresses only. Undeclared buttons pass through
  unchanged to main OutputDevice. No Layer, no full suppress/inject pipeline,
  no tap-hold.
  src/config/mapping.zig: MappingConfig struct with [remap] section only in
  Phase 1.
  Primary user scenario: M1 = { type = "key", code = "KEY_F13" } → pressing M1
  triggers KEY_F13 keyboard event via AuxDevice.
depends: [T9c, T10]
context:
  - planning/phase-1.md §T12
  - engineering/mapper.md §RemapTarget
commit:
```

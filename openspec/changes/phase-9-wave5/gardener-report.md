# Gardener Report: Phase 9 Wave 5 — inotify Hot-Reload + Battery Extraction (T17/T19a)

## 审查范围

- `openspec/changes/phase-9-wave5/brief.md`
- `openspec/changes/phase-9-wave5/design.md`
- `openspec/changes/phase-9-wave5/tasks.md`
- `openspec/changes/phase-9-wave5/test-plan.md`
- 交叉校验: `src/supervisor.zig`, `src/core/state.zig`, `devices/sony/dualsense.toml`

---

## 一致性检查

### 1. T17: inotify Config Hot-Reload

- [x] design.md 的 Supervisor 新字段 (`inotify_fd`, `debounce_fd`) 与 tasks.md T17a 一致
- [x] 现有 `src/supervisor.zig` 的 ppoll 循环使用 `[3]posix.pollfd`, design 正确描述扩展到 5 slots
- [x] 现有 `initForTest` 设 `netlink_fd = -1`, design 沿用相同模式设 `inotify_fd = -1`, `debounce_fd = -1`
- [x] `run()` 中 SIGHUP 处理逻辑调用 `reloadFn` + `self.reload()`, design 复用同一路径用于 debounce 触发
- [x] `deinit()` 中关闭 `netlink_fd >= 0` 的模式可直接复用于 inotify/debounce fds
- [x] test-plan TP1-TP10 覆盖: 创建、降级、initForTest、文件写入触发、合并、re-arm、SIGHUP 共存、rename、ppoll fd 管理

**发现 I1 (INFO)**: tasks.md T17b 提到 nfds 计算需处理 4 种组合 (netlink/inotify 各自有无), 但随后正确地简化为 "fd=-1 让 ppoll 忽略"。这消除了复杂的条件分支, 与现有 netlink_fd 处理风格一致。

**发现 W1 (WARNING)**: design.md 提到 `armDebounce` 使用 `linux.timerfd_settime`, 但现有 `supervisor.zig` 中使用的是 `posix` 命名空间 (如 `posix.signalfd`, `posix.close`)。Zig std 中 `timerfd_settime` 位于 `linux` 命名空间而非 `posix`, 这是正确的, 但代码风格会混用两个命名空间。建议统一说明。

**发现 W2 (WARNING)**: design.md 提到 config dir 路径通过 `Supervisor.init()` 或 `run()` 参数传入, 但 tasks.md T17d 同时列出两个入口。当前 `init()` 不接受 config dir 参数, `run()` 也不接受。需明确选择一个入口点, 避免 API 歧义。建议在 `init()` 中传入 (与 netlink fd 初始化同级别)。

### 2. T19a: Battery Level Extraction

- [x] `src/core/state.zig` 中 `GamepadState` 无 `battery_level` 字段, `GamepadStateDelta` 也无 — design 正确识别缺失
- [x] `src/core/interpreter.zig` 的 `FieldTag` enum 无 `battery_level`, `parseFieldTag` 对 "battery_raw" 返回 `.unknown` — design 正确识别丢弃问题
- [x] design.md 的 `battery_level: u8 = 0` 类型选择 (u8) 与现有 `lt`/`rt` 字段类型一致
- [x] design.md 的 `applyFieldTag` 实现 `@intCast(val & 0xff)` 与现有 `lt`/`rt` 处理逻辑完全一致
- [x] `dualsense.toml` USB battery_raw 在 offset 53, BT 在 offset 54 (+1 BT header), design 的 bits DSL `[53, 0, 4]` / `[54, 0, 4]` 偏移正确
- [x] test-plan TP11-TP19 覆盖: applyDelta, diff, parseFieldTag, applyFieldTag, DualSense USB/BT 提取, 字段数量, bits DSL 参数

**发现 W3 (WARNING)**: design.md 决策 D6 选择 bits DSL 提取 battery level。但 `dualsense.toml` 中现有的 `touch0_contact` 和 `touch1_contact` 字段面临同样的子字节提取需求 (bit7=inactive, bits[6:0]=finger ID), 却仍使用 `type = "u8"`。如果 bits DSL 已实现, 为何 touch contact 字段未同步更新? 建议要么在本 wave 中一并更新 touch contact 字段, 要么明确说明 touch contact 的子字节提取属于其他 wave 的范围。

**发现 I2 (INFO)**: design.md Option B (传原始 u8, 下游自行 mask) 被否决, 选择 Option A (bits DSL)。这是正确的设计选择 — 在数据源头提取语义值, 而非在消费者端做位运算。

### 3. 文档间交叉引用

- [x] brief.md `refs` 路径与实际文件路径一致: `src/supervisor.zig`, `src/core/state.zig`, `devices/sony/dualsense.toml`
- [x] brief.md out-of-scope 明确排除 UPower/DBus (T19b 已删除, 违反 P5)
- [x] tasks.md 声明 T17/T19a 独立无依赖, 与 brief.md 一致
- [x] test-plan 的 regression guard (TP20-TP25) 覆盖所有被修改文件的现有测试

### 4. 与源码结构的一致性

- [x] `Supervisor` struct 的 field 布局 (allocator, managed, stop_fd, hup_fd, netlink_fd, configs, devname_map) 与 design 新增字段位置无冲突
- [x] `run()` 的 ppoll 循环结构 (pollfd array → ppoll → revents check) 与 design 扩展方案兼容
- [x] `GamepadState.diff()` 和 `applyDelta()` 的逐字段模式可机械扩展, 无结构性障碍

---

## 总结

| 级别 | 数量 | 说明 |
|------|------|------|
| ERROR | 0 | — |
| WARNING | 3 | W1: timerfd_settime 命名空间混用; W2: config dir 参数入口点未明确; W3: touch contact 字段未同步使用 bits DSL |
| INFO | 2 | I1: nfds 简化策略; I2: bits DSL vs 原始 u8 决策 |

**结论**: 无阻塞问题。W2 需在实现前确定 API 入口 (建议 `init()`)。W1 和 W3 不影响正确性, 可在实现时自然解决。

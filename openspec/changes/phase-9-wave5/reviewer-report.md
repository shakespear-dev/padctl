# Reviewer Report: Phase 9 Wave 5 — inotify Hot-Reload + Battery Extraction (T17/T19a)

## 审查范围

- `openspec/changes/phase-9-wave5/brief.md`
- `openspec/changes/phase-9-wave5/design.md`
- `openspec/changes/phase-9-wave5/tasks.md`
- `openspec/changes/phase-9-wave5/test-plan.md`
- `openspec/changes/phase-9-wave5/gardener-report.md`

## 原则合规性

### P5 — Single Static Binary

- **T17 (inotify)**: COMPLIANT。inotify 和 timerfd 均为 Linux 内核 syscall，零外部依赖。不引入任何动态库、不依赖外部服务。与现有 signalfd/netlink 使用模式完全一致。
- **T19a (battery)**: COMPLIANT。纯内部字段扩展，不引入任何外部依赖。明确排除 UPower/DBus (T19b 已删除，违反 P5)。

### P9 — All Modules Independently Testable

- **T17**: COMPLIANT。`initForTest` 设 `inotify_fd = -1` / `debounce_fd = -1` 禁用 inotify 路径，现有测试不受影响。inotify 专属测试使用临时目录 + 真实 kernel fd，属于 Layer 1（无需特权）。debounce 合并逻辑可通过 timerfd 直接验证，无需 mock。
- **T19a**: COMPLIANT。`GamepadState` 的 `diff()`/`applyDelta()` 扩展遵循现有逐字段模式，机械添加。`FieldTag` 的 `parseFieldTag`/`applyFieldTag` 可独立单元测试。bits DSL 提取已在 Wave 2 (T4) 实现并验证。所有新逻辑均可在 `zig build test` 中覆盖。

## 完整性评估

### brief.md

- [x] Why/Scope/Success Criteria/Out of Scope/References 齐全
- [x] 两个 task 独立无依赖，与 `planning/phase-9.md` Wave 5 描述一致
- [x] Out of Scope 明确排除: UPower/DBus、charging state、递归子目录监听、devices/ 目录监听

### design.md

- [x] T17: 现有 SIGHUP 机制分析、新字段、init/ppoll/事件流/debounce/测试性 完整覆盖
- [x] T17: IN_CLOSE_WRITE + IN_MOVED_TO 选择有充分论证 (排除 IN_MODIFY 避免部分写入触发)
- [x] T17: SIGHUP 向后兼容明确保留
- [x] T19a: 现状分析 (battery_raw → FieldTag.unknown → 丢弃) 准确
- [x] T19a: GamepadState/GamepadStateDelta/FieldTag 三处修改均有代码片段
- [x] T19a: bits DSL vs raw u8 两方案对比，选择 Option A (bits DSL) 合理
- [x] 8 个设计决策 (D1-D8) 均有 rationale

### tasks.md

- [x] T17a-T17d、T19a-a/b/c 步骤具体，代码片段可直接参考
- [x] T17b 的 nfds 计算考虑了四种 fd 组合，并正确简化为 "fd=-1 让 ppoll 忽略"
- [x] T19a 的三步（state → interpreter → TOML）顺序清晰，每步独立可验证

### test-plan.md

- [x] 25 个测试点覆盖: inotify 创建/降级/initForTest/写入触发/合并/re-arm/SIGHUP 共存/rename/ppoll (TP1-TP10)、battery applyDelta/diff/parseFieldTag/applyFieldTag/USB 提取/BT 提取/字段数/bits DSL (TP11-TP19)、回归 (TP20-TP25)
- [x] TP5 (debounce 合并) 和 TP6 (re-arm 重置) 针对 500ms 防抖的核心行为验证
- [x] TP16/TP17 使用具体的位操作场景 (0x38 → battery=8, 0x2A → battery=10)

### gardener-report.md

- [x] 0 ERROR、3 WARNING、2 INFO
- [x] W1 (timerfd_settime 命名空间): Zig std 中 timerfd API 确实位于 `linux` 而非 `posix` 命名空间，design.md 引用正确。代码风格混用是 Zig std 的现状，非 design 问题。非阻塞。
- [x] W2 (config dir 参数入口点): tasks.md T17d 同时列出 `init()` 和 `run()` 两个入口。gardener 建议 `init()` 合理（与 netlink fd 初始化同级别）。非阻塞，但实现前需确定。
- [x] W3 (touch contact 未同步 bits DSL): 合理观察，但 touch contact 的子字节提取属于触摸板功能完善范围，不在本 wave 范围内。非阻塞。

## 发现

**F1 (NON-BLOCKING)**: W2 指出 config dir 参数入口点未明确。建议采纳 gardener 建议，在 `Supervisor.init()` 中传入 config dir 路径，与 netlink fd 初始化保持同一层级。实现时自然解决。

## 判定

**PASS** — 无 BLOCKING 问题。P5/P9 合规，四份文档完整一致，测试覆盖充分。可进入实现。

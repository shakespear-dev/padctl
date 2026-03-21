# Reviewer Report: Phase 9 Wave 2 — bits DSL + Touchpad (T4/T5/T6/T7)

> Date: 2026-03-21 | Verdict: **PASS** | BLOCKING: 0

## Scope

Reviewed `brief.md`, `design.md`, `tasks.md`, `test-plan.md`, `gardener-report.md` against:
- `decisions/009-bits-dsl-syntax.md` (ADR-009)
- `design/principles.md` (P1–P9)

---

## Gardener Blocking Fix Verification

### B1: `bits_type` vs ADR-009 `type` 命名冲突

**已修复。** design.md 和 tasks.md 均使用 `type: ?[]const u8` 复用已有字段名，
与 ADR-009 的 `type = "unsigned" | "signed"` 语法一致。通过上下文语义区分：
`bits` 存在时 `type` 表示符号性，`bits` 不存在时 `type` 表示字节对齐类型标签。
设计决策 D8 明确记录了此选择。

### B2: `FieldConfig.offset`/`type` 可选化破坏性变更

**已修复。** 三处均已覆盖：
1. design.md §Config Validation 明确要求 `validate()` 对 `field.type` 做 null check，
   保护 `fieldTypeSize` 调用（原 line 192）
2. tasks.md T4b 列出了相同的 null check guard 步骤
3. test-plan.md 新增 TP-BWC 测试用例，验证现有 `offset + type` 字段在结构体
   改为 optional 后仍然正确解析

---

## Principle Compliance

| 原则 | 评估 | 备注 |
|------|------|------|
| P1 声明式优先 | 通过 | 12-bit 跨字节字段纯 TOML 声明，无需代码 |
| P2 通用协议引擎 | 通过 | `extractBits` 纯函数无设备特定逻辑；`touch0_active` 通过 `bits` DSL + `invert_bool` 变换实现，interpreter 不含设备名称或 if/switch |
| P3 渐进复杂度 | 通过 | `bits` 为可选语法，简单设备的 `offset + type` 路径不受影响；TP-BWC 验证向后兼容 |
| P5 单二进制 | 通过 | 无新外部依赖 |
| P6 设备/映射分离 | 通过 | 触摸板协议定义在 `devices/*.toml`，映射关注点（手势识别等）明确标记为 out of scope |
| P8 输出设备声明式 | 通过 | `[output.touchpad]` 所有参数（name/min/max/slots）在 TOML 中声明 |
| P9 独立可测试 | 通过 | `extractBits`/`signExtend` 纯函数 Layer 0 可测；`TouchpadOutputDevice` vtable 支持 mock 注入 Layer 1 测试 |

## ADR-009 Compliance

| ADR-009 要求 | OpenSpec 对应 | 状态 |
|-------------|-------------|------|
| `bits = [byte_offset, start_bit, bit_length]` 三元组 | design.md T4, tasks.md T4b | 一致 |
| LSB0 bit 编号 | design.md T4 Algorithm step 3 | 一致 |
| 最大 32 bits / 4 字节 | tasks.md T4a bit_count=32 边界处理，TP5 验证拒绝 >4 字节 | 一致 |
| Little-endian 字节组装 | design.md/tasks.md 读取算法 | 一致 |
| `type = "unsigned" \| "signed"` | D8 上下文依赖设计，TP17/TP18 验证 | 一致 |
| Config 验证规则 | design.md §Config Validation, TP11-TP18 | 一致 |
| `extractBits` 纯函数签名 | design.md/tasks.md 签名完全匹配 ADR-009 §6 | 一致 |

---

## Completeness

### Brief
- 动机清晰：12-bit 跨字节字段的 P3 违规驱动
- 范围边界明确：Steam Deck TOML 在 scope 内，DualSense TOML 明确 out of scope
- 成功标准可测量，与 test-plan 一一对应

### Design
- 四个任务（T4/T5/T6/T7）层次分明，依赖关系正确
- 关键设计决策（D1-D9）有理有据，均引用原则或 ADR 支撑
- D9（`invert_bool` 变换）解决了 gardener W5 标记的 `negate` 语义错误

### Tasks
- 子步骤粒度适当，每步有代码示例可直接实现
- 依赖链 T4→T5→T6→T7 合理
- T6b 明确标注需新增 `UI_SET_PROPBIT` 到 `ioctl_constants.zig`（gardener W2 已在任务中体现）
- T7b 明确说明 `button_group.map` 中无 L3_touch/R3_touch，无需删除（gardener W3 已修复）

### Test Plan
- 34 个测试点覆盖：extractBits 边界（TP1-TP10）、config 验证（TP11-TP18, TP-BWC）、
  interpreter 集成（TP19-TP23）、state diff/apply（TP24-TP26）、
  端到端管线（TP27-TP29）、回归防护（TP30-TP32）、手动测试（TP33-TP34）
- TP5 已移至 config 验证区作为 bounds check 测试（gardener W4 已修复）

---

## Feasibility

- `extractBits` 算法直接，边界用例可穷举，实现风险低
- `FieldConfig` optional 化是一次性迁移，TP-BWC 降低回归风险
- 触摸板 uinput 设备使用标准 Linux multitouch protocol（Type B），无定制化
- Steam Deck TOML 变更最小（重命名 + 2 个 bits 字段 + output section）

## Gardener Warnings (Non-blocking) Status

| Warning | 状态 | 说明 |
|---------|------|------|
| W1: CompiledField tagged union vs flat | 已修复 | design.md 和 tasks.md 统一为 flat fields + mode enum |
| W2: UI_SET_PROPBIT 缺失 | 已修复 | tasks.md T6b 明确列出添加步骤 |
| W3: L3_touch button_group 不存在 | 已修复 | tasks.md T7b 明确标注无需删除 |
| W4: TP5 测试分类 | 已修复 | TP5 移至 config 验证区，描述为 bounds check 拒绝测试 |
| W5: negate 语义错误 | 已修复 | D9 新增 `invert_bool` 变换，out-of-scope DualSense 示例已更新 |

---

## Observations (Non-blocking)

### O1: `invert_bool` 变换需要在 interpreter 中实现

design.md D9 定义了 `invert_bool` 变换（1->0, 0->1），但 tasks.md 未包含
实现此变换的子任务。当前 Wave 2 scope 中 Steam Deck `touch0_active` 不需要此变换
（bit=1 直接表示 active），仅 DualSense（out of scope）需要。

建议：在后续 DualSense 触摸板 Wave 中实现 `invert_bool`，或在 T4 中预留（影响极小，
一行 switch case）。不阻塞本 Wave。

### O2: `signExtend` bit_count=32 边界

当 `bit_count=32` 时，`signExtend` 中 `32 - bit_count = 0`，shift 量为 0，
函数退化为 `@bitCast(val)`。这是正确行为（32-bit 值无需符号扩展），但建议在
TP6/TP7 附近增加一个 `bit_count=32` 的 signExtend 测试用例以明确覆盖此边界。

---

## Verdict

**PASS** — 0 BLOCKING issues.

Gardener B1/B2 均已在 design.md、tasks.md、test-plan.md 中修复。
五个 WARNING 全部已修复。
设计与 ADR-009 一致，符合 P1/P2/P3/P5/P6/P8/P9 原则，
测试覆盖完整，实现可行性高。可进入实现阶段。

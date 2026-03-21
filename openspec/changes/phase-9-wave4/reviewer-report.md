# Reviewer Report: Phase 9 Wave 4 — BT Device Expansion (T11/T12/T13)

## 审查范围

- `openspec/changes/phase-9-wave4/brief.md`
- `openspec/changes/phase-9-wave4/design.md`
- `openspec/changes/phase-9-wave4/tasks.md`
- `openspec/changes/phase-9-wave4/test-plan.md`
- `openspec/changes/phase-9-wave4/gardener-report.md`

## 原则合规性

### P1 — Declarative First

- **T11 (DualSense BT init)**: COMPLIANT。BT 模式激活通过 `[device.init]` DSL 声明式实现，一次性 fire-and-forget 写入，无需 WASM。design.md 正确分析了有状态 vs 声明式的区别，最终选择 USB 格式 output report (Report ID 0x02) 绕开 CRC32 依赖。零代码改动，纯 TOML 配置。
- **T12 (DualShock 4)**: COMPLIANT。新设备 = 新 `.toml` 文件，核心 P1 承诺的完美体现。v1/v2 通过独立 TOML 文件支持，无代码改动。
- **T13 (Switch Pro WASM)**: COMPLIANT (via P7)。子命令协议的四个特征（递增 counter、request-response、SPI flash 校准读取、HD Rumble 编码）均需运行时状态，无法用 TOML 表达。TOML 保留 `[device]`/`[[report]]`/`[output]` 用于设备匹配和 uinput 创建，只有 report 解释权委托给 WASM。职责分离清晰。

### P7 — WASM Escape Hatch

- **T13**: COMPLIANT。design.md 详细论证了为何 Switch Pro 属于 P7 逃生舱用例，三钩子 ABI (`init_device`/`process_calibration`/`process_report`) 与 `decisions/005-wasm-plugin-runtime.md` 完全对齐。TOML 中 `[wasm.overrides] process_report = true` 使 WASM 接管 report 解释，同时保留 TOML 字段声明作为 fallback。
- **T11/T12**: 不涉及 WASM，无合规性问题。

## 完整性评估

### brief.md

- [x] Why/Scope/Success Criteria/Out of Scope/References 齐全
- [x] 三个 task 的范围划分清晰，依赖关系正确 (T11/T12 并行，T13 依赖 T1)
- [x] Out of Scope 合理排除了 BT 输出 CRC32、NFC/IR、12-bit stick 等

### design.md

- [x] T11 的有状态/声明式分析完整，最终决策 D1/D2 有充分论证
- [x] T12 的协议表、TOML 设计、BT init、output/commands 完整
- [x] T13 的 WASM 必要性论证、三钩子设计、TOML/WASM 职责划分清晰
- [x] 7 个设计决策 (D1-D7) 均有 rationale
- [x] DS4 v2 支持方案明确 (独立 TOML)

### tasks.md

- [x] T11a/T11b、T12a-T12c、T13a-T13c 步骤具体可执行
- [x] 代码片段完整，可直接作为实现参考
- [x] Post-merge wrap-up 包含归档和 roadmap 更新

### test-plan.md

- [x] 28 个测试点覆盖: init 解析/发送/重试/超时 (TP1-TP4)、DS4 解析/字段/校验和 (TP5-TP13)、WASM 配置/packet counter/init 序列/校准 (TP14-TP20)、集成 (TP21-TP22)、回归 (TP23-TP28)
- [x] 测试粒度适当，每个 test point 有明确的输入和预期输出

### gardener-report.md

- [x] 0 ERROR、3 WARNING、3 INFO
- [x] W1 (init.zig read_buf 64B vs 78B): 功能不受影响，prefix 检查只需 byte 0。非阻塞。
- [x] W2 (协议表 button size 标注 4 vs 3): 文档表述问题，button_group source size=3 是正确的实现。非阻塞。
- [x] W3 (Switch Pro D-Pad bit vs hat 转换): WASM `process_report` 接管后 TOML 的 button_group 仅作 fallback，fallback 模式下转换由引擎处理。非阻塞，但建议实现时确认。

## 发现

无新发现。Gardener report 的 3 个 WARNING 均已审阅，确认非阻塞。

## 判定

**PASS** — 无 BLOCKING 问题。P1/P7 合规，四份文档完整一致，测试覆盖充分。可进入实现。

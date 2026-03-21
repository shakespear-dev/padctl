# Gardener Report: Phase 9 Wave 4 — BT Device Expansion (T11/T12/T13)

## 审查范围

- `openspec/changes/phase-9-wave4/brief.md`
- `openspec/changes/phase-9-wave4/design.md`
- `openspec/changes/phase-9-wave4/tasks.md`
- `openspec/changes/phase-9-wave4/test-plan.md`
- 交叉校验: `src/init.zig`, `devices/sony/dualsense.toml`, `src/wasm/runtime.zig`

---

## 一致性检查

### 1. T11: DualSense BT Init

- [x] design.md 的 `[device.init]` enable 字段 (Report ID 0x02, 63 字节) 与 tasks.md T11a 一致
- [x] `response_prefix = [0x31]` 与现有 `dualsense.toml` BT report match `[0x31]` 一致
- [x] `src/init.zig` 的 `runInitSequence` 逻辑正确处理 `commands = []` + `enable` 组合: 跳过空 commands, 发送 enable, 等待 prefix 匹配
- [x] test-plan TP1-TP4 覆盖 init 解析、发送、重试、超时四个场景

**发现 W1 (WARNING)**: `sendAndWaitPrefix` 的 `read_buf` 仅 64 字节, 但 DualSense BT extended report 为 78 字节。prefix 检查只需 byte 0 (`0x31`), 所以功能不受影响, 但 read 会截断。建议在 init.zig 中将 read_buf 增大到至少 128 字节, 或在 brief.md 中注明此限制。

**发现 I1 (INFO)**: design.md 提到"CRC32 placeholder — the engine's output CRC32 support must fill this"用于 BT 格式 init, 但最终决策 D1 已选择 USB 格式绕过 CRC32, 二者一致。首选方案的描述可视为设计推导过程记录。

### 2. T12: DualShock 4

- [x] design.md 的 USB 和 BT field offsets 与协议文档一致 (USB sticks 1-4, BT sticks 3-6, 差值 +2)
- [x] BT checksum config (`algo="crc32"`, `range=[0,74]`, `seed=0xa1`, `expect.offset=74`) 与 dualsense.toml BT checksum 格式结构一致
- [x] button_group map 的 bit 索引与注释中的 byte 布局对应: byte 5 bits 4-7 = X(4) A(5) B(6) Y(7), byte 6 bits 0-7 = LB(8) RB(9)...
- [x] tasks.md T12a-T12c 步骤完整覆盖 v1 + v2 创建
- [x] test-plan TP5-TP13 覆盖解析、fields、offsets、checksum、commands、output

**发现 W2 (WARNING)**: design.md 协议表中 buttons 标注在 `offset 5, size 4`, 但 button_group 只取 `source = { offset = 5, size = 3 }` (3 字节)。DS4 button 跨 3 字节 (bytes 5-7), 这是正确的。但协议表标记 "size = 4" 可能误导, 建议修正为 "size = 3" 或 "3 bytes"。

**发现 I2 (INFO)**: DS4 的 `[device.init]` enable 命令 `"05 ff 00..."` 使用 Report ID 0x05 (32 字节)。与 DualSense 的 Report ID 0x02 (63 字节) 模式一致但格式不同, 合理。

### 3. T13: Switch Pro WASM

- [x] design.md 的 WASM 三钩子 ABI (`init_device`, `process_calibration`, `process_report`) 与 `src/wasm/runtime.zig` 的 VTable 定义完全匹配
- [x] design.md 的 `[wasm.overrides] process_report = true` 与 `dualsense.toml` 已有的 WASM 配置模式一致
- [x] 现有 `switch-pro.toml` 的 raw u8 axes (0-255) 将升级为 calibrated axes (-32768..32767), tasks.md T13a 中有明确说明
- [x] test-plan TP14-TP20 覆盖 WASM config 解析、packet counter、init 序列、stick 校准、12-bit 提取

**发现 W3 (WARNING)**: 现有 `switch-pro.toml` 的 D-Pad 使用独立 bit 映射 (`DPadDown=16, DPadUp=17, DPadRight=18, DPadLeft=19`), 不是 hat 编码。但 `[output.dpad]` 声明 `type = "hat"`。design.md 未提及这一差异的处理方式 — 独立 D-Pad bit 转 hat 输出需要中间层转换逻辑。如果 WASM `process_report` 全权接管, 则 TOML 中的 button_group D-Pad 定义仅作 fallback, 但 fallback 模式下 bit -> hat 转换是否由引擎处理需要确认。

**发现 I3 (INFO)**: tasks.md T13b 的 WASM 插件源码用 C 编写 (`clang --target=wasm32`), 而非 Zig。这是合理的 (WASM 工具链更成熟), 但值得注意项目有两种语言。

### 4. 文档间交叉引用

- [x] brief.md `refs` 路径与实际文件路径一致: `src/init.zig`, `devices/sony/dualsense.toml`, `devices/nintendo/switch-pro.toml`
- [x] brief.md 的 out-of-scope 清单与 design.md 的范围一致 (no touchpad, no 12-bit sticks in TOML, no NFC/IR)
- [x] tasks.md 的依赖声明 (T11/T12 parallel, T13 depends on T1) 与 brief.md 一致

---

## 总结

| 级别 | 数量 | 说明 |
|------|------|------|
| ERROR | 0 | — |
| WARNING | 3 | W1: init.zig read_buf 64B vs 78B report; W2: 协议表 button size 标注; W3: Switch Pro D-Pad bit vs hat 转换 |
| INFO | 3 | I1: 设计推导保留; I2: DS4 init 格式差异; I3: WASM 用 C |

**结论**: 无阻塞问题。三个 WARNING 均不影响功能正确性 (W1 仅影响 init 阶段 read 截断但 prefix 检查仍有效; W2 是文档表述; W3 需在实现时确认), 建议在实现前修正。

<p align="center"><img src="docs/logo.svg" alt="SenWeave" width="104"></p>

# SenWeave · 感织

面向 MoonBit 物联网应用的 SenML 测量数据语义与 JSON／CBOR 交换库。

**当前阶段：SenML JSON 解析与字段校验，版本 `0.1.0-dev.2`。** 提供带资源上限的 JSON 解析器、类型化原始记录、四种测量值、数字原文保留和结构化错误。完整基准／时间解算、CBOR 编解码和网络集成仍在开发；尚未发布到 Mooncakes。

SenML 数据包里的测量记录可以继承此前出现的设备名称、基准时间、单位和基准数值。记录从原数据包取出前，需要先应用这些信息，才能安全地独立保存或筛选。项目依据 [RFC 8428](https://www.rfc-editor.org/rfc/rfc8428.html)，为设备网关、采集服务和离线工具提供这层共享能力。

## 从源码运行

安装 [MoonBit 官方工具链](https://www.moonbitlang.com/download/)，JS 与 wasm-gc 目标需要可用的 JavaScript 运行时，native 目标需要平台 C 工具链。

当前代码使用 `Int32` 命名，开发验证工具链为 `moon 0.1.20261023`、`moonc v0.10.17+d971670cd`。请使用这一版或更新的兼容工具链；CI 使用官方 latest 通道，并在日志中记录实际版本。

```sh
moon check --target js --deny-warn
moon test --target js
moon run examples/labels --target js
moon run examples/json --target js
```

`examples/labels` 展示标准标签映射。`examples/json` 解析包含基准设置、数值、布尔与二进制值的数据包，输出 `raw records: 4, measurements: 3`，保留 `22.50` 的数字原文，并演示拒绝未知强制扩展。

CI 针对 Windows、Linux 和 `native`、`js`、`wasm-gc` 三个后端运行相同测试与示例。

## 已有接口

- `parse_json(input, limits?)`：返回 `Pack`，失败抛出带诊断的 `SenmlError`。
- `Pack::len()`、`record(index)`、`measurement_count()`：读取原始记录和测量数量；越界索引返回 `None`。
- `MeasurementValue`：区分数值、文本、布尔和二进制值；零、`false`、空文本和空二进制会保留。
- `Number::json_literal()`：读取原始数字文本；`as_double()` 提供可能舍入的 binary64 近似值。
- `SenmlError::diagnostic()`：读取错误类别、记录索引、字段及可用的 JSON 行列位置。
- `ParseLimits::default()`：提供输入大小、记录数、嵌套深度、字段数和字符串／数字长度上限。
- `Label::from_json_name(name)`：识别区分大小写的标准 JSON 标签。
- `Label::from_cbor_key(key)`：识别标准整数 CBOR 标签。
- `Label::json_name()` 与 `Label::cbor_key()`：获取同一标签的两种表示。

标签查找对未知名称返回 `None`。JSON 解析器按 RFC 8428 忽略普通未知扩展，拒绝名称以 `_` 结尾的未知扩展。解析支持版本 10，并拒绝重复的解码后成员名称。详细边界与默认上限见 [JSON 输入约定](docs/json-profile.md)。

**返回记录保留原始基准字段，时间、单位和基准数值尚未解算。** 直接取出的记录仍可能依赖前文；完整记录输出将在下一阶段实现。普通未知扩展会被丢弃，当前接口用于读取和校验，暂不提供保留扩展的转码功能。

## 下一步实现

1. 实现基准字段继承、相对时间解算和完整记录输出，参考时刻由调用方显式提供。
2. 评估并复用现有 CBOR 包，验证整数键、二进制值和数值边界，完成 JSON／CBOR 转换。
3. 对照 RFC 示例与外部实现验证语义，提供网关消费示例和离线检查工具。
4. 正式发布 Mooncakes 包，在独立消费项目中验证注册表安装与使用。

首版范围为 RFC 8428 的 SenML JSON／CBOR 数据包。XML、EXI、SenSML 无限流和单位换算不在首版范围内。

## 架构与生态

![当前实现与计划架构](docs/architecture.svg)

核心以 MoonBit 实现，接口接收内存数据。文件、时钟、网络和界面由消费项目提供。现有 [CBOR](https://mooncakes.io/docs/2515050242/cbor)、[MQTT](https://mooncakes.io/docs/Strangelight-Merser/moon-mqtt-client) 和 [CoAP](https://mooncakes.io/docs/sujy123456/mooncoap) 包是拟集成的上下游；当前尚无第三方运行时依赖或已完成的集成。

检索记录与实现决策见 [开发记录](docs/development.md)。

## 许可

[Apache-2.0](LICENSE)。标准行为以 RFC 8428 为准；互操作验证计划参考 [absmach/senml](https://github.com/absmach/senml) 和 [KPN Python SenML](https://github.com/kpn-iot/senml-python-library)。当前实现未复制这些项目的源代码。

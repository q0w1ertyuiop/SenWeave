<p align="center"><img src="docs/logo.svg" alt="SenWeave" width="104"></p>

# SenWeave · 感织

面向 MoonBit 物联网应用的 SenML 测量数据语义与 JSON／CBOR 交换库。

**当前阶段：仓库初始化，版本 `0.1.0-dev.1`。** 已实现 RFC 8428 的 15 个标准标签及 JSON 名称／CBOR 整数键的双向映射。完整数据包解析、语义解算、数据转换和网络集成尚在开发计划中；尚未发布到 Mooncakes。

SenML 数据包里的测量记录可以继承此前出现的设备名称、基准时间、单位和基准数值。记录从原数据包取出前，需要先应用这些信息，才能安全地独立保存或筛选。项目依据 [RFC 8428](https://www.rfc-editor.org/rfc/rfc8428.html)，为设备网关、采集服务和离线工具提供这层共享能力。

## 从源码运行

安装 [MoonBit 官方工具链](https://www.moonbitlang.com/download/)，JS 与 wasm-gc 目标需要可用的 JavaScript 运行时，native 目标需要平台 C 工具链。

```sh
moon check --target js --deny-warn
moon test --target js
moon run examples/labels --target js
```

示例输出包括 `bn -> CBOR key -2` 和 `vd -> CBOR key 8`。它只展示标准标签映射，不解析测量数据包。

CI 针对 Windows、Linux 和 `native`、`js`、`wasm-gc` 三个后端运行相同测试与示例。

## 已有接口

- `Label::from_json_name(name)`：识别区分大小写的标准 JSON 标签。
- `Label::from_cbor_key(key)`：识别标准整数 CBOR 标签。
- `Label::json_name()` 与 `Label::cbor_key()`：获取同一标签的两种表示。

未知名称和扩展标签返回 `None`。这个结果只表示不属于基础标签表；完整扩展接受策略将由后续数据包解析器处理。

## 下一步实现

1. 建立测量值、记录、数据包和结构化诊断模型；实现 SenML JSON 解析与校验。
2. 实现基准字段继承、相对时间解算和完整记录输出，参考时刻由调用方显式提供。
3. 评估并复用现有 CBOR 包，验证整数键、二进制值和数值边界，完成 JSON／CBOR 转换。
4. 对照 RFC 示例与外部实现验证语义，提供网关消费示例和离线检查工具。
5. 正式发布 Mooncakes 包，在独立消费项目中验证注册表安装与使用。

首版范围为 RFC 8428 的 SenML JSON／CBOR 数据包。XML、EXI、SenSML 无限流和单位换算不在首版范围内。

## 架构与生态

![当前实现与计划架构](docs/architecture.svg)

核心以 MoonBit 实现，接口接收内存数据。文件、时钟、网络和界面由消费项目提供。现有 [CBOR](https://mooncakes.io/docs/2515050242/cbor)、[MQTT](https://mooncakes.io/docs/Strangelight-Merser/moon-mqtt-client) 和 [CoAP](https://mooncakes.io/docs/sujy123456/mooncoap) 包是拟集成的上下游；当前尚无第三方运行时依赖或已完成的集成。

检索记录与实现决策见 [开发记录](docs/development.md)。

## 许可

[Apache-2.0](LICENSE)。标准行为以 RFC 8428 为准；互操作验证计划参考 [absmach/senml](https://github.com/absmach/senml) 和 [KPN Python SenML](https://github.com/kpn-iot/senml-python-library)。当前实现未复制这些项目的源代码。

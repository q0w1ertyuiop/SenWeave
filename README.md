<p align="center"><img src="docs/logo.svg" alt="SenWeave" width="104"></p>

# SenWeave · 感织

面向 MoonBit 物联网应用的 SenML 测量数据语义与 JSON／CBOR 交换库。

**当前阶段：SenML JSON／CBOR 库、离线工具与 CoAP 采集适配器，版本 `0.1.0-dev.7`。** 支持带资源上限的字节解析、基字段展开、筛选、独立记录输出，以及文件／管道检查和转换。CoAP 支持延迟到宿主存储完成后应答，已通过本机 UDP、SQLite 事务及 aiocoap 客户端验证；Mooncakes 正式发布和 MQTT 集成尚未完成。

SenML 数据包里的测量记录可以继承此前出现的设备名称、基准时间、单位和基准数值。记录从原数据包取出前，需要先应用这些信息，才能安全地独立保存或筛选。项目依据 [RFC 8428](https://www.rfc-editor.org/rfc/rfc8428.html)，为设备网关、采集服务和离线工具提供这层共享能力。

## 从源码运行

安装 [MoonBit 官方工具链](https://www.moonbitlang.com/download/)，JS 与 wasm-gc 目标需要可用的 JavaScript 运行时，native 目标需要平台 C 工具链。

当前代码使用 `Int32` 命名，开发验证工具链为 `moon 0.1.20261023`、`moonc v0.10.17+d971670cd`。请使用这一版或更新的兼容工具链；CI 使用官方 latest 通道，并在日志中记录实际版本。

```sh
moon update
moon check --target js --deny-warn
moon test --target js
moon run examples/labels --target js
moon run examples/json --target js
moon run examples/gateway --target js
moon run examples/cbor --target js
```

`examples/labels` 展示标准标签映射。`examples/json` 解析包含基准设置、数值、布尔与二进制值的数据包，输出 `raw records: 4, measurements: 3`，保留 `22.50` 的数字原文，并演示拒绝未知强制扩展。

`examples/gateway` 把 4 条原始记录展开为测量，筛选并按时间输出 2 条温度记录，分别为 `23` 和 `22.5`，随后逐条独立重读。调用方提供接收时刻，核心库不读取系统时钟。

`examples/cbor` 输出原始包与展开包的 CBOR 十六进制，以及展开后的 JSON。可通过 `-- --hex <十六进制>` 传入外部 CBOR 数据。

CI 针对 Windows、Linux 和 `native`、`js`、`wasm-gc` 三个后端运行相同测试与示例，另设两平台 CLI／UDP 检查与 Python 互操作任务。测试范围与复现命令见 [离线工具](docs/cli.md)、[传输接入](docs/transport.md) 和 [互操作范围](docs/interoperability.md)。

## 检查实际数据文件

CLI 使用 Node.js 24 及以上作为文件与管道宿主，语义处理仍由编译后的 MoonBit 库完成。先在仓库根目录构建：

```sh
moon build cmd/bridge --target js --release
node bin/senweave.mjs check examples/data/gateway.json --now 1793000000
node bin/senweave.mjs resolve examples/data/gateway.json --now 1793000000 --name urn:dev:gateway:demo:temperature
node bin/senweave.mjs resolve examples/data/gateway.json --now 1793000000 --to cbor --output measurements.cbor
```

`check` 验证完整展开过程，包含缺失参考时刻和数值溢出；`resolve` 输出按时间排列的独立测量。文件输出拒绝覆盖已有文件，未通过校验时不创建输出。默认从标准输入读取，也可用 `--from cbor` 读取二进制包。详细参数、退出码和输入边界见 [CLI 说明](docs/cli.md)。

## 已有接口

- `parse_json(input, limits?)`：返回 `Pack`，失败抛出带诊断的 `SenmlError`。
- `parse_cbor(input, limits?, max_input_bytes?)`：把确定长度的 CBOR 数据包读入同一个 `Pack`，复用字段校验与展开逻辑。
- `parse_payload(bytes, format, limits?, max_input_bytes?, reject_extensions?)`：共用的传输字节入口，JSON 严格检查 UTF-8，解码前检查字节上限，可拒绝普通未知扩展。
- `Format`：提供 SenML JSON／CBOR 的媒体类型与 CoAP Content-Format 映射；不将 SenSML 流误认成有限包。
- `Pack::len()`、`record(index)`、`measurement_count()`、`ignored_extension_count()`：读取原始记录、测量和丢弃扩展数量；越界索引返回 `None`。
- `Pack::resolve(reference_time?, max_expanded_code_units?)`：应用名称、单位、时间、数值与和的基字段，返回按时间排序的 `ResolvedPack`；相对时间需要显式参考时刻。
- `ResolvedPack::filter(predicate)`、`record(index)`、`len()`：筛选和读取独立测量；等时记录保留输入顺序，`source_index` 指向原始记录。
- `ResolvedPack::to_json_string()`、`ResolvedRecord::to_json_string()`：输出完整数据包或单条测量组成的数组，可独立保存和转发。
- `Pack::to_cbor_bytes()`、`ResolvedPack::to_cbor_bytes()`、`ResolvedRecord::to_cbor_bytes()`：输出原始上下文包或独立测量；可设置 `max_output_bytes`。
- `MeasurementValue`：区分数值、文本、布尔和二进制值；零、`false`、空文本和空二进制会保留。
- `Number::json_literal()`：读取原始数字文本；`as_double()` 提供可能舍入的 binary64 近似值。
- `SenmlError::diagnostic()`：读取错误类别、记录索引、字段及可用的 JSON 行列位置。
- `ParseLimits::default()`：提供输入大小、记录数、嵌套深度、字段数和字符串／数字长度上限。
- `Label::from_json_name(name)`：识别区分大小写的标准 JSON 标签。
- `Label::from_cbor_key(key)`：识别标准整数 CBOR 标签。
- `Label::json_name()` 与 `Label::cbor_key()`：获取同一标签的两种表示。

标签查找对未知名称返回 `None`。JSON 解析器按 RFC 8428 忽略普通未知扩展，拒绝名称以 `_` 结尾的未知扩展。解析支持版本 10，并拒绝重复的解码后成员名称。详细边界与默认上限见 [JSON 输入约定](docs/json-profile.md)。

**`parse_json` 返回原始记录；独立取出或筛选测量前，应先调用 `resolve`。** 展开会保留原包，消除基字段并生成绝对时间；仅有基字段的上下文记录不输出。普通未知扩展会被丢弃，输出不保留扩展。

展开算术采用 binary64，可能舍入；没有加法或加零时保留数值原文。溢出、缺失相对时钟和不可表示的绝对时间会失败，展开体积默认采用 4 Mi UTF-16 单元的保守上限。使用示例、时间与数值边界见 [展开和输出约定](docs/resolution.md)。

CBOR 使用标准整数标签和原生字节串，数字支持整数、浮点与输入 Tag 4。编码保留可表示的普通 64 位整数字面量，其余数字采用 binary64；JSON 的十进制原文在跨格式输出后会改变。输入类型、确定长度及数值边界见 [CBOR 约定](docs/cbor-profile.md)。

## 接收 CoAP 测量

`integrations/coap` 接收 `POST /ingest`，只支持 Content-Format `110`（SenML JSON）和 `112`（SenML CBOR）。协议层复用 MoonCoAP；适配器解析并展开测量，返回待发送报文和验收事件。相同对端的重复报文在交换生存期内重发缓存响应，不重复输出测量。

```sh
moon build cmd/coapbridge --target js --release
node examples/coap/collector.mjs --port 0 --duration-ms 10000
```

示例绑定 `127.0.0.1` 的临时 UDP 端口，启动行显示端口号，10 秒后退出。单调毫秒用于 CoAP 超时，接收时的 POSIX 秒用于相对测量时间。`Accepted` 表示解析与展开通过，持久化由调用方完成。接口、8 KiB 负载上限、去重范围和独立客户端复现见 [传输接入](docs/transport.md)。

需要落库后再确认时，使用 `Collector::new(deferred=true)`。`Pending` 事件给出绑定当前采集器的 `Delivery`，宿主提交存储后调用 `finish(stored=true, monotonic_ms)`；失败则传入 `false`。待处理最多 16 项，30 秒超时，重复或过期句柄不会生成成功响应。

```sh
node examples/coap/collector.mjs --port 0 --duration-ms 10000 --store measurements.sqlite
```

`--store` 使用 Node.js 内置 SQLite 保存独立测量文本，事务提交后才返回 `2.04`，锁冲突或配额失败返回 `5.00`。现有非 SenWeave 数据库会被拒绝。数据库配置和跨重启去重边界见 [存储后应答说明](docs/transport.md#存储后应答)。

## 下一步实现

1. 验证 MQTT 消费接入与更多外部 SenML 实现，扩充真实设备输入。
2. 正式发布 Mooncakes 包，在独立消费项目中验证注册表安装与使用。

首版范围为 RFC 8428 的 SenML JSON／CBOR 数据包。XML、EXI、SenSML 无限流和单位换算不在首版范围内。

## 架构与生态

![当前实现与计划架构](docs/architecture.svg)

核心以 MoonBit 实现，接口接收内存数据。文件、时钟、网络和界面由消费项目提供。CBOR 编解码固定复用 [2515050242/cbor@0.1.2](https://mooncakes.io/docs/2515050242/cbor@0.1.2)，CoAP 子包固定复用 [sujy123456/mooncoap@0.1.1](https://mooncakes.io/docs/sujy123456/mooncoap@0.1.1) 的内存协议核心；根包不导入网络驱动。模块依赖解析包含 MoonCoAP 的传递依赖，宿主示例的 UDP 使用 Node.js。现有 [MQTT 包](https://mooncakes.io/docs/Strangelight-Merser/moon-mqtt-client) 留待后续接入。

检索记录与实现决策见 [开发记录](docs/development.md)。

## 许可

[Apache-2.0](LICENSE)。标准行为以 RFC 8428 为准；[KPN Python SenML](https://github.com/kpn-iot/senml-python-library) 的测试版本、已通过流程和已知差异见 [互操作范围](docs/interoperability.md)。[absmach/senml](https://github.com/absmach/senml) 已阅读实现，尚未运行对照。当前实现未复制这些项目的源代码。

<p align="center"><img src="docs/logo.svg" alt="SenWeave" width="104"></p>

# SenWeave · 感织

面向 MoonBit 的 SenML 解析、语义展开与互操作库。

**当前阶段：SenML JSON／CBOR／XML 库、Node.js SDK、离线工具与 CoAP 收发适配器，版本 `0.1.0-dev.16`。** 支持带资源上限的解析、基字段展开、独立记录输出及存储后应答。业务键可识别跨重启重试并拒绝负载冲突。npm 本地压缩包已通过独立运行与 TypeScript 消费验证，MoonBit 源码归档已通过三个后端的独立模块验证；注册表正式发布和 MQTT 集成尚未完成。

SenML 数据包里的测量记录可以继承此前出现的设备名称、基准时间、单位和基准数值。记录从原数据包取出前，需要先应用这些信息，才能安全地独立保存或筛选。项目依据 [RFC 8428](https://www.rfc-editor.org/rfc/rfc8428.html)，为设备网关、采集服务和离线工具提供这层共享能力。

项目目标与交付计划见 [项目申报书](docs/proposal.md)，当前状态见 [标准覆盖表](docs/senml-support.md) 和 [参考实现比较](docs/comparison.md)。

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

CI 针对 Windows、Linux 和 `native`、`js`、`wasm-gc` 三个后端运行相同测试与示例，另设两平台 CLI／UDP、分发、Python 互操作与 Go／Python 共同样本任务。

固定版本的跨语言对照已运行 55 组、133 项 JSON／CBOR／XML 用例，分别核对解码校验、原始编码、展开和数值表示。完整输入、实际输出与差异分类由脚本生成，CI 保存结果 artifact。测试范围与命令见 [参考实现比较](docs/comparison.md)、[离线工具](docs/cli.md)、[传输接入](docs/transport.md) 和 [互操作范围](docs/interoperability.md)。

## 在 Node.js 应用中调用

从源码构建后可通过 ESM 或 CommonJS 调用，输入使用 JSON／XML 原文或字节，测量数字不先转成 JavaScript `Number`：

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
npm run test:sdk
npm run verify:package
```

```js
import { check, resolve } from './js/index.mjs';

const input = '[{"bn":"sensor:","bt":1793000000},{"n":"counter","v":9007199254740993}]';
const summary = check(input);
const cbor = resolve(input, { to: 'cbor' });
const json = resolve(cbor.data, { from: 'cbor' });
console.log(summary.measurements, json.data);
```

`check` 验证完整展开，`resolve` 返回 JSON／XML 文本或 CBOR 字节及扩展丢弃数量。`SenWeaveError` 提供固定诊断；相对时间需要显式 `referenceTime`。SDK 随本地 `.tgz` 携带编译后的 MoonBit 核心，消费项目只需 Node.js，无额外 npm 运行时依赖。接口、类型和边界见 [SDK 说明](docs/js-sdk.md)，两种归档的消费检查见 [分发验证](docs/distribution.md)。

CommonJS 应用可用 `const { check, resolve } = require('@q0w1ertyuiop/senweave')` 加载已安装分发包；两种入口共享函数和错误类型。

应用可用 `limits: { maxInputBytes: 8192, maxRecords: 16 }` 收紧单次调用预算，并设置展开和输出上限。`rejectExtensions: true` 在展开前拒绝扩展丢弃；错误诊断只保留标准字段名，避免把应用扩展名称写入日志。

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
- `parse_xml(input, limits?)`：按命名空间读取 SenML XML 的基础属性和 `ct`／`bct`，复用共享校验和展开；词法、实体和字符边界见 [XML 约定](docs/xml-profile.md)。
- `parse_payload(bytes, format, limits?, max_input_bytes?, reject_extensions?)`：共用的传输字节入口，JSON／XML 严格检查 UTF-8，解码前检查字节上限，可拒绝普通未知扩展。
- `Format`：提供 SenML JSON／CBOR／XML 的媒体类型与 CoAP Content-Format 映射；不将 SenSML 流误认成有限包。
- `Pack::to_json_string(max_output_code_units?)`：输出原始 JSON 包，保留顺序、基字段、相对时间和数字文本；无需参考时刻，默认使用 4 Mi UTF-16 单元的保守预算。
- `Pack::to_xml_string()`、`ResolvedPack::to_xml_string()`、`ResolvedRecord::to_xml_string()`：输出原始上下文包或独立测量，使用保守代码单元预算并拒绝 XML 1.0 无法表示的字符。
- `Pack::len()`、`record(index)`、`measurement_count()`、`ignored_extension_count()`：读取原始记录、测量和丢弃扩展数量；越界索引返回 `None`。
- `Pack::resolve(reference_time?, max_expanded_code_units?)`：应用名称、单位、时间、数值与和的基字段，返回按时间排序的 `ResolvedPack`；相对时间需要显式参考时刻。
- `ResolvedPack::filter(predicate)`、`record(index)`、`len()`：筛选和读取独立测量；等时记录保留输入顺序，`source_index` 指向原始记录。
- `ResolvedPack::to_json_string()`、`ResolvedRecord::to_json_string()`：输出完整数据包或单条测量组成的数组，可独立保存和转发。
- `Pack::to_cbor_bytes()`、`ResolvedPack::to_cbor_bytes()`、`ResolvedRecord::to_cbor_bytes()`：输出原始上下文包或独立测量；可设置 `max_output_bytes`。
- `MeasurementValue`：区分数值、文本、布尔和二进制值；零、`false`、空文本和空二进制会保留。
- `ContentFormatSpec::parse(input, max_code_units?)`：校验 RFC 9193 内容格式；`as_string()` 保留原文，`coap_number()` 读取编号。`ct`／`bct` 三格式往返及二进制继承见 [内容格式说明](docs/content-formats.md)。
- `Number::json_literal()`：读取原始数字文本；`as_double()` 提供可能舍入的 binary64 近似值。
- `SenmlError::diagnostic()`：读取错误类别、记录索引、字段及可用的 JSON／XML 行列位置。
- `ParseLimits::default()`：提供输入大小、记录数、嵌套深度、字段数和字符串／数字长度上限。
- `Label::from_json_name(name)`：识别区分大小写的 RFC 8428 基础 JSON 标签。
- `Label::from_cbor_key(key)`：识别标准整数 CBOR 标签。
- `Label::json_name()` 与 `Label::cbor_key()`：获取同一标签的两种表示。

`Label` 查找用于十五个基础标签；`ct`／`bct` 不具有整数 CBOR 键，由共享解析器单独处理。其他名称返回 `None`。JSON 解析器按 RFC 8428 忽略普通未知扩展，拒绝名称以 `_` 结尾的未知扩展。解析支持版本 10，并拒绝重复的解码后成员名称。详细边界与默认上限见 [JSON 输入约定](docs/json-profile.md)。

**`parse_json` 返回原始记录；独立取出或筛选测量前，应先调用 `resolve`。** 展开会保留原包，消除基字段并生成绝对时间；仅有基字段的上下文记录不输出。普通未知扩展会被丢弃，输出保留已理解的 `ct`／`bct`，不保留未知扩展。

展开算术采用 binary64，可能舍入；没有加法或加零时保留数值原文。溢出、缺失相对时钟和不可表示的绝对时间会失败，展开体积默认采用 4 Mi UTF-16 单元的保守上限。使用示例、时间与数值边界见 [展开和输出约定](docs/resolution.md)。

CBOR 使用标准整数标签和原生字节串，数字支持整数、浮点与输入 Tag 4。普通整数字面量在基本 CBOR 范围 `-2^64` 至 `2^64−1` 内可准确编码，其余数字采用 binary64；JSON 的十进制原文在跨格式输出后会改变。不定长记录映射与非首选参数宽度可读，`vs`／`vd` 仍使用确定长度。输入类型及数值边界见 [CBOR 约定](docs/cbor-profile.md)。

## 接收与发送 CoAP 测量

`integrations/coap` 接收 `POST /ingest`，支持 Content-Format `110`（SenML JSON）、`112`（SenML CBOR）和 `310`（SenML XML）。协议层复用 MoonCoAP；适配器解析并展开测量，返回待发送报文和验收事件。相同对端的重复报文在交换生存期内重发缓存响应，不重复输出测量。

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

可选应用路由 `/ingest?source=room-a&key=batch-1` 用业务来源和幂等键标识一次写入。同键、同格式、同负载重试不新增记录，也不重新保存基于新接收时刻展开的时间；同键换负载返回 `4.09`。这是应用约定，未修改 SenML 标签或将 CoAP MID 当作永久身份。生产接入需把来源绑定到已认证设备，详见 [业务幂等约定](docs/idempotency.md)。

一键演示会运行真实 UDP、重启采集进程并核对账本，临时文件在完成后清理：

```sh
node examples/coap/retry-demo.mjs
```

演示操作、四个检查点与讲解材料见 [三分钟演示](docs/demo.md)。

设备侧可复用纯 MoonBit `Sender`，由 MoonCoAP 处理请求重传、MID／Token 关联和独立响应 ACK，宿主提供套接字、单调时钟与随机源。Node.js 示例支持取消和单次截止时间，真实 UDP 检查覆盖请求与回复丢失。接口、预算与超时后的业务重试见 [CoAP 发送说明](docs/coap-sender.md)。

## 下一步实现

1. 持续扩充 JSON／CBOR／XML 条款覆盖与跨语言共同样本。
2. 验证 EXI 的 schema、依赖与后端路线，并实现独立适配器。
3. 实现版本特征和单位注册信息；SenSML 使用单独的增量接口规划。
4. 正式发布 Mooncakes 包，在独立消费项目中验证注册表安装与使用。

当前已运行的表示为有限 SenML JSON／CBOR／XML。`ct`／`bct` 内容格式已实现；EXI、SenSML、版本特征、单位注册信息和单位换算尚未实现，各项状态分别记录在标准覆盖表中。

## 架构与生态

![当前实现与计划架构](docs/architecture.svg)

核心以 MoonBit 实现，接口接收内存数据。文件、时钟、网络和界面由消费项目提供。CBOR 入站由有界 SenML 读取器完成；浮点解码与标量编码固定复用 [2515050242/cbor@0.1.2](https://mooncakes.io/docs/2515050242/cbor@0.1.2)，XML 固定复用 [Milky2018/xml@0.6.1](https://mooncakes.io/docs/Milky2018/xml@0.6.1) 的命名空间解析器与 Writer，CoAP 子包固定复用 [sujy123456/mooncoap@0.1.1](https://mooncakes.io/docs/sujy123456/mooncoap@0.1.1) 的内存协议核心；根包不导入网络驱动。模块依赖解析包含 MoonCoAP 的传递依赖，宿主示例的 UDP 使用 Node.js。现有 [MQTT 包](https://mooncakes.io/docs/Strangelight-Merser/moon-mqtt-client) 留待后续接入。

检索记录与实现决策见 [开发记录](docs/development.md)。

## 许可

[Apache-2.0](LICENSE)。基础行为依据 RFC 8428，内容格式依据 RFC 9193；[KPN Python SenML](https://github.com/kpn-iot/senml-python-library) 的测试版本、已通过流程和已知差异见 [互操作范围](docs/interoperability.md)。[absmach/senml](https://github.com/absmach/senml) 已固定提交并运行 JSON／CBOR／XML 对照。当前实现未复制这些项目的源代码。

# 字节入口与 CoAP 采集 · 0.1.0-dev.8

传输层只负责取得字节、对端身份和接收时刻。SenWeave 负责完整解析与展开，再把独立测量交给调用方。字节入口属于根包；CoAP 适配器属于公开子包 `q0w1ertyuiop/senweave/integrations/coap`，不需要将套接字类型带进业务代码。

## 共用字节入口

```moonbit
let raw = @senweave.parse_payload(
  wire,
  @senweave.SenmlJson,
  max_input_bytes=8192,
  reject_extensions=true,
)
let measurements = raw.resolve(reference_time=received_at)
```

`wire` 是收到的 `Bytes`，`received_at` 是宿主提供的 POSIX 秒。默认字节上限为 1 MiB，必须为正数；在 UTF-8 解码前检查。JSON 无效 UTF-8 返回 `InvalidUtf8`，BOM 保留后由 JSON 语法检查拒绝；CBOR 直接使用原始字节。`ParseLimits` 和展开预算仍有效。

根包默认遵循 SenML 普通扩展忽略规则；设置 `reject_extensions=true` 时，存在被丢弃的普通扩展会返回 `IgnoredExtensions`。`Pack::ignored_extension_count()` 可供宽松消费方记录损失数量。未知强制扩展始终拒绝。

`Format::from_content_type()` 接收最多 256 个 UTF-16 单元，媒体类型按 ASCII 大小写无关识别，修剪空格与制表符。JSON／XML 可带唯一的 `charset=utf-8` 参数（值可用双引号），CBOR 不接受参数；未知／重复参数返回 `None`。这是一项明确的入口约定，不是通用 HTTP 头解析器。

| Format | Content-Type | CoAP Content-Format |
| --- | --- | --- |
| `SenmlJson` | `application/senml+json` | 110 |
| `SenmlCbor` | `application/senml+cbor` | 112 |

编号依据 [RFC 8428 §12.5 Table 8](https://www.rfc-editor.org/rfc/rfc8428.html#section-12.5)。111／113 是 SenSML 流，不能作为这两个有限包格式传入。

## CoAP 适配器

导入子包为 `@coap` 后：

```moonbit
let collector = @coap.Collector::new()
let events = collector.receive(peer, datagram, monotonic_ms, received_at)
let expiration_events = collector.poll(later_monotonic_ms)
```

`receive` 和 `poll` 不读系统时钟、不发送数据。宿主负责执行事件：

| 事件 | 宿主处理 |
| --- | --- |
| `SendDatagram(peer, bytes)` | 向指定对端发送协议报文 |
| `Accepted(peer, pack)` | 处理已完整展开的 `ResolvedPack` |
| `Pending(delivery, peer, pack)` | 延迟模式：保存测量后调用句柄的 `finish` |
| `Completed(id, peer)` | 存储成功已由宿主报告，成功响应已调度 |
| `Duplicate(id, peer)` | 宿主确认相同业务请求已存储，成功响应已调度 |
| `Conflict(id, peer)` | 宿主报告业务键冲突，`4.09` 响应已调度 |
| `StorageFailed(id, peer)` | 存储失败已由宿主报告，`5.00` 响应已调度 |
| `Expired(id, peer)` | 待处理已超时，停止尝试完成此句柄 |
| `Busy(peer)` | 待处理队列已满，本请求返回 `5.03` |
| `InvalidDelivery(id)` | 句柄已消费或过期，不能再次完成 |
| `Rejected(peer, diagnostic)` | 记录数据错误；适配器已准备错误响应 |
| `ProtocolError(peer)` | 记录协议、资源或响应构造失败 |
| `InvalidClock` | 修正时钟来源，不把本次报文计为接收成功 |

`peer` 必须由可信传输元数据生成，稳定区分地址与端口。`monotonic_ms` 为非负、不会回退的 `Int64` 毫秒；CoAP 交换和去重用这一时钟。`received_at` 为有限且至少 `2**28` 的 POSIX 秒，用于 [RFC 8428 相对时间展开](https://www.rfc-editor.org/rfc/rfc8428.html#section-4.5.3)。这两个参数不能互相代替。宿主应在一次收到报文时取值，并定期调用 `poll` 回收过期状态。

默认路由只接收无查询参数的 `POST /ingest`。延迟模式显式启用 `idempotency=true` 后，可接收成对的 `source`／`key` 查询参数；其余查询仍拒绝，见 [业务幂等约定](idempotency.md)。缺失／不支持的 Content-Format 返回 `4.15`，其他路径返回 `4.04`，其他方法返回 `4.05`，错误查询或 SenML 校验失败返回 `4.00`。成功返回 `2.04 Changed`，无响应负载。数据错误的响应负载只包含固定错误码，不回显测量内容。

默认拒绝普通未知扩展，避免收到成功响应后才发现字段已丢失。确实允许丢弃时可用 `Collector::new(reject_extensions=false)`；`Accepted` 不额外携带丢弃统计，需要统计时应在通用字节入口完成。

## 资源与重传边界

固定使用 [MoonCoAP 0.1.1](https://github.com/sujy123456/MoonCoAP) 的有界端点，负载上限 8192 字节、完整报文上限 9000 字节，最多 8 个对端、16 个交换、64 个去重条目、128 个 MID 租约、16 个队列项和 128 个待取动作。超限报文或资源耗尽不会输出 `Accepted`。不支持 Blockwise、Observe 或无限 SenSML 流。

确认型请求以对端和 MID 识别重传，在默认 247000 毫秒生存期内重发缓存 ACK，避免再次展开和输出。不同对端可以使用相同 MID；过期后可复用。非确认型消息采用 MoonCoAP 的默认 145000 毫秒生存期。缓存是进程内状态，重启后不提供业务幂等；持久化消费应使用设备／业务记录标识自行去重。

默认模式的 `Accepted` 只表示语义校验成功，并且成功构造了协议响应。它不代表数据已写入存储或响应已送达。要求持久化后确认时应启用下述延迟模式。本例不提供 DTLS 或公网部署配置。

## 存储后应答

```moonbit
let collector = @coap.Collector::new(deferred=true)
// receive 返回 Pending(delivery, peer, pack) 后，先执行宿主的存储事务。
// 事务成功提交后：
let response_events = delivery.finish(stored=true, completed_at_monotonic_ms)
// 存储失败时改用 stored=false，执行返回的 SendDatagram 事件。
```

确认型请求通过校验后立即生成空 ACK，它只确认协议报文已收到；此时没有 `2.04` 成功响应。宿主报告存储成功后生成独立的确认型 `2.04`，报告失败则生成 `5.00`。非确认型请求不发空 ACK，完成时发非确认型响应。独立响应沿用请求 Token，使用自己的 MID；宿主继续把客户端 ACK／RST 传给 `receive`，并定期 `poll`，MoonCoAP 负责响应重传与结束。

`Delivery` 的字段和构造器私有，句柄绑定创建它的采集器；`id()` 只作本进程关联，不能作为跨重启业务标识。`finish(stored~, monotonic_ms)` 只接受一次成功的完成操作，时钟回退时保留待处理项以便修正时钟后重试。已消费、过期或旧句柄返回 `InvalidDelivery`。`Collector::pending_count()` 提供当前数量；不调用 `receive`／`poll`／`finish` 时，时间不会自动推进。

`complete(outcome, monotonic_ms)` 另支持 `Stored`、`AlreadyStored`、`KeyConflict`、`Failed` 四种宿主结果，旧 `finish` 保持兼容。`AlreadyStored` 返回 `2.04`，`KeyConflict` 返回 `4.09`；没有业务键的句柄不能使用这两种结果。`business_key()`、`payload()` 和 `format()` 供宿主取得已校验的身份、原始负载和表示，库不代替宿主查询或提交持久化状态。

每个采集器最多 16 项待处理，每项自接收后 30000 毫秒到期。容量满时返回 `5.03`，不逐出尚未完成的数据。达到期限后生成 `Expired` 和 `5.03`；如果宿主晚到连协议交换也已过期，则只清理句柄。晚到的存储结果不能再产生成功响应。宿主应在期限内完成事务；异步操作可能在超时后实际提交，此时仍需业务标识处理重试，不能因未收到成功响应就断定没有落库。

库不执行或检查宿主的事务。调用 `finish(stored=true, ...)` 的含义是宿主已确认自己的存储提交成功；`Completed` 表示响应已交给协议端点调度，不代表客户端已收到。进程在提交与发送成功响应之间退出时，业务数据可能已存在；这两步不构成跨存储和网络的原子事务。

### SQLite 示例

```sh
node examples/coap/collector.mjs --port 0 --duration-ms 10000 --store measurements.sqlite
python scripts/check_coap_interop.py --storage
```

存储模式通过 [Node.js 24 内置 `node:sqlite`](https://nodejs.org/docs/latest-v24.x/api/sqlite.html) 的同步接口执行独立事务。测量作为 `senml_json TEXT` 参数绑定，保留 MoonBit 输出的大整数文本；不经过宿主数字转换。`peer` 和 `received_at` 是传输对端及宿主保存时取到的 POSIX 时刻。事务提交后调用 `finish(stored=true, ...)`，锁定、提交或容量错误调用 `stored=false`；错误响应不包含路径或数据库错误详情。

示例仅创建新的普通文件或重新打开具有 SenWeave application ID 和 schema 版本 1／2 的账本。旧版本 1 在同一事务中添加业务键列和唯一索引，保留原记录；失败时回滚，版本不前移。其他数据库、符号链接和 `:memory:` 被拒绝。使用 DELETE 日志和 `synchronous=FULL`，主文件采用 4096 字节页、4096 页上限（16 MiB），最多 4096 包；日志和文件系统开销另计。达到上限时保留已有数据并拒绝新存储，已提交的幂等重试仍可成功。业务应用需要设计归档和保留策略。SQLite 同步策略见 [官方 PRAGMA 说明](https://www.sqlite.org/pragma.html#pragma_synchronous)。已验证正常提交、锁冲突、配额、重开与响应顺序，未做硬件掉电测试。

账本行是每个 SenML 包的独立测量数组，`id` 为账本自增序号。不带业务键的请求继续按包新增，重启后可能重复；带键请求按来源、键、原始字节和格式判定，保留首次测量，详见 [业务幂等约定](idempotency.md)。SQLite 是可替换的宿主示例，MoonBit 核心和 CoAP 子包均不依赖 SQLite。

## 实际 UDP 示例与验证

Node.js 24 及以上提供 UDP 套接字，MoonBit 提供协议与语义处理；没有额外 npm 依赖：

```sh
moon update
moon build cmd/coapbridge --target js --release
node examples/coap/collector.mjs --port 0 --duration-ms 10000
```

只绑定 `127.0.0.1` IPv4，启动行输出实际端口。`--port` 可指定 0–65535；`--duration-ms` 为 100–60000。默认读取每次接收时的系统 POSIX 秒，`--now 1793000000` 可固定测试时间。输出为 JSON 行，测量位于 `accepted` 事件的 `json` 字符串中；宿主没有重新解析测量数字。标准输出积压预算为 1 MiB，待发送报文最多 32 项，超过预算退出。

```sh
node --test tests/coap.test.mjs tests/coap-client.test.mjs
python -m pip install cbor2==5.7.1 aiocoap==0.4.14
python scripts/check_coap_interop.py
python scripts/check_coap_interop.py --storage
```

Node 测试通过真实 UDP 检查 JSON／CBOR／XML、独立 ACK 字节、重复报文只验收一次、路由与格式错误、无效 UTF-8、扩展丢弃政策、SQLite 提交／拒绝和有限运行时间。Python 3.10 及以上的独立 aiocoap 客户端在默认模式执行 7 次、存储模式执行 11 次请求；后者包括同键重试、负载冲突和缺失来源拒绝，最终独立读回 3 包。CoAP 纯逻辑在 native、JS、wasm-gc 测试；套接字示例目前只有 Node.js 实现，尚未接入 MoonCoAP 的 native UDP 驱动或 MQTT 客户端。

设备侧发送适配器、默认重传间隔、取消和丢包验证见 [CoAP 发送说明](coap-sender.md)。

XML 使用 `SenmlXml` 和 Content-Format `310`；纯状态机、Node.js Sender 与 SQLite 例子均已验证原始 XML 字节的接收和业务重试。XML 词法、DTD 策略及预算见 [XML 约定](xml-profile.md)。

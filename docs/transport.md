# 字节入口与 CoAP 采集 · 0.1.0-dev.6

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

`Format::from_content_type()` 接收最多 256 个 UTF-16 单元，媒体类型按 ASCII 大小写无关识别，修剪空格与制表符。JSON 可带唯一的 `charset=utf-8` 参数（值可用双引号），CBOR 不接受参数；未知／重复参数返回 `None`。这是一项明确的入口约定，不是通用 HTTP 头解析器。

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
| `Rejected(peer, diagnostic)` | 记录数据错误；适配器已准备错误响应 |
| `ProtocolError(peer)` | 记录协议、资源或响应构造失败 |
| `InvalidClock` | 修正时钟来源，不把本次报文计为接收成功 |

`peer` 必须由可信传输元数据生成，稳定区分地址与端口。`monotonic_ms` 为非负、不会回退的 `Int64` 毫秒；CoAP 交换和去重用这一时钟。`received_at` 为有限且至少 `2**28` 的 POSIX 秒，用于 [RFC 8428 相对时间展开](https://www.rfc-editor.org/rfc/rfc8428.html#section-4.5.3)。这两个参数不能互相代替。宿主应在一次收到报文时取值，并定期调用 `poll` 回收过期状态。

路由只接收无查询参数的 `POST /ingest`。缺失／不支持的 Content-Format 返回 `4.15`，其他路径返回 `4.04`，其他方法返回 `4.05`，查询参数或 SenML 校验失败返回 `4.00`。成功返回 `2.04 Changed`，无响应负载。数据错误的响应负载只包含固定错误码，不回显测量内容。

默认拒绝普通未知扩展，避免收到成功响应后才发现字段已丢失。确实允许丢弃时可用 `Collector::new(reject_extensions=false)`；`Accepted` 不额外携带丢弃统计，需要统计时应在通用字节入口完成。

## 资源与重传边界

固定使用 [MoonCoAP 0.1.1](https://github.com/sujy123456/MoonCoAP) 的有界端点，负载上限 8192 字节、完整报文上限 9000 字节，最多 8 个对端、16 个交换、64 个去重条目、128 个 MID 租约、16 个队列项和 128 个待取动作。超限报文或资源耗尽不会输出 `Accepted`。不支持 Blockwise、Observe 或无限 SenSML 流。

确认型请求以对端和 MID 识别重传，在默认 247000 毫秒生存期内重发缓存 ACK，避免再次展开和输出。不同对端可以使用相同 MID；过期后可复用。非确认型消息采用 MoonCoAP 的默认 145000 毫秒生存期。缓存是进程内状态，重启后不提供业务幂等；持久化消费应使用设备／业务记录标识自行去重。

`Accepted` 只表示语义校验成功，并且成功构造了协议响应。它不代表数据已写入存储或响应已送达。当前适配器先生成成功响应，再把测量交给宿主；要求“持久化成功后才确认”的服务，需要另外设计存储与应答协调接口。本例不提供 DTLS 或公网部署配置。

## 实际 UDP 示例与验证

Node.js 24 及以上提供 UDP 套接字，MoonBit 提供协议与语义处理；没有额外 npm 依赖：

```sh
moon update
moon build cmd/coapbridge --target js --release
node examples/coap/collector.mjs --port 0 --duration-ms 10000
```

只绑定 `127.0.0.1` IPv4，启动行输出实际端口。`--port` 可指定 0–65535；`--duration-ms` 为 100–60000。默认读取每次接收时的系统 POSIX 秒，`--now 1793000000` 可固定测试时间。输出为 JSON 行，测量位于 `accepted` 事件的 `json` 字符串中；宿主没有重新解析测量数字。标准输出积压预算为 1 MiB，待发送报文最多 32 项，超过预算退出。

```sh
node --test tests/coap.test.mjs
python -m pip install cbor2==5.7.1 aiocoap==0.4.14
python scripts/check_coap_interop.py
```

Node 测试通过真实 UDP 检查 JSON／CBOR、独立 ACK 字节、重复报文只验收一次、路由与格式错误、无效 UTF-8、扩展丢弃政策和有限运行时间。Python 3.10 及以上的独立 aiocoap 客户端执行 7 次请求，核对 2 个成功包和 5 个拒绝响应。CoAP 纯逻辑在 native、JS、wasm-gc 测试；套接字示例目前只有 Node.js 实现，尚未接入 MoonCoAP 的 native UDP 驱动或 MQTT 客户端。

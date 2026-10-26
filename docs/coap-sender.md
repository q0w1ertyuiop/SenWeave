# CoAP 发送适配器 · 0.1.0-dev.11

`integrations/coap` 提供设备侧 `Sender` 和采集侧 `Collector`。发送器不打开套接字、不读取时钟；请求编码、重传、MID／Token 关联及独立响应应答复用 MoonCoAP 0.1.1。宿主负责报文收发、单调时间和随机源。

## MoonBit 消费示例

导入 `q0w1ertyuiop/senweave` 与 `q0w1ertyuiop/senweave/integrations/coap`，后者别名为 `coap`：

```moonbit
let sender = @coap.Sender::new("gateway", 123L).unwrap()
let key = @coap.BusinessKey::from_queries([
  "source=room-a", "key=batch-1",
]).unwrap().unwrap()
let events = sender.send(
  b"[{\"n\":\"temperature\",\"v\":22.5,\"t\":-3}]",
  @senweave.SenmlJson, 0L, 500000, business_key=key,
)
```

固定种子和时间用于演示。实际宿主应提供新鲜的非负 Token 种子（不等于 `Int64` 最大值）、单调毫秒与 0–1000000 的随机样本。`peer` 是固定对端的宿主键，接收时必须按实际来源映射。Token 只关联响应，不提供身份认证。

| 接口 | 行为 |
| --- | --- |
| `Sender::new(peer, token_seed, initial_mid?, response_timeout_ms?)` | 固定对端、单个活动上传；响应预算默认 10000 毫秒，允许 2000–247000 毫秒 |
| `send(payload, format, now, random_sample, business_key?)` | 校验后发送 `POST /ingest`，忙时拒绝另一上传 |
| `receive(peer, wire, now)` | 忽略其他对端及无效报文，检查 MID／Token |
| `next_deadline()`、`poll(now)` | 提供和推进绝对单调毫秒截止时刻 |
| `cancel(now)`、`is_pending()` | 取消或查询等待状态；取消不会先触发到期重传 |

发送前执行严格 UTF-8 和 8192 字节上限的原始 SenML 校验，拒绝未知扩展。发送器保留输入负载，不展开相对时间或基值算术；这些语义由接收方处理。协议重传使用完全相同的请求字节，新的应用上传分配新的 MID／Token。

每个实例最多一个活动交换、64 个独立响应回执和 128 个 MID 租约。历史状态保留默认交换生存期，到期由轮询等操作清理。容量耗尽报告 `Capacity`；调用方应限流等待到期，避免重建同种子、同 MID 的实例来绕过租约。

## 重传、响应和取消

`Transmit(bytes)` 交给绑定对端；`Acknowledged(id)` 只说明收到空 ACK；`Received(id, code, payload)` 表示收到最终响应，业务方仍需检查响应码。`4.09` 和 `5.00` 不会被转换成成功。

初始重传间隔为 2–3 秒，之后指数退避，最多四次；应用预算可提前终止等待。空 ACK 停止请求重传，独立响应使用自己的 MID。持续存活的实例再次收到独立响应时重发 ACK，不重复产生 `Received`。协议依据见 [RFC 7252 §4.2](https://www.rfc-editor.org/rfc/rfc7252.html#section-4.2)、[§4.8](https://www.rfc-editor.org/rfc/rfc7252.html#section-4.8) 与 [§5.2.2](https://www.rfc-editor.org/rfc/rfc7252.html#section-5.2.2)。

`Failed` 报告超时、对端 Reset 或协议失败，`Rejected` 表示操作未获准，`Cancelled` 表示停止本地等待。错误原因不复制原始负载、对端名称或上游错误文本。超时或取消后服务端可能已提交存储，应使用相同业务键与原始字节重试，见 [业务幂等约定](idempotency.md)。

## Node.js 回环宿主

```sh
moon build cmd/coapbridge --target js --release
node --test tests/coap-client.test.mjs tests/coap.test.mjs
node examples/coap/retry-demo.mjs
```

`examples/coap/client.mjs` 的 `sendMeasurement` 使用临时回环 UDP 套接字、系统随机源和 MoonBit 给出的截止时刻。这是源码示例，未作为 npm SDK 接口导出；套接字宿主目前只有 Node.js 实现。

参数包括 `port`、`Buffer` 负载、可选 `source`／`key`、`format`（110／112）、`mid` 和 `AbortSignal`。未指定 `mid` 时使用系统随机源生成初始 MID。`timeout` 默认 10000 毫秒，允许 1–10000 毫秒；短预算会提前取消，不会加速协议重传。已取消的信号在绑定前拒绝。

结果包含 `code`、`emptyAck`、`responseHex` 和请求发送次数 `attempts`。超时错误码为 `CoapTimeout`，取消为 `ABORT_ERR`；两者保留 `attempts`／`emptyAck`，不回显取消原因。该宿主应答独立响应后关闭套接字；需持续处理重复响应的应用应长期托管 MoonBit `Sender`。

真实 UDP 测试主动丢弃首个请求和成功回复，核对重传字节一致、恢复成功、采集器只验收一次。另测错误对端／Token、无效报文、独立响应 ACK、超时与取消。MoonBit 显式时间测试覆盖退避、取消与重传同时到期、历史容量恢复及 MID 回绕，在三个后端执行。

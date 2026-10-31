# 已验证的互操作范围 · 0.1.0-dev.16

这份记录区分通用 CBOR 编码交换与外部 SenML 库的语义交换。测试使用未修改的已发布版本，公共脚本保留实际断言。

## Python cbor2 5.7.1

`scripts/check_cbor_interop.py` 在 native、JS、wasm-gc 上双向交换。Python 先读取 MoonBit 原始包与展开包，再生成包含 Tag 4、字节串、布尔及最大 UInt64 的 6 条原始记录交给 SenWeave。断言覆盖名称、单位、时间、基值／基和、中文与表情、数据类型和数值。

```sh
python -m pip install cbor2==5.7.1
python scripts/check_cbor_interop.py --target js
```

其余目标将 `js` 换为 `native` 或 `wasm-gc`。这是编码交换与指定场景的检查，`cbor2` 不承担 SenML 语义校验。

`0.1.0-dev.13` 另外通过 `cbor2` 验证六类输入表示：不定长记录映射、非首选参数宽度、Int64 以下的三类负整数边界和分块名称。每类都核对原始 JSON、原始 CBOR、展开 JSON 与展开 CBOR，基本整数保持准确值。此项仍是独立 CBOR 与预期测量的核对，不代替其他 SenML 库的完整语义对照。

## Go／Python 共同样本

`scripts/senml_comparison/run.py` 固定 Go `absmach/senml` 提交 `40cd806e5f63` 与 Python `kpn-senml 1.0.1`，使用 `--xml` 运行 55 组、133 项共同输入（含 45 项 XML）分别核对解码校验、原始编码与展开。SenWeave 的 133 项满足固定期望；Go 48 项结果一致，80 项记录了差异阶段和原因，另有 5 项因无关原因同阶段拒绝，未算作语义一致；Python 的 40 次输入更新中，34 次更新和 6 次已知异常均按预期复现。相对时刻由测试宿主显式对齐，整数表示与 binary64 等价单列。

共同样本包含错误输入和定向边界，结果数量不表示整体缺陷率。Go／Python 的接口范围、阶段对应、逐项差异、复现入口和 CI artifact 见 [参考实现比较](comparison.md)。以下 KPN 五条交换流程继续独立保留，未与共同样本混合计数。

## KPN SenML 1.0.1

来源为 [KPN SenML 仓库](https://github.com/kpn-iot/senml-python-library) 的 [PyPI 已发布版本 1.0.1](https://pypi.org/project/kpn-senml/1.0.1/)。该版本对应早期 SenML 草案，测试不修改源码或补丁兼容层。

```sh
moon update
moon build cmd/bridge --target js --release
python -m pip install cbor2==5.7.1 kpn-senml==1.0.1
python scripts/check_senml_interop.py
```

针对该版本已运行并通过以下 5 条流程：

| 方向 | 核对内容 |
| --- | --- |
| KPN JSON → SenWeave | 数值、零、`false`、完整名称、单位、基值和绝对时刻 |
| KPN CBOR → SenWeave | 同一数值／布尔包及其基字段 |
| SenWeave JSON → KPN | 已展开的数值、零和布尔值；使用 KPN 更新已有记录的接口 |
| SenWeave CBOR → KPN | 相同测量值及布尔类型 |
| KPN 含 `bs` 的 JSON → SenWeave | 基准和加偏移后为 105，保留单位和时刻 |

脚本同时复现并核对三处差异：

- KPN `1.0.1` 的 CBOR 映射把 `bs` 写为 `-16`；[RFC 8428 §6](https://www.rfc-editor.org/rfc/rfc8428.html#section-6) 定义的是 `-6`。SenWeave 对该旧键返回 `InvalidCborLabel`，没有把它静默解释成基准和。
- 该发布版在 Python 3 构造文本值时触发 `NameError: basestring`。文本／二进制的完整交换由 `cbor2` 流程验证，未计入 KPN 已通过流程。
- KPN 输入接口更新记录值，不更新记录的时间元数据。因此反向流程只核对它实际支持的测量值更新，没有将其计作完整时刻／单位回读验证。

脚本输出 `passed-with-documented-differences`，并列出这三项差异。它们属于当前对照版本的兼容边界，不能据此推断其他版本具有相同行为。源码检索与本地安装内容也表明仓库 master 与 PyPI 发布版存在差别；此处以固定发布版的运行结果为准。

## aiocoap 0.4.14

使用未修改的 [aiocoap 0.4.14](https://pypi.org/project/aiocoap/0.4.14/) 客户端，通过真实本机 UDP 与 Node.js 宿主的 MoonBit CoAP 采集器交互。脚本不以自制客户端替代外部协议栈。

```sh
moon build cmd/coapbridge --target js --release
python -m pip install cbor2==5.7.1 aiocoap==0.4.14
python scripts/check_coap_interop.py
python scripts/check_coap_interop.py --storage
```

共 7 次请求：JSON 基值／相对时间与 CBOR 字节串成功接收，缺失格式、错误格式、未知路径、无效 UTF-8、未知普通扩展被拒绝。断言核对 `2.04`／`4.00`／`4.04`／`4.15` 响应及两包完整测量的名称、时刻、数值和二进制数据。另有 Node UDP 测试通过独立构造的报文和 ACK 字节检查重传去重，纯协议逻辑测试覆盖 MID 过期复用与时钟回退。接口和边界见 [传输接入](transport.md)。

`--storage` 在独立临时 SQLite 文件中执行 11 次交换：包含原来的 7 次，再增加带来源／业务键的首次提交、原样重试、同键不同负载 `4.09` 和缺失来源 `4.00`。确认型成功请求先收到空 ACK，宿主提交或查明已提交后由 MoonCoAP 发送独立响应，aiocoap 完成匹配与 ACK；最终独立读回 3 包完整内容。两种模式共 18 次请求，均已运行。

Node 测试另外验证数据库锁定和行配额返回 `5.00`、已有账本重开、跨重启重试保留首次时间、两个采集进程共享账本不重复写入、满额时已存请求仍成功，以及旧账本格式升级失败回滚。拒绝其他应用数据库时字节不变。一键演示通过 4 次真实 UDP 请求展示同样的重启与冲突流程，见 [演示说明](demo.md)。

跨重启业务幂等由上述 Node UDP 测试验证；当前测试尚未覆盖公网、DTLS、真实硬件设备或持续丢包压力。更多 SenML 实现版本与 RFC 全部示例需要后续覆盖。

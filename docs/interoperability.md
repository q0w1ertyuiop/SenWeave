# 已验证的互操作范围 · 0.1.0-dev.5

这份记录区分通用 CBOR 编码交换与外部 SenML 库的语义交换。测试使用未修改的已发布版本，公共脚本保留实际断言。

## Python cbor2 5.7.1

`scripts/check_cbor_interop.py` 在 native、JS、wasm-gc 上双向交换。Python 先读取 MoonBit 原始包与展开包，再生成包含 Tag 4、字节串、布尔及最大 UInt64 的 6 条原始记录交给 SenWeave。断言覆盖名称、单位、时间、基值／基和、中文与表情、数据类型和数值。

```sh
python -m pip install cbor2==5.7.1
python scripts/check_cbor_interop.py --target js
```

其余目标将 `js` 换为 `native` 或 `wasm-gc`。这是编码交换与指定场景的检查，`cbor2` 不承担 SenML 语义校验。

## KPN SenML 1.0.1

来源为 [KPN SenML 仓库](https://github.com/kpn-iot/senml-python-library) 的 [PyPI 已发布版本 1.0.1](https://pypi.org/project/kpn-senml/1.0.1/)。该版本对应早期 SenML 草案，测试不修改源码或补丁兼容层。

```sh
moon update
moon build cmd/bridge --target js --release
python -m pip install cbor2==5.7.1 kpn-senml==1.0.1
python scripts/check_senml_interop.py
```

本批已运行并通过以下 5 条流程：

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

[absmach/senml](https://github.com/absmach/senml) 已阅读其展开实现，尚未运行。更多版本、RFC 全部示例、传输层和真实设备输入需要后续覆盖。

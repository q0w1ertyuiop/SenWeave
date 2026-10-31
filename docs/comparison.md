# SenML 参考实现比较

核查日期：2026-10-31。SenWeave 为 `0.1.0-dev.14`。共同样本已实际运行；XML、EXI 和其他未覆盖能力继续单列。

| 维度 | SenWeave | Go absmach/senml | Python KPN SenML 1.0.1 |
| --- | --- | --- | --- |
| 数据模型 | MoonBit 类型化记录、原始数字文本与包上下文 | Record／Pack；公共数值字段为 float64 | 面向包和执行器记录的对象模型 |
| 表示 | JSON／CBOR；XML／EXI 待实现 | README 与源码提供 JSON／XML／CBOR 入口 | 发布版本提供 JSON／CBOR |
| 校验与展开 | 共同样本 72 项符合固定期望 | Decode 内含 Validate；Normalize 与原始编码分别实测 | 共同样本 40 项调用 input-update；未提供通用 Validate／Normalize 对照 |
| 单位 | 当前按字符串处理，注册信息与次级单位待实现 | 单位能力需继续逐项核查 | 上游文档列有单位注册信息；未完成逐项运行核对 |
| 扩展与版本 | 当前 version 10；普通扩展可忽略或按接入策略拒绝 | 强制扩展、未知版本、显式零值／空值均已测出具体差异 | 已实测其值更新入口对这些输入的行为；该入口不构成完整语义校验 |
| 数值范围 | 基本 CBOR 整数 `-2^64` 至 `2^64−1` 原文与整数编码可保留；实际算术为 binary64 | 已测大整数表示变化、负整数下界和 Tag 4；分别报告原文与 binary64 比较 | 共同样本核对准确整数值；文本和数据值有发布版本异常 |
| 复用方式 | MoonBit 公共包、三后端测试、Node.js SDK；注册表发布待完成 | Go 模块 | Python 发布包 |

## 已核查版本与来源

- Go 来源为 [absmach/senml](https://github.com/absmach/senml)，固定到提交 [40cd806](https://github.com/absmach/senml/tree/40cd806e5f6331135c00bfabaf82f037b0d81354)，模块版本 `v1.0.9-0.20261001142627-40cd806e5f63`。Go 1.24.5 实际运行，依赖由 `go.mod`／`go.sum` 固定；不修改上游模块。
- Python 使用已发布的 [kpn-senml 1.0.1](https://pypi.org/project/kpn-senml/1.0.1/)，已运行范围与版本差异见[互操作记录](interoperability.md)。
- [farshidtz/senml/v2](https://github.com/farshidtz/senml) 的文档提供模型、校验、归一化、单位及 JSON／XML／CBOR 编解码，可作为另一 Go 对照候选；尚未运行。

## 共同样本与阶段

入口为 [run.py](../scripts/senml_comparison/run.py)，[cases.json](../scripts/senml_comparison/cases.json) 保存 40 组输入、标准条款或接入策略以及期望；按格式得到 72 项。样本包括数值、零、false、空／Unicode 文本、二进制、仅含和、继承与清零、相对时间、上下文记录、扩展、版本、错误输入、整数边界及 CBOR 编码变体。未采用随机生成样本。

1. **解码与校验：** SenWeave 的 `parse_json`／`parse_cbor` 对齐 Go 的 `Decode`，后者内部调用 `Validate`。坏输入分别保存错误与失败阶段，不以 Go 的结果决定标准期望。
2. **原始编码：** 两端分别输出原始 JSON／CBOR，再由 SenWeave 重读、展开并与固定期望比较，检查清零字段是否在编码中丢失。外部 cbor2 还检查展开 CBOR 的字段及字节串类型。
3. **展开：** SenWeave 使用固定参考时刻 `1793000000`。Go 原始 `Normalize` 输出完整保存；测试宿主再补齐相对时刻并按绝对时间排序，另存该投影。Go 没有参考时刻参数，这一步明确属于宿主。
4. **表示：** 比较忽略对象成员顺序与独立记录的空单位表示；布尔和数值严格区分。大整数同时报告准确表示与 binary64 等价情况，浮点表示变化单列，不能直接据此判为标准缺陷。

## 实测结果

| 结果 | 数量与含义 |
| --- | --- |
| SenWeave | 72 项满足固定期望；有效样本另核对原始 JSON／CBOR 往返、展开 JSON／CBOR |
| Go 一致 | 33 项在所测结果上相同，包括共同拒绝的输入 |
| Go 已解释差异 | 39 项：30 项标准语义或输入表示覆盖差异，5 项数值表示差异，2 项版本策略，1 项重复成员策略，1 项失败阶段差异 |
| Python input-update | 40 项：34 次值更新与固定期望一致，文本的 4 次 NameError 和二进制的 2 次 KeyError 已固定复现 |

这些是包含边界和反例的定向样本数量，不是随机抽样的总体错误率。逐项差异和原因固定在 [go_expectations.json](../scripts/senml_comparison/go_expectations.json)，新增或消失的差异都会使检查失败。

具体观察：

- Go `Normalize` 未继承后续记录的 `bv`；显式空 `bn`、空单位及零 `bt`／`bs` 与缺失混同。原始编码中的 `omitempty` 也会丢弃重置项。依据 RFC 8428 §4.1、§4.5 保留这些差异，不能在适配器中补写上游行为。
- Go 的 `vd` 使用字符串字段，JSON 到 CBOR 时写成文本串，标准 CBOR 字节串输入则解码失败；Tag 4 分数和 `-2^64` 整数输入也有明确拒绝。依据 RFC 8428 §6 和 RFC 8949 §3.1 记录。
- 未知强制扩展、大写指数与仅含基字段的记录存在处理差异，分别关联 RFC 8428 §4.4、§5 和 §5.1.7。未知版本另归类为当前版本策略；重复 JSON 成员归类为接入策略。
- 数值表示样本中，Go 的 float64 路径可能改变整数文本。报告另列 `go_binary64_equivalent_difference_stages`，区分文本精度与测量的 binary64 语义。
- 加法溢出时，SenWeave 在 resolve 拒绝；Go Normalize 返回后，JSON Encode 因 `+Inf` 拒绝。两端均未交付成功 JSON，失败阶段不同。
- Python 该版本主要更新既有执行器值，所测入口未填充 time、unit、sum、update_time；34 次更新包含它接受了若干 SenWeave 拒绝的输入，不能写成 34 次完整 SenML 校验通过。未覆盖的共同样本明确标注，原有五条双向交换与 `bs` 标签差异仍由旧脚本独立验证。

## 复现与结果文件

需要 MoonBit、Node.js 24 及以上、Python 3.10 及以上和 Go 1.24.5 及以上。在仓库根目录执行：

```sh
moon update
python -m pip install cbor2==5.7.1 kpn-senml==1.0.1
python scripts/senml_comparison/run.py
```

脚本构建 MoonBit JS 对照入口和 Go 适配器，结果写到 `_build/interop/senml-comparison.json`，包含全部输入、固定期望、实际输出、失败阶段、工具版本和分类。CI 的 `senml-comparison` 任务运行同一入口，并保存同名 artifact 30 天；过期后可用对应提交重新运行。

本轮没有执行 Go XML、EXI、单位体系或后续 SenML 扩展对照；这些能力的状态仍见[标准覆盖表](senml-support.md)。

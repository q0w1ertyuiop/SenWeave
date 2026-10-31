# 二进制值的内容格式 · 0.1.0-dev.16

[RFC 9193 §3–6](https://www.rfc-editor.org/rfc/rfc9193.html#section-3) 为二进制测量值 `vd` 定义 `ct`（本条内容格式）与 `bct`（基准内容格式）。SenWeave 在 JSON、CBOR、XML 中使用同一类型、校验与继承逻辑，原始包和独立测量均能保留这些信息。

## 值与接口

两个字段都使用字符串，允许以下表示：

- `"0"` 至 `"65535"` 的十进制 CoAP Content-Format 编号，除零本身外不允许前导零；`"60"` 有效，`60`、`"060"`、`"65536"` 无效。
- 媒体类型及参数，可接按应用顺序排列的内容编码，如 `text/plain; charset=utf-8@deflate`、`application/json@deflate@aes128gcm`。

解析器按 RFC 的 ABNF 检查类型名称、127 字符名称上限、参数 token／引号、转义与编码列表。引号内的 `@` 和分号属于参数值，不会拆成编码。保留大小写、空格、参数和编码顺序的原文；不进行编号与媒体类型之间的注册表映射。符合语法的未来媒体类型、参数、编码及未分配编号也可保留。

```moonbit
let spec = @senweave.ContentFormatSpec::parse("60")
assert_eq(spec.coap_number(), Some(60))
assert_eq(spec.as_string(), "60")
```

`ContentFormatSpec` 的构造字段私有。公开 `parse(input, max_code_units?)` 默认最多 65,536 个 UTF-16 单元；包入口使用对应的 `ParseLimits.max_string_code_units`。`Record.base_content_format`、`Record.content_format` 和 `ResolvedRecord.content_format` 均为可选的已校验类型。`coap_number()` 对媒体类型字符串返回 `None`。

## 继承与独立输出

```json
[
  {"bct":"60","bt":1793000000},
  {"n":"blob","vd":"AP8"},
  {"n":"temperature","v":7.1},
  {"n":"photo","vd":"AA","ct":"image/png"},
  {"n":"blob2","vd":"AQ"}
]
```

`bct` 可单独构成上下文记录，作用于本条及后续记录，直到下一个 `bct` 替换它。展开后 `blob`、`blob2` 具有 `ct:"60"`，`photo` 保留自己的 `ct:"image/png"`；温度记录没有 `ct`。本条 `ct` 不改变后续默认值。空二进制同样可携带内容格式。

显式 `ct` 要求同条存在 `vd`；出现在数值、文本、布尔、仅含和或纯上下文记录上会返回 `InvalidRecord`。空字符串不是清除 `bct` 的合法值；改用另一个有效规范值，或开始新的独立包。缺省格式未知时不生成 `ct`，库也不会猜测二进制的媒体类型。

先按原始顺序应用继承，再排序或筛选。独立 JSON／CBOR／XML 输出直接携带 `ct`，不依赖原包的 `bct`。原始包输出则保留基字段、覆盖项和顺序，无需参考时刻。

## 表示、预算与应用接入

JSON 使用 `ct`／`bct` 字符串成员；XML 使用无命名空间的同名属性；CBOR 使用文本键和文本值，`vd` 仍为原生字节串。[RFC 9193 §8](https://www.rfc-editor.org/rfc/rfc9193.html#section-8) 没有为这两个扩展分配整数键，十五个基础标签的 `Label` 枚举保持原有映射。带外来命名空间的 XML 属性仍按未知扩展处理。

这两个已理解字段不计入 `ignored_extension_count`，`reject_extensions=true` 或 SDK 的 `rejectExtensions:true` 接受它们。错误类型为 `WrongType`，语法或编号范围错误为 `InvalidContentFormat`；诊断只保留 `ct`／`bct`、记录索引和固定说明，不回显内容格式值。

字段名、字符串、成员数、输入和输出预算继续生效。继承到每条二进制测量的格式字符串计入展开预算，先检查完整包，再执行筛选。SDK、CLI 和 CoAP／SQLite 示例复用同一实现；包的外层 Content-Format `110`／`112`／`310` 与 `vd` 内的 `ct` 含义分别处理。

库保存格式说明及原始二进制，不自动解压、解密、执行或调用媒体处理器。应用若要解释数据，需自行选择处理器并配置处理预算。

## 验证

`content_format_test.mbt` 覆盖 ABNF 正反例、范围、类型、基字段替换、排序与筛选、三格式原始／独立往返、CBOR 文本键与重复键、XML 引号和命名空间、严格准入及配额。Node 测试覆盖 SDK、CLI 管道和真实 UDP 接收落库；独立 MoonBit 与 npm 归档消费也检查格式元数据。

共同样本增加八组 RFC 9193 输入。`cbor2` 独立编码／读取文本扩展键，ElementTree 独立生成／读取 XML 属性。固定 Go 参考模型没有 `ct`／`bct`，因此分别记录扩展丢弃、基准上下文拒绝及 CBOR 字节串先行拒绝；这些结果不能视为参考端已验证内容格式语义，详见[参考实现比较](comparison.md)。

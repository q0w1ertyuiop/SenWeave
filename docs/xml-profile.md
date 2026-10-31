# SenML XML · 0.1.0-dev.15

XML 入口按 [RFC 8428 §7](https://www.rfc-editor.org/rfc/rfc8428.html#section-7) 将十五个基础属性读入与 JSON／CBOR 共用的 `Pack`。解析和写入固定复用 [Milky2018/xml@0.6.1](https://mooncakes.io/docs/Milky2018/xml@0.6.1) 的命名空间事件流和检查型 Writer，在 native、JS、wasm-gc 使用相同代码。

```xml
<sensml xmlns="urn:ietf:params:xml:ns:senml">
  <senml bn="sensor:" bt="1793000000" bu="Cel" bv="20"/>
  <senml n="temperature" v="2.5" t="-3" ut="30"/>
  <senml n="door" vb="false" u="/"/>
  <senml n="blob" vd="AP8" u="/"/>
</sensml>
```

## 解析与转换

`parse_xml(text, limits?)` 返回原始包；`parse_payload(bytes, SenmlXml, ...)` 先检查字节上限并严格解码 UTF-8。完整文档读取并校验后才返回结果。`Pack::to_xml_string` 保留基字段、重置值及记录顺序，无需参考时刻；`ResolvedPack::to_xml_string` 与单条 `ResolvedRecord::to_xml_string` 输出可独立重读的文档。

根元素按标准命名为 `sensml`，记录元素为 `senml`，两者都必须处于 `urn:ietf:params:xml:ns:senml` 命名空间。接受默认命名空间或任意合法前缀。标准属性不带前缀；带前缀的其他属性作为扩展处理，不会因局部名称为 `v` 而变成测量值。命名空间声明单独处理，未知普通属性丢弃并计数，未知强制属性拒绝。

支持自闭合或成对记录标签、XML 1.0 声明、UTF-8 BOM、注释、处理指令、预定义实体及数字字符引用。记录值来自属性，非空文本和嵌套元素拒绝。根元素只接受命名空间声明。空文档容器与 JSON 的空包采用相同处理。

数值按 XML Schema 的词法读取：接受前导 `+`、前导零、`.5`、`1.` 及大小写指数，再转换为有效 JSON 数字文本供共享校验器使用。版本属性为整数词法；`+010` 可表示版本 10，`10.0` 不属于 XML 整数词法。布尔属性接受 `true`、`false`、`1`、`0`。`vd` 使用无填充 base64url。字段存在、空值和零值分别保留。

## 接入与输出预算

沿用 `ParseLimits`：输入代码单元、记录数、元素深度、每个元素的属性数、字符串和数字长度。属性数包含命名空间声明；标准命名空间 URI 为固定结构，不占测量字符串预算。底层读取器缓冲整个受限输入，单个事件内部的扫描由输入上限约束；该 API 不是增量字节流接口。

DTD 在测量读取前拒绝，返回 `UnsupportedXmlFeature`；接口不获取外部实体。当前数值继续使用共享有限 binary64 约定，拒绝非有限值和非零数下溢。其他编码声明也拒绝。语法错误返回固定的 `InvalidXml`，可带行列位置，不复制底层错误中的属性值。

输出默认使用 4 Mi UTF-16 单元的保守预算，在写入前计入属性转义开销。Writer 将属性中的制表符、换行和回车写为字符引用，重读时仍保留原值。JSON 中的 NUL 等字符无法在 XML 1.0 表示，转换返回 `InvalidXml`；不会替换为其他字符。SDK 另外检查实际输出字节数。

## 应用调用与验证

CLI 支持 `--from xml`／`--to xml`；SDK 支持 `from: 'xml'`／`to: 'xml'`，XML 结果类型为 `string`。CoAP 对应 Content-Format 为 `310`，`311` 的 SenSML 流继续由有限包接口拒绝。Node.js 回环例子已验证 XML 原始字节存储和业务重试。

```sh
moon build cmd/bridge --target js --release
node bin/senweave.mjs resolve examples/data/gateway.json --now 1793000000 --to xml
python scripts/senml_comparison/run.py --xml
```

XML 专项测试覆盖命名空间、词法、转义、清零、配额、全部截断前缀、DTD 和诊断。共同样本增加 38 项 XML 输入，并使用 Python ElementTree 独立产生／读取 XML，与固定 Go SenML 模块分别核对校验、原始编码和展开。运行结果与差异见[参考实现比较](comparison.md)。EXI 编解码仍待实现。

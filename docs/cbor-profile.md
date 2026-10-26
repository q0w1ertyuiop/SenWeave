# CBOR 约定 · 0.1.0-dev.4

`parse_cbor(bytes, limits?, max_input_bytes?)` 把 `application/senml+cbor` 数据包读入与 JSON 相同的 `Pack`。基字段继承、名称检查、版本 10、测量类型和错误处理复用现有实现。依据 [RFC 8428 §6](https://www.rfc-editor.org/rfc/rfc8428.html#section-6)，基础标签采用整数键，二进制值使用 CBOR 字节串。

## 调用与输出

```moonbit
let raw = @senweave.parse_json(
  "[{\"bn\":\"sensor:\",\"bt\":1793000000},{\"n\":\"temp\",\"v\":22.5}]",
)
let wire = raw.to_cbor_bytes()
let received = @senweave.parse_cbor(wire)
let readings = received.resolve()
let independent_wire = readings.to_cbor_bytes()
let independent_json = readings.to_json_string()
```

`Pack::to_cbor_bytes()` 保留原始记录顺序与基字段；`ResolvedPack::to_cbor_bytes()` 输出按时间排列的完整测量；单条 `ResolvedRecord::to_cbor_bytes()` 输出一个元素的数组。独立取出测量前仍需 `resolve`。

## 支持的编码

- 数据包必须是确定长度数组，每条记录必须是确定长度映射。文本和字节串同样采用确定长度；本版在整个输入中拒绝不定长项，包括未知扩展内部。
- 15 个已知标签使用 RFC 8428 的整数键。未知整数键、已知标签的文本别名以及其他键类型返回 `InvalidCborLabel`。扩展使用文本标签，普通扩展忽略，末尾 `_` 的未知扩展拒绝。
- 记录映射中的重复标签返回 `DuplicateKey`，包括未知文本扩展。未知扩展的嵌套结构由 CBOR 库解码后丢弃，内部映射不另做 SenML 标签或重复键检查。
- `vd` 必须是字节串，`vs` 必须是文本，`vb` 必须是布尔。空字节串、空文本、零和 `false` 都保留。UTF-8 由依赖解码器严格校验。
- 数字接受 CBOR 整数、binary16／32／64 浮点数及 Tag 4 十进制分数。分数必须是 `[整数指数, 整数尾数]`，使用标准 JSON 数字转换得到 binary64 投影，沿用有限数、非零下溢和数字文本长度检查。
- `bver` 的 CBOR 表示必须是无符号整数 10，浮点或 Tag 4 形式会被拒绝。

底层复用 [2515050242/cbor@0.1.2](https://mooncakes.io/docs/2515050242/cbor@0.1.2)，固定该版本。它要求整数参数和长度使用最短形式，整数范围为 `-2^63` 至 `2^64−1`；超出该范围的负整数和非最短参数编码返回 `InvalidCbor`。Tag 2／3 大整数不在本版范围内。该范围以外的测量可使用有限浮点表示；完整 RFC 输入形式的覆盖仍需后续扩展。

## 数字往返

CBOR 输入的整数会保留准确十进制文本，如 `9007199254740993` 和 `18446744073709551615`；`as_double()` 仍可能舍入。Tag 4 保留为 `尾数e指数`，例如 `123e-2`。浮点数没有原始十进制拼写，使用解码后的数字文本。

编码时，不含小数点或指数、且能由 64 位整数表示的普通整数字面量采用整数编码，`-0` 采用浮点编码以保留符号。其他数字使用 binary64 投影；例如 `9007199254740993.0` 转成浮点后原文会改变，但投影与原 JSON 的 binary64 投影一致。输出不保留十进制拼写、Tag 4 形式和普通未知扩展。

## 资源与错误

`max_input_bytes` 默认 `1048576`，必须为正数，在解码前检查。`ParseLimits.max_input_code_units` 只用于 JSON；CBOR 不使用它限制输入字节。

其他 `ParseLimits` 参数继续有效：记录数、每条成员数、数字文本长度和字符串 UTF-16 单元上限。CBOR 二进制值按字节计入 `max_string_code_units`。`max_depth` 按 CBOR 项层级计数：顶层数组是 1，记录映射是 2，键和值是 3，Tag 的内容额外增加一层。

调用通用解码器前，预检器先扫描字节头，检查完整输入、尾随内容、嵌套、容器数量及字符串声明长度。长度始终先与剩余字节比较，才转为机器索引，阻止巨大声明被截断或用于分配。未知扩展同样接受这一预检。无效编码返回 `InvalidCbor`，不定长或保留形式返回 `UnsupportedCborType`。

三个 `to_cbor_bytes(max_output_bytes?)` 默认采用 `4194304` 字节的保守预算。编码前按 Int64 累计 UTF-8、字节串、字段和容器头开销；超限返回 `OutputLimit`，参数非正返回 `InvalidLimits`。上界可能提前拒绝实际编码尚未达到上限的包；空包需要 1 字节。该预算约束输出，不作为整个进程的内存配额。

字段语义错误继续提供原始记录索引和字段名称；预检与底层编码错误可能没有记录索引。诊断不回显原始数值或二进制内容。失败不返回部分包。

## 复现验证

本批在 native、JS、wasm-gc 各运行 54 个测试。新增 19 个 CBOR 测试包含独立字节样本、准确整数边界、浮点宽度、Tag 4、二进制、重复标签、截断、巨大声明、不定长项、UTF-8 和资源上限。

Python 3.9 及以上可运行外部编码对照；使用独立虚拟环境安装测试依赖：

```sh
moon update
python -m pip install cbor2==5.7.1
python scripts/check_cbor_interop.py --target js
python scripts/check_cbor_interop.py --target native
python scripts/check_cbor_interop.py --target wasm-gc
```

脚本先用 Python `cbor2` 读取 MoonBit 输出，再用它生成包含 Tag 4、二进制、布尔和最大 UInt64 的数据包交给 SenWeave，核对原始值与展开结果。三个本地目标均通过；CI 另设 JS 对照任务。这验证了 CBOR 编码交换及选定场景，外部 SenML 库的完整语义对照尚未完成。

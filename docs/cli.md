# 离线检查与转换 · 0.1.0-dev.5

CLI 把文件与标准输入接到 SenWeave 库，可用于网关抓包检查、离线数据展开和 JSON／CBOR 转换。宿主需要 Node.js 24 及以上，核心逻辑由 MoonBit 编译；没有额外 npm 运行时依赖。

## 构建和运行

在仓库根目录运行，MoonBit 工具链要求同 README：

```sh
moon update
moon build cmd/bridge --target js --release
node bin/senweave.mjs --help
node bin/senweave.mjs check examples/data/gateway.json --now 1793000000
node bin/senweave.mjs resolve examples/data/gateway.json --now 1793000000 --name urn:dev:gateway:demo:temperature
node bin/senweave.mjs resolve examples/data/gateway.json --now 1793000000 --to cbor --output measurements.cbor
node bin/senweave.mjs resolve measurements.cbor --from cbor
```

最后一条命令输出已经展开的包，不需要再次提供参考时刻。重新执行写文件命令前须选择新的输出名称；已有文件和输入文件都不会被覆盖。二进制输出在 PowerShell 中建议使用 `--output`，避免旧版本 shell 重定向对字节流重新编码。

文件参数省略或写作 `-` 时读取标准输入。`--output -` 明确输出到标准输出；没有 `--output` 时行为相同。输入路径可以包含空格或中文；以 `-` 开头的文件名可放在 `--` 之后。构建完成后，命令可从其他工作目录通过脚本路径调用。

## 命令和参数

| 项目 | 行为 |
| --- | --- |
| `check` | 解析并验证完整展开，输出记录数、测量数和忽略扩展数的 JSON 摘要 |
| `resolve` | 展开、按时间排序，再筛选和输出独立测量 |
| `--from json\|cbor` | 输入格式，默认 `json`；CBOR 接收实际二进制字节 |
| `--to json\|cbor` | `resolve` 的输出格式，默认 `json` |
| `--now SECONDS` | 显式提供 POSIX 秒数，只有相对时间需要；不自动读取系统时间 |
| `--name FULL_NAME` | 按展开后的完整名称精确筛选，没有匹配时输出空包 |
| `--output FILE` | 校验成功后创建新的输出文件 |
| `--reject-extensions` | 普通未知扩展将被丢弃时拒绝输出 |

`check` 包含名称、类型、基字段、时间和算术检查；相对时间缺少 `--now` 会返回 `MissingReferenceTime`。`--name` 和 `--to` 只用于 `resolve`。所有语义边界与库一致，见 [展开约定](resolution.md)、[JSON 约定](json-profile.md) 和 [CBOR 约定](cbor-profile.md)。

## 数据和输出保护

文件在打开后检查是否为普通文件及大小，实际读取时还会逐块计数；标准输入也逐块计数。两种输入的上限都是 1 MiB。JSON 按 UTF-8 严格解码，无效字节拒绝；BOM 保留给 JSON 校验，因此不会被静默去除。

宿主只传递 JSON 原文，解析与序列化都在 MoonBit 中执行。返回宿主的是序列化文本，因此 `18446744073709551615` 不会因经过 JavaScript `Number` 而被改写。JSON／CBOR 本身的数值投影边界仍按库约定处理。

全部校验、展开、筛选和序列化完成后才输出。文件输出先在目标目录写完临时文件，再用独占硬链接创建目标；目标已存在时失败，临时文件随后清理。两个进程同时写同一新路径时只有一个成功。目标文件系统需要支持硬链接；不支持时返回 `OutputIO`，不改用覆盖写入。当前未验证掉电持久化。

输出实际字节数上限为 4 MiB，同时保留核心库的保守展开／编码预算。普通未知扩展默认丢弃，并在标准错误输出 `IgnoredExtensions` 提示；严格模式在写入前拒绝。CBOR 输出由宿主写原始字节。

## 诊断与复现

标准输出只包含成功的数据或摘要。错误写到标准错误，为单行 JSON，包含稳定错误码、固定说明，以及可用的原始记录索引、字段和 JSON 行列；不会回显原始测量值。退出码 `0` 表示成功，`1` 表示数据／时钟／体积／严格扩展检查失败，`2` 表示命令参数、构建或文件 I/O 失败。

```sh
node --test tests/cli.test.mjs
```

本批本地通过 12 项端到端测试，覆盖文件与管道、中文路径、大整数和字节串往返、重复键、时钟缺失、输入上限、覆盖拒绝、并发写入和临时文件清理。CI 在 Windows 与 Linux 上运行同一套检查。MoonBit 宿主桥逻辑另有 4 项测试，纳入三个后端的 58 项测试总数。

# Node.js SDK · 0.1.0-dev.16

SDK 为 Node.js 24 及以上提供 ESM／CommonJS 入口和 TypeScript 声明，解析、校验、展开和编码由编译后的 MoonBit 实现完成。宿主传递 JSON／XML 原文或 `Uint8Array`，测量数值不会先经 JavaScript 对象转换。当前接口面向 Node.js，浏览器构建尚未提供。

## 构建与安装本地分发包

从源码构建需要 README 所列 MoonBit 工具链；构建同时生成编译核心及两种模块格式的类型声明：

```sh
moon update
npm ci --ignore-scripts --no-audit --no-fund
npm run build
npm run test:sdk
npm run verify:package
```

最后一条命令重新构建并打包，生成 `_build/npm/q0w1ertyuiop-senweave-0.1.0-dev.16.tgz`，随后在临时项目中离线安装该文件并验证运行与类型。将 `.tgz` 复制到自己的应用目录后：

```sh
npm install ./q0w1ertyuiop-senweave-0.1.0-dev.16.tgz
```

应用可通过 `import` 或 `require()` 按包名加载，保留现有项目的模块配置。分发包已经包含编译后的核心和必要许可，运行时无需 MoonBit、TypeScript 或额外 npm 包。当前验证针对本地压缩包，npm／Mooncakes 注册表正式发布仍待完成。

## 调用方式

```js
import { check, resolve, SenWeaveError } from '@q0w1ertyuiop/senweave';

const input = '[{"bn":"s:"},{"n":"counter","v":18446744073709551615,"t":-3}]';
const options = { referenceTime: 1793000000 };
const summary = check(input, options);
const wire = resolve(input, { ...options, to: 'cbor', name: 's:counter' });
const standalone = resolve(wire.data, { from: 'cbor' });
console.log(summary.measurements, standalone.data);

try { check('[{"n":"x","v":1}]'); }
catch (error) {
  if (error instanceof SenWeaveError) console.error(error.code, error.diagnostic);
  else throw error;
}
```

CommonJS 项目使用相同接口：

```js
const { check, resolve, SenWeaveError } = require('@q0w1ertyuiop/senweave');
const input = '[{"n":"counter","v":9007199254740993,"t":1793000000}]';
const wire = resolve(input, { to: 'cbor' });
console.log(check(input).measurements, resolve(wire.data, { from: 'cbor' }).data);
```

两种入口共用同一份 CommonJS 实现，ESM 入口只转导出公开函数。在同一安装副本、同一进程中混用时，函数与 `SenWeaveError` 构造器保持相同引用，`instanceof` 可跨入口使用。公开 API 对象冻结；CommonJS 入口可以在禁用 `require(ESM)` 的 Node.js 进程中运行。

| 项目 | 行为 |
| --- | --- |
| `check(input, options?)` | 完整展开校验，返回 `valid=true`、`stage='resolved'`、`rawRecords`、`measurements`、`ignoredExtensions` |
| `resolve(input, options?)` | 返回 `{ format, data, ignoredExtensions }`；默认 JSON 文本，`to='xml'` 为 XML 文本，`to='cbor'` 为 `Uint8Array` |
| `from` | `json`、`cbor` 或 `xml`，默认 `json`；CBOR 必须提供实际字节，不接受十六进制字符串 |
| `referenceTime` | 显式 POSIX 秒，有限数或十进制字符串；相对时间必须提供，不自动读系统时钟 |
| `rejectExtensions` | 默认 `false`；`true` 时存在被丢弃的普通扩展即返回 `IgnoredExtensions` 错误 |
| `name` | 仅用于 `resolve`，在展开后按完整名称筛选；无匹配时输出空包 |
| `limits` | 按应用收紧输入、解析、展开和输出预算，未指定项使用默认值 |

`check` 不接收输出格式和筛选参数。未知参数、错误类型和空筛选名均拒绝。选项与预算只读取对象自身的数据属性，忽略原型上的设置，并拒绝访问器属性。输入不接收已经解析的测量对象数组，避免对象中的大整数在进入 MoonBit 前已经舍入。

JSON 也可以用 UTF-8 字节提供，严格拒绝无效序列；BOM 保留给 JSON 语法检查，`Uint8Array` 的偏移和长度均有效。宿主直接提供字符串时，先拒绝未配对 UTF-16 代理项，保证传入 MoonBit 的字符串满足 Unicode 不变量。SDK 按实际输入字节限制为 1 MiB，输出限制为 4 MiB，并保留核心库的记录、深度、字符串和展开预算。

输出 JSON 是文本。例中的 `18446744073709551615` 在 SDK 往返中保留；应用如果再调用 `JSON.parse` 将其变成宿主数值，会自行引入 JavaScript 数值精度边界。MoonBit 真实算术仍遵循 [binary64 展开约定](resolution.md) 和 [CBOR 约定](cbor-profile.md)。

## 按接入场景配置预算

例如网关每条消息最多 8 KiB、16 条原始记录，并为单次展开预留 64 Ki UTF-16 单元、输出预留 32 KiB：

```js
const limits = {
  maxInputBytes: 8192, maxRecords: 16,
  maxExpandedCodeUnits: 65536, maxOutputBytes: 32768,
};
const result = resolve(input, { referenceTime: 1793000000, rejectExtensions: true, limits });
```

| 预算项 | 默认值及允许的最大值 | 计量与检查阶段 |
| --- | ---: | --- |
| `maxInputBytes` | 1,048,576 | JSON／XML UTF-8 与 CBOR 字节，解码前检查 |
| `maxRecords` | 4,096 | 原始记录数，包含基字段上下文 |
| `maxDepth` | 32 | 包含未知扩展的完整嵌套深度 |
| `maxFieldsPerRecord` | 64 | 每条原始记录的成员数 |
| `maxStringCodeUnits` | 65,536 | JSON 字符串长度；CBOR 详见其输入约定 |
| `maxNumberCodeUnits` | 128 | 已知数值字段的十进制文本长度 |
| `maxExpandedCodeUnits` | 4,194,304 | 筛选前完整展开的保守 UTF-16 成本 |
| `maxOutputBytes` | 4,194,304 | 仅 `resolve` 使用；JSON 实际 UTF-8 字节，CBOR／XML 编码前保守成本 |

所有指定预算必须为正整数，且不得大于表内默认值；无效设置返回 `InvalidLimits`。预算只作用于当前调用，不修改全局默认值。CBOR 与 XML 成本为保守估计，可能拒绝实际编码后略小于预算的数据。JSON 在完整展开预算内序列化，再检查实际 UTF-8 输出字节；这不是流式内存预算。

`rejectExtensions` 在解析完成后、展开前执行，避免已被接入策略拒绝的数据继续参与算术或时间解算。筛选不会绕过原始包的记录、扩展和展开检查。更低的协议适配器上限仍然有效，例如 CoAP 接入的 8 KiB 上限由该适配器控制。

## 诊断与类型

`SenWeaveError.code` 是错误码，`.diagnostic` 为冻结的诊断对象，包含固定说明及可用的 `record_index`、`field`、`line`、`column`。`field` 只保留标准 SenML 标签，未知扩展名和测量值均不回显；重复键仍保留可用的行列位置。源码未构建或编译核心缺少当前接口时返回 `BuildRequired`；分发消费验证会检查核心文件及接口确实可用。

TypeScript 中默认 JSON 结果推导为 `string`，显式 `to: 'cbor'` 推导为 `Uint8Array`、`to: 'xml'` 推导为 `string`；动态格式返回可按 `format` 缩小的联合类型。分发检查使用 TypeScript 5.9.3 严格模式，既检查正确调用，也验证错误输入和未知参数会被类型检查拒绝。


NodeNext 按 `import`／`require` 条件分别解析 `dist/index.d.mts` 与 `dist/index.d.cts`；普通 CommonJS／Node 模块解析使用顶层 `types`。两份声明均由 `js/index.d.ts` 构建生成，校验脚本核对它们与源声明一致。分发验证使用 TypeScript 5.9.3，检查两种 NodeNext 入口及 CommonJS／Node 配置，并确认实际选中的声明文件。条件导出与类型格式分别依据 [Node.js 包文档](https://nodejs.org/docs/latest-v24.x/api/packages.html#conditional-exports) 和 [TypeScript 模块参考](https://www.typescriptlang.org/docs/handbook/modules/reference.html#node16-node18-node20-nodenext)。

## 二进制内容格式

已理解的 RFC 9193 `ct`／`bct` 使用同一校验类型并参与原始输出及二进制测量展开；严格扩展策略接受这两个字段。字段表示、语法、继承与预算见 [内容格式说明](content-formats.md)。

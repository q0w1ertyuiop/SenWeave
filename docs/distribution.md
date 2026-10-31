# 分发产物与独立消费验证 · 0.1.0-dev.15

仓库内的测试通过后，还需要确认拿到分发包的应用不依赖开发目录。当前保留两类实际产物：MoonBit 源码 ZIP 和包含编译核心的 npm `.tgz`。注册表正式发布尚未完成，此处不把本地归档消费等同于注册表安装。

## MoonBit 源码归档

```sh
python scripts/check_moon_package.py
```

Python 3.10 及以上、MoonBit 工具链和 native 所需 C 工具链即可运行，无额外 Python 包。脚本执行 `moon package`，检查生成的真实 ZIP 内容，然后只用解压后的文件创建另一个工作区：`library` 为归档源码，`consumer` 为独立模块。依赖通过 `moon.work` 关联，没有指回原仓库路径。

消费模块通过公开接口核对大整数、JSON／CBOR／XML 往返、业务键、延迟 CoAP 句柄完成、内容格式继承、诊断字段脱敏、原始 JSON 输出、CBOR 宽负整数往返和 Sender 重传／取消，并在 native、JS、wasm-gc 三个后端检查和运行。临时工作区完成后清理；原始 ZIP 保留在 `_build/publish/`。可用 `--target js` 单独运行一个后端。

`.moonignore` 使用明确的源码和文档目录清单。归档保留打包策略、Git 构建忽略规则和 npm 开发依赖锁，便于从解压源码继续构建。脚本另外检查最终路径和内容，拒绝非清单内隐藏项、构建目录及机器绝对路径；不依赖开发者的仓库本地 Git 忽略配置。配置语义见 [MoonBit 模块文档](https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html)。

## npm 分发包

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run verify:package
npm run test:sdk
```

验证脚本先构建编译核心，再用 `npm pack` 得到真实压缩包，按 [npm `files` 清单](https://docs.npmjs.com/cli/v11/configuring-npm/package-json/#files) 检查文件范围。在独立临时应用中通过本地 tarball 离线安装，禁用安装脚本，分别使用 ESM 导入和 CommonJS 加载，核对完整校验、大整数、CBOR／XML 交换、内容格式继承及混合加载时的错误类型身份；CommonJS 运行检查禁用 `require(ESM)`。随后以严格 NodeNext 模式同时检查两种 TypeScript 消费代码，并额外检查 CommonJS／Node 模块解析配置。类型检查对无效调用使用预期失败断言，声明文件出错或错误调用意外被接受都会使检查失败。

`import` 和 `require` 的类型条件分别指向构建生成的 `.d.mts`、`.d.cts`，两者使用同一份源声明。类型检查同时列出实际载入文件，确认两种格式均被消费。

产物保留在 `_build/npm/`，输出包括实际 tarball 完整性值。`dist/bridge.cjs` 来自本次 MoonBit release 构建；源码构建版本与 npm 版本不一致时拒绝生成。分发内容包含 stdlib、CBOR 与 XML 依赖的原始 LICENSE／NOTICE，构建时从实际依赖中复制。

SDK 的 20 项测试包含两种模块入口的共享身份和无 ESM 加载依赖检查，并覆盖严格 UTF-8、切片字节、扩展准入顺序、八项应用预算、选项属性、诊断脱敏和筛选。独立 npm 消费还检查预算、严格扩展策略和诊断行为，TypeScript 检查包含预算类型及未知预算项。CI 在 Windows 与 Linux 运行分发验证，源库原有三个后端的测试及 CLI／UDP／互操作任务继续保留。

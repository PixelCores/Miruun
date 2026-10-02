# Miruun

Miruun 是原生 macOS 菜单栏小工具，面向这样的工作流：在 Codex GUI 使用账号 A 建立对话，通过 CC Switch + CLIProxyAPI 切到账号 B，重启 Codex 后继续原来的工作。

一次启用后，Miruun 在后台维护统一的本地代理入口，不需要选择某一条对话。当前实现覆盖同一 `CODEX_HOME` 中由内置 `openai` 创建的所有历史；保留原 ID、项目、模型和历史文件。它不会扫描或批量改写对话，也不提供账户池或新的代理服务。

**当前是实验实现：本机配置守护与合成测试不等于已经通过真实账号 A → B 的 GUI 续聊验收。** 自定义 provider 历史、正在运行的会话热切换、跨账号加密上下文和上游账户归属仍有独立边界，见 [验证记录](VALIDATION.md)。

## 使用

1. 将打包后的 `Miruun.app` 放到固定位置并打开，选择 Codex 实际使用的数据目录，通常为 `~/.codex`。
2. 勾选“启用后台连续性守护”。也可选择“登录 Mac 时启动 Miruun”。之后关闭窗口即可，日常状态只显示在菜单栏。
3. 在 CC Switch 配好 CLIProxyAPI 的本地 Responses 入口与代理 API key，由代理管理账号 B。Miruun 不替你登录，也不写入凭据。
4. 等待菜单栏提示配置已就绪，再重启 Codex GUI，直接打开任意原生 `openai` 历史继续。
5. 首次实际使用时，检查多个原对话的上下文和同次代理请求的上游账号。成功响应或模型名称不能单独证明请求由账号 B 处理。

守护每两秒检查配置和认证文件；两次稳定采样后才调整配置。暂停或退出守护会保留当前配置；需要更换数据目录时先暂停。回到 OAuth 登录时，守护仅移除自己标记的代理入口；遇到未标记的地址覆盖会提示处理，不擅自恢复旧文件。正常检查没有弹窗、通知或网络请求，不会启动 Codex 后端。登录项使用 macOS 13+ 的 `SMAppService`，未经签名构建的系统注册行为仍需实机验收。

## 配置契约

根 `model_provider` 保持为 `openai`，根 `openai_base_url` 指向 CC Switch 当前选中的本地代理。Codex 冷恢复保留历史 provider ID，再从当前配置解析其地址，所以无需逐条迁移历史。所有新建对话也继续使用相同 ID；之后切换账号由代理负责。

当前仅接受明确的本地入口（`localhost`、`127.0.0.1`、`[::1]`），Responses 协议，以及文件中的 API-key 认证。自定义 provider 必须明确使用全局 OpenAI 认证。无法保留的自定义认证、请求头、查询参数、profile、Keychain 和未知配置语法会显示原因并停止调整；不会猜测有效运行配置。已有自定义 provider 历史不会自动改为 `openai`，其 GUI 可见性也不能由本工具保证。

Miruun 只写所选目录的 `config.toml`，读 `auth.json` 判断认证方式。状态与日志不展示凭据，也不会备份认证文件；配置文件本身可能含敏感字段，因此原配置备份只保存在本机 `~/Library/Application Support/Miruun/ConfigBackups/`（目录 0700、文件 0600）。配置修改采用临时文件、重核对和原子替换；这不能给不合作的外部写入者提供事务锁。请等 CC Switch 完成切换、Miruun 配置就绪后再启动 Codex。

[OpenAI 官方高级配置](https://developers.openai.com/codex/config-advanced/)说明 `openai_base_url` 的用途，但它不改变认证。源码核对基于 Codex 0.159.2；GUI 外部认证、管理员策略、启动参数和不同数据目录可能影响实际行为。原模型、Responses/WebSocket 与历史中的加密内容也需要目标代理和账号支持。

## 构建与开发

要求 macOS 13+、Swift 5.9+ 和包含 XCTest 的完整 Xcode。在仓库根目录执行，或双击 `Build App.command`：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash "Build App.command"
```

脚本先运行全部测试，再编译 Release 并组装 `dist/<时间戳>/Miruun.app`。它不安装、不启动应用，也不读取真实 Codex 数据。每次输出独立目录。

```bash
swift test
swift build -c release
bash scripts/build-app.sh --no-reveal
```

受限开发环境可为脚本显式追加 `--disable-sandbox`。开发工具中的 SwiftPM 沙盒与应用的数据保护是独立设置。请运行完整 `.app`；`swift run Miruun` 缺少正确的 bundle 信息，不能启用守护。

## 项目结构

| 路径 | 职责 |
| --- | --- |
| `Sources/Miruun` | 菜单栏、设置、后台调度、系统登录项 |
| `Sources/BridgeEngine/ContinuityGuard.swift` | 配置判定、稳定采样、备份及原子调整 |
| `Sources/BridgeEngine/ProviderCatalog.swift` | 复用保守的 TOML 解析与配置校验 |
| `Sources/MiruunEngine`、其余 BridgeEngine / BridgeCore / CSQLite | 初始化时保留的单次修复引擎与协议；当前 GUI 不调用，不是后台批量迁移入口 |
| `Tests` | 隔离临时目录中的合成配置、存储、协议与状态测试 |

应用使用 Swift、AppKit、Foundation、CryptoKit、ServiceManagement 和系统 SQLite3，没有第三方 Swift 包或 Python 运行依赖。旧单对话 UI 已被后台守护替代，旧 helper 不具备原 GUI 的持久未决保护，不应自行调用它执行真实切换。历史备份与未决记录不会自动删除。

[产品说明](docs/product.md)记录当前范围；[代码分析](docs/analysis.md)记录初始化与新方向的依据。图标母版尚未提供，菜单栏使用系统符号；Developer ID 签名、公证和洁净机器验收尚未完成。

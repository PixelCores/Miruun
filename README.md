# Miruun

Miruun 是原生 macOS 菜单栏小工具，面向这样的工作流：在 Codex GUI 使用账号 A 建立对话，通过 CC Switch + CLIProxyAPI 切到账号 B，重启 Codex 后继续原来的工作。

一次启用后，Miruun 在后台维护接入配置，并提供“打开 Codex”入口：自动检查当前配置与认证，准备完成后再启动 Codex，不需要手动等待状态或选择某一条对话。当前实现覆盖同一 `CODEX_HOME` 中由内置 `openai` 创建的历史，并在切回官方 ChatGPT/OAuth 登录后补齐缺失的 `custom` 定义，让该 ID 的旧历史可以再次解析接入配置；保留原 ID、项目、模型和历史文件。它不会扫描或批量改写对话，也不提供账户池或新的代理服务。

**当前是实验实现：用户已确认停用代理、回到账号 A 后能够继续 `custom` 历史对话，但完整账号 A → B → A 的 GUI 续聊仍未完成验收。** `custom` 历史的列表可见性、其他 provider ID、正在运行的会话热切换、跨账号加密上下文和上游账户归属仍有独立边界，见 [验证记录](VALIDATION.md)。

## 使用

1. 将打包后的 `Miruun.app` 放到固定位置并打开，点击菜单栏土星图标可显示毛玻璃浮窗。在“设置”中选择 Codex 实际使用的数据目录，通常为 `~/.codex`。
2. 返回概览开启守护，也可开启“自动打开”，并从 Finder 将 `Miruun.app` 拖入 Dock，以它作为日常启动入口。设置中也可选择“登录 Mac 时启动 Miruun”；登录项启动仍保持静默。
3. 在 CC Switch 配好 CLIProxyAPI 的本地 Responses 入口与代理 API key，由代理管理账号 B。支持 Key 已保存在 Codex 文件认证中，或由当前 custom provider 的 `experimental_bearer_token` 提供。
4. 正常退出 Codex GUI 及其他 Codex 后端，再点击浮窗概览中的主要按钮“打开 Codex”。Miruun 重新检查配置，按需备份配置与认证、接入已有代理 Key，准备完成后启动 Codex，使用所选数据目录；打开任意原生 `openai` 历史继续。
5. 首次实际使用时，检查多个原对话的上下文和同次代理请求的上游账号。成功响应或模型名称不能单独证明请求由账号 B 处理。
6. 停用 CC Switch + CLIProxyAPI、切回账号 A 时，先恢复官方 `openai` 入口及文件 ChatGPT/OAuth 登录，再退出 Codex 并通过 Miruun 打开。守护会补齐缺失的 `custom` 历史接入并移除自己管理的本机地址，然后启动 Codex，回到原对话。

守护每两秒检查配置和认证文件；两次稳定采样后才调整配置。所有配置与认证写入均等待 Codex 客户端及后端退出。启动入口仅在守护启用时可用，复用新的检查结果，不使用上一次“就绪”状态；尚未就绪或客户端仍运行时保持等待，不强制退出。重复点击合并为一次启动请求；暂停或退出会取消尚未发出的启动并保留当前配置；错误显示在状态中。需要更换数据目录时先暂停。

模式取决于当前配置与认证，不以代理在线状态猜测。回到 OAuth 登录时，守护仅清理自己标记的本机地址并维护 `custom` 定义；遇到未标记的根地址覆盖会提示处理，不擅自恢复旧 OAuth 备份。正常后台检查没有弹窗、通知或网络请求，也不会自行启动 Codex。登录项使用 macOS 13+ 的 `SMAppService`，未经签名构建的系统注册行为仍需实机验收。

桌面版启动会合并登录 shell 环境。“打开 Codex”在配置就绪后预检 shell 使用的 `CODEX_HOME`，仅获取该变量；固定目录覆盖、无法确认或 shell 执行失败时停止启动，原始输出不显示。预检后再次检查配置和客户端。两次采样至少间隔两秒，慢检查不会触发紧接着的补采样。按父进程、工作目录或命令内容分支的 shell 配置不在支持保证内，详见验证记录。

浮窗概览保留守护与自动打开两行开关、一处实际状态入口和主要“打开 Codex”按钮；底部提供设置与退出。设置子页包含数据目录、配置备份和登录项，底部“返回”回到概览。状态子页可滚动查看并选择复制完整文字。半透明背景由系统合成，会随桌面内容与辅助功能设置变化。

自动打开已开启且守护启用后，手动双击、执行 `open "/完整路径/Miruun.app"` 或再次打开运行中的 Miruun，直接进入准备与启动流程；启动出错时打开完整状态子页。自动打开关闭或守护暂停时，手动打开显示浮窗，启用守护后可使用“打开 Codex”。再次点击土星图标、按 Esc 或切到其他应用仅收起界面，不暂停守护，也不取消待启动请求；后台检查更新状态时不会反复弹出浮窗。`⌘,` 打开设置，`⌘Q` 或底部“退出”正常结束 Miruun，并等待当前配置检查完成。直接使用原 Codex 图标启动不经过 Miruun，无法保证配置先准备完成；已经运行的对话不会热切换，需要正常退出后重新打开。

## 配置契约

使用本机代理时，根 `model_provider` 保持为 `openai`，根 `openai_base_url` 指向 CC Switch 当前选中的本地代理。Codex 冷恢复保留历史 provider ID，再从当前配置解析其地址，所以无需逐条迁移历史。所有新建对话也继续使用相同 ID；代理模式下切换账号由代理负责。

当前仅接受明确的本地入口（`localhost`、`127.0.0.1`、`[::1]`）与 Responses 协议。支持两种代理认证：`requires_openai_auth = true` 使用既有文件 API Key；或 `requires_openai_auth = false` 且 `experimental_bearer_token` 明确提供代理 Key，此时先备份原认证，再写为 Codex 的 `apikey` 文件认证。认证文件原来不存在也可接管。其他自定义认证、请求头、查询参数、profile、Keychain 和未知配置语法会显示原因并停止调整；不会猜测有效运行配置。

2026-10-03 合并的修复处理 `Model provider custom not found`：仅当当前 provider 为原生 `openai`（或省略）、使用文件 ChatGPT/OAuth 认证且缺少 `custom` 定义时，追加带 `# miruun-managed-custom-provider` 标记的 `[model_providers.custom]`，设置 `name = "OpenAI"`、`wire_api = "responses"`、`requires_openai_auth = true`。OAuth 下不写 `base_url`，由 Codex 按认证模式选择官方入口；之后切回受支持的本机 API Key 代理时，已管理的 `custom` 定义同步到原生入口，回到 OAuth 时再次移除其本机地址。已有未标记的 `custom` 定义保留；已管理定义被修改、包含额外字段或非本机地址，以及无法安全追加的 TOML 会停止调整。历史中的 `custom` ID 不变；其他历史 provider 不会自动修复，GUI 列表可见性仍取决于客户端筛选。

Miruun 读取所选目录的 `config.toml` 与可选的 `auth.json`。接管 provider 自带的 Key 时会写入 API Key 认证文件；不会创建新 Key、改变上游账号凭据或改写历史。状态与日志不展示 Key。配置和原认证的备份包含敏感信息，只保存在本机 `~/Library/Application Support/Miruun/ConfigBackups/`（目录 0700、文件 0600）。两份文件各自采用临时文件、重核对和原子替换，先提交代理认证，再设置本机地址；这不能让两份文件或其他程序共同参与原子事务。提交异常会保留备份与未决记录，重开 Miruun 也不会自动重试或恢复旧凭据。请等 CC Switch 完成切换后，通过 Miruun 打开 Codex。

[OpenAI 官方高级配置](https://developers.openai.com/codex/config-advanced/)说明 `openai_base_url` 的用途，但它不改变认证。源码核对基于 Codex 0.159.2；GUI 外部认证、管理员策略、启动参数和不同数据目录可能影响实际行为。补齐的 `custom` 定义默认使用 HTTP SSE，不承诺与 builtin `openai` 的 WebSocket 能力等价。原模型与历史中的加密内容也需要目标代理和账号支持。

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
| `Sources/Miruun` | 菜单栏浮窗、设置与状态、后台调度、系统登录项 |
| `Sources/BridgeEngine/ContinuityGuard.swift` | 配置判定、稳定采样、备份及原子调整 |
| `Sources/BridgeEngine/ProviderCatalog.swift` | 复用保守的 TOML 解析与配置校验 |
| `Sources/MiruunEngine`、其余 BridgeEngine / BridgeCore / CSQLite | 初始化时保留的单次修复引擎与协议；当前 GUI 不调用，不是后台批量迁移入口 |
| `Tests` | 隔离临时目录中的合成配置、存储、协议与状态测试 |

应用使用 Swift、AppKit、Foundation、CryptoKit、ServiceManagement 和系统 SQLite3，没有第三方 Swift 包或 Python 运行依赖。旧单对话 UI 已被后台守护替代，旧 helper 不具备原 GUI 的持久未决保护，不应自行调用它执行真实切换。历史备份与未决记录不会自动删除。

[产品说明](docs/product.md)记录当前范围；[代码分析](docs/analysis.md)记录初始化与新方向的依据。菜单栏使用绘制的土星图标；应用图标母版、Developer ID 签名、公证和洁净机器验收尚未完成。

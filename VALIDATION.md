# Miruun 验证记录

## 未发布：启动前自动准备接入配置

日期：2026 年 10 月 3 日。基于 `main@1a43f2dae5fee5ce7d4fbebc60a9fe4872747d4d`；本次不调整应用版本号。

新增菜单与设置中的“打开 Codex”，以及“打开 Miruun 时自动打开 Codex”选项。启动请求复用串行守护与两秒定时检查，重新读取当前配置和认证，确认相同样本及客户端退出后，通过 `NSWorkspace` 启动 `com.openai.codex`，传入所选 `CODEX_HOME`。暂停或退出取消尚未发出的请求；系统登录项仍静默。

| 验证 | 结果 |
| --- | --- |
| 全量 XCTest | 124 项通过，0 失败（BridgeEngine 111、BridgeCore 13） |
| 连续性守护 | 41 项通过；新增 5 项启动前检查回归，全部使用临时合成配置与注入的进程状态 |
| Release 与打包 | Miruun / MiruunEngine 成功，日志无 warning 或 error；plist 校验通过 |
| 独立复核 | 检查主线程与 worker 边界、请求合并、暂停/退出取消、旧回调失效及失败状态保留；未发现未解决问题 |
| GUI | 实际打开包含启动入口的先行包；官方配置就绪，菜单和设置均有启动入口，自动打开选项可见 |
| 活跃客户端与暂停 | 点击启动后按钮禁用并等待已有 Codex 退出；暂停取消请求，重新启用后按钮恢复，无 Codex 重启 |
| 手动再次打开 | 勾选自动打开后关闭设置，通过 Finder 双击同一应用进入等待启动流程；再次暂停并启用后请求取消，自动打开偏好保留 |

新增测试覆盖官方与代理的配置无需写入时仍等待客户端、首次就绪配置也需稳定采样、客户端退出后重新采样、较早就绪结果不掩盖新配置变化、不支持的新配置拒绝，以及无法确认进程状态时不写入文件。

随后核对本机桌面包 `26.928.21956`，发现登录 shell 可能覆盖传入的目录。补上目录预检及 4 项进程测试，覆盖 shell 元字符与中文路径、初始化输出、覆盖或 unset、非零退出，以及临时 HOME 中真实 zsh 的 `.zprofile` 覆盖；不执行用户的真实登录 shell。检查后重新读取配置和客户端，并改为单次 timer 完成后隔两秒重新安排，防止慢检查导致紧接着补采样。

构建命令：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-app.sh --no-reveal --disable-sandbox
```

最终产物：`dist/20261003-135308-3064/Miruun.app`。日志：`/private/tmp/miruun-mode-launch-final-build.log`。GUI 验证用先行产物 `dist/20261003-133049-91459/Miruun.app`，截图为 `/private/tmp/miruun-mode-launch-ui.png`。已正常退出旧 Miruun 并运行先行包，保留原守护启用状态并开启自动打开选项；当前没有待启动请求。最终包打包后 Mac 锁屏，未切换到最终包。未关闭当前 Codex，未发送真实回合，也未读取真实会话或数据库。

边界：**本次没有通过新入口实际冷启动 Codex，也没有完成两种真实模式的往返续聊验收。** `CODEX_HOME` 的传递与异步成功/失败回调已按本机 AppKit SDK、安装包和代码复核，尚无真实启动的运行证据。目录预检能识别固定导出冲突，无法证明按父进程、cwd 或命令内容分支的任意 shell 脚本与桌面启动完全等价；这些覆盖不在支持保证内。外部程序可在最后检查后再次写配置或启动客户端；此入口不控制这些程序，不提供活动会话热切换，也不按代理在线状态恢复旧凭据。系统登录项静默、Dock 固定、签名及洁净机器仍需实机验收。

## 已合并：官方登录恢复 custom 历史

日期：2026 年 10 月 3 日。基于 `main@caa3d27539f9d21823392e551d42dde0824f5802`；本次不调整应用版本号。

修复停用 CC Switch / CLIProxyAPI、回到官方登录后，历史仍引用 `custom` 而当前配置已删除该定义导致的 `Model provider \`custom\` not found`。仅在当前原生 `openai` 配置和文件 OAuth 认证下补齐缺失定义；已有非管理定义保持原样。管理 alias 随后续本机代理接入同步地址，OAuth 回切时移除地址，不读取或改写真实历史。

| 验证 | 结果 |
| --- | --- |
| 全量 XCTest | 115 项通过，0 失败（BridgeEngine 102、BridgeCore 13） |
| 连续性守护 | 36 项通过；新增 9 项，调整原 OAuth 测试，全部使用临时合成数据 |
| Release 与打包 | Miruun / MiruunEngine 成功，日志无 warning 或 error；plist 校验通过 |
| 独立代码复核 | 路由、认证、管理块归属与既有写入事务未发现未解决问题 |
| 实际 Codex 隔离复现 | `codex-cli 0.159.2` 创建 custom 对话后删除定义，无 provider/model 覆盖的冷恢复精确复现原报错 |
| 兼容定义与往返 | 合成 OAuth + 无 base_url 的 alias 恢复同一 ID/custom；再切到新 localhost mock 入口，同一对话继续并重放历史输入与回复 |

新增回归覆盖 OAuth 首次补齐及幂等、认证字节与 inode 保留、备份、LF/CRLF 与末尾换行、根 API 入口及两类选中代理认证的 alias 同步、OAuth 回切清理两处地址、既有非管理普通/inline 定义保留、管理块篡改与注释伪表头拒绝、sealed/畸形/超限配置、活动客户端及提交前配置冲突。首次测试发现 Swift 字符串换行判断在 CRLF 下多插入空行；按 UTF-8 换行字节修正后，全量通过。

构建命令：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-app.sh --no-reveal
```

本机产物：`dist/20261003-113051-69777/Miruun.app`。日志：`/private/tmp/miruun-custom-provider-build.log`。未安装或启动该产物，未修改真实 Codex 配置、认证或会话。

独立后端验证脚本为 `/private/tmp/miruun-custom-alias-contract.py`；汇总、完整 RPC 和 mock HTTP 请求保存在 `/private/tmp/miruun-codex-contract-8sz3bfn9/`。所有 `thread/resume` 只传 thread ID 和 `excludeTurns`，没有指定 provider/model。后端使用隔离 HOME/CODEX_HOME、合成认证和历史；沙盒禁止访问 `/Users` 和外网，仅允许两个临时 localhost 端口。这些临时文件不是发布依赖。

后续用户验证：重启修复包后，用户确认停用代理、回到账号 A 可以继续原 `custom` 历史对话。PR #1 已合并到 main，合并提交为 `1a43f2dae5fee5ce7d4fbebc60a9fe4872747d4d`。该反馈验证了报告的故障场景；未独立检查官方响应的账户归属，也不代表完整 A → B → A、全部历史或其他连接行为已经验收。

隔离测试边界：合成 OAuth 的实际推理在外网隔离下停于 `workspace routing discovery failed`；加密/压缩上下文与 WebSocket 仍未验证。`thread/list` 默认仍按当前 provider 筛选，`modelProviders = []` 才包含所有 provider；本修复不改变 GUI 各列表的筛选方式，也不将历史 provider 改成 `openai`。Keychain、外部认证和配置覆盖继续遵循现有支持边界。

## 0.4.1 代理认证接入与启动修复

日期：2026 年 10 月 2 日。以下为 0.4.1 当日证据；后面的 0.4.0、0.3.1 为更早记录。

| 验证 | 当前结果 |
| --- | --- |
| 全量 XCTest | 106 项通过，0 失败（BridgeEngine 93、BridgeCore 13） |
| 连续性守护测试 | 27 项通过，全部使用临时合成数据目录与注入的进程状态 |
| Release 构建与打包 | Miruun / MiruunEngine 成功，日志无 warning 或 error；plist 校验通过 |
| 独立复核 | 修正两文件提交顺序：先认证，再配置；再次复核确认该问题消除 |
| 最终 GUI | 0.4.1 设置窗口实际打开，顶部布局正常，保留用户已启用的守护；实际配置被识别，显示等待 Codex/ChatGPT 及后端退出 |
| 手动再次打开 | 已用相同启动修复的先行 0.4.1 包验证：关闭窗口后再次执行 open，设置重新显示；最终包已验证首次显示及退出旧版的 Cmd+Q |
| 本机代理只读检查 | 当前配置 Key 在内存中用于 localhost:8317 的 GET /v1/models；HTTP 200，26 个模型中包含当前配置模型；没有打印 Key 或发送真实回合 |
| 实际 Codex 后端隔离验证 | 内嵌 codex-cli 0.159.2 在合成 HOME/CODEX_HOME 中识别 API Key 认证，冷恢复同一线程后向新的 mock 入口携带预期 Bearer 和历史输入、回复 |

新增回归包括：缺失 auth 的等待状态、inline bearer 建立 API Key 文件认证、原 OAuth 字节备份、相同 Key 不重写认证文件、配置或认证变化后重新采样、活动及未知客户端门、提交前冲突、认证提交后的客户端启动与文件冲突、未决记录阻止同实例及重开后的重试，以及不同数据目录互不阻塞。备份目录 0700、文件 0600；状态和阶段回执不包含 Key。认证提交后、配置提交前中断时保留原 custom 配置、已提交认证与 pending，文案明确可能未完整完成。

实际后端验证使用 `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`。独立 app-server 使用合成凭据、模型和两轮输入；macOS 沙盒只允许两个随机 localhost 端口，并禁止读取或写入 `/Users`。验证先在一个 mock 入口建立内置 openai 对话并保存首轮，再关闭后端、切换入口、无模型/provider 覆盖地恢复同一 ID。第二个入口确认请求包含第一轮输入、mock 回复和第二轮输入。

该验证使用 HTTP SSE，mock 拒绝 WebSocket 后客户端回退；未覆盖真实代理的 WebSocket、账号 B、GUI 登录态、加密 reasoning 或压缩历史。运行结果保存在本机临时目录 `/private/tmp/miruun-codex-contract-9wux3n2q/result.json`，合成复现脚本为 `/private/tmp/miruun-codex-contract.py`；这些临时文件不作为发布依赖。

最终应用：`dist/20261002-215833-23422/Miruun.app`，版本 0.4.1 / build 3。完整构建日志：`/private/tmp/miruun-0.4.1-final-build.log`。构建沿用下方 Xcode 命令。当前 Codex 仍在运行，Miruun 已启用并等待退出，实际 `auth.json` 仍不存在；尚未执行真实两文件接管，也未读取真实会话或数据库。

接下来的真实验收由用户退出当前 Codex 后进行：保持 Miruun 与 CLIProxyAPI 运行，等待配置就绪，再打开多个原生 openai 对话主动续聊，并对照代理日志确认账户 B。配置就绪不代表这些运行结果已经通过。登录项静默启动、Developer ID 签名、公证及其他系统/架构的分发验收仍未完成。

## 0.4.0 后台连续性守护

日期：2026 年 10 月 2 日。当前 GUI 已替换单线程选择/确认流程，下方 0.3.1 部分仅为初始化历史证据。

| 验证 | 当前结果 |
| --- | --- |
| 全量 XCTest | 94 项通过，0 失败、0 跳过（BridgeEngine 81、BridgeCore 13） |
| 新增守护测试 | 15 项，全部在临时合成 CODEX_HOME 中运行 |
| Release 构建与打包 | Miruun / MiruunEngine 成功；最终编译日志无 warning 或 error |
| 代码复核 | 独立复核认证门、原子写入及 UI 串行启停；修复外部/未知认证误判与 null 模式拒绝 |
| GUI 冒烟 | 实际打开设置页，确认初始守护关闭、路径可读、勾选项与状态可见；未启用真实守护或系统登录项 |
| 配置与文档 | plist、git diff --check 通过，产品文档已区分当前守护与旧单线程引擎 |

守护测试覆盖：两次稳定采样、config/auth 变化重置采样窗口、仅调整根路由键、保留模型/注释/CRLF、备份与文件权限、幂等检查不重复备份、API Key/OAuth/混合/外部/未知/null 认证、仅移除标记的 OAuth 回切地址、loopback 与 Responses 校验、profile/Keychain/特殊 provider 拒绝、链接/硬链接/FIFO/超限文件与不安全备份目录拒绝。没有访问真实 config/auth、历史或数据库，没有运行真实后端或向代理发请求。

GUI 首次检查发现滚动文档顶部留白和退出快捷键缺失，已分别以 flipped 文档视图与应用菜单修复并重新编译。最终包静默启动后的界面复核工具超时，因此这两项交互修复仍缺少最终包的视觉/键盘复验。系统登录项、启用/暂停的实际界面操作、强退与重开均仍需完整 UI 验收。

最终产物：`dist/20261002-204538-86210/Miruun.app`，版本 0.4.0 / build 2。临时日志：`/private/tmp/miruun-continuity-build.log`。构建命令沿用下方 Xcode 命令；执行沙盒限制 SwiftPM 子沙盒启动，改在常规本机环境中运行后成功。

仍未证实的核心产品边界：

- 真实 CC Switch 写入顺序与 GUI 重启之间的配合，以及配置来源覆盖。
- 账号 A 创建的多个原生 openai 对话，经账号 B 续聊后的上下文、模型和工具状态。
- CLIProxyAPI 最终账户 B 的请求与计费归属；稳定地址与 HTTP 成功不是账户证据。
- 跨账号的加密 reasoning、压缩历史、WebSocket 重连及完整重放。
- 其他历史 provider、Keychain/外部认证和非默认配置覆盖不属于当前支持保证。
- 登录项系统授权、签名、公证、Intel/macOS 13 与洁净机器分发。

下一步应在用户控制下完成多个原对话的 GUI 续聊，并对照同次代理日志。配置检查“就绪”只表示本地文件符合当前契约。

## 0.3.1 初始化历史

日期：2026 年 10 月 2 日。本记录对应 Miruun 初始化后的本地源码，替代原交付中仅有静态检查、Swift 测试尚未执行的状态。

## 本次实际通过

环境：Apple Silicon、macOS 27.0（26A428），使用 `/Applications/Xcode.app/Contents/Developer` 的 Apple Swift 6.4。当前系统选择的 Command Line Tools 提供 Swift 6.3.3，但缺少 XCTest；没有修改系统开发工具选择。

完整本机构建命令：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/miruun-xcode-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/miruun-xcode-swift-cache \
bash scripts/build-app.sh --no-reveal
```

| 验证 | 结果 |
| --- | --- |
| XCTest | 79 个测试，0 失败、0 跳过 |
| Release 编译与链接 | Miruun、MiruunEngine 均成功 |
| 应用打包 | 两个 arm64 Mach-O 可执行文件及 Info.plist，菜单栏 bundle 设置正确，最低系统元数据为 13.0 |
| 构建脚本与 plist | 两个脚本 bash -n 通过，plist 校验通过，脚本和二进制保留执行权限 |
| 打包 helper 冒烟 | 无效 JSON、未知命令、缺少切换同意均返回关联的脱敏失败结果并在变更前停止 |
| CI 配置 | YAML 解析通过；已配置 macos-15 测试、release 打包及保留可执行权限的 ZIP 产物 |
| 原交付保护 | 对全部原交付文件计算 SHA-256，初始化前后内容一致 |

测试构成：13 个 BridgeCore 状态/协议测试、6 个入口安全门测试、8 个 NativeEngine 跨层测试、6 个实际合成子进程/协议探测测试、12 个原生存储测试、9 个事务测试、25 个 provider/TOML 测试。

跨层测试验证备份先于恢复、原 ID 与模型保留、独立验证进程无 provider/model 覆盖、确认消费，以及配置、身份、队列、后端版本和备份异常时的停止或锁定。实际管道测试使用临时 shell 后端，验证握手、截断/损坏输出、意外回合、请求关联超时和禁止 turn/start。存储测试包含权限、链接/FIFO 拒绝、已提交 WAL 数据、孤立快照只读查询和不完整证据保留。

源码和测试本身没有新增第三方 Swift 包或 Python 运行依赖。初始化过程中用本机脚本检查产物，不把检查工具打入应用。

构建产物：`dist/20261002-161814-45484/Miruun.app`。完整构建日志保存在本机临时文件 `/private/tmp/miruun-build.log`，临时日志不作为永久产品记录。

受限执行环境中，首次 release 生成 dSYM 被执行沙盒拒绝；随后在常规本机执行环境中运行同一构建脚本，测试、release 和打包均成功。没有为解决环境限制删除测试或弱化应用安全门。

## 尚未验证

- AppKit 视觉布局、小屏确认面板、键盘导航与 VoiceOver。
- 实际安装 Codex 后端的启动、协议响应、客户端进程检测与持久化行为。
- 强制退出、重开及 orphan backend 场景下的端到端行为。
- 真实私人存储备份、同线程切换、GUI 原对话续聊、实际路由、上游账户和计费归属。
- macOS 13 机器、Intel/x86_64 或通用二进制运行验收。
- Developer ID 签名、公证、Gatekeeper、图标资源和洁净机器安装体验。
- GitHub 托管 CI 的实际运行；本记录仅覆盖本地验证。

本次没有读取真实 Codex 会话、凭据或数据库，也没有对真实线程发恢复请求。通过测试及后端设置验证仍不能替代用户在原 GUI 中的主动续聊验收。

## 下一阶段验收

1. 使用一次性合成 CODEX_HOME 检查界面空状态、长标题、选择变化、取消与过期确认、小窗口和滚动。
2. 在合成后端中注入超时、意外回合、输出损坏、进程异常和保存失败；确认回执与 0700/0600 证据保留。
3. 合成操作中强退后重开，应只读锁定、没有旧同意重用；活动后端或操作锁应拒绝并行复核。
4. 完成这些验收后，经明确同意选择一个真实原对话，分别验证原 ID/项目/模型、冷恢复设置、原 GUI 身份、主动回复与预期服务路径。
5. 纳入图标母版，再完成签名、公证和支持平台的洁净机器验收。

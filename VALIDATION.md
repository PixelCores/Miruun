# Miruun 验证记录

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

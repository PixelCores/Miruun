# Miruun 0.3.1 验证记录

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

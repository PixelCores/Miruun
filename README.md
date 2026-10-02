# Miruun

Miruun 是实验性的原生 macOS 菜单栏工具：为一个已存在的 Codex 对话切换已配置的 provider，保留原线程 ID、项目和模型，并用独立后端进程检查设置是否持久化。

应用使用 Swift、AppKit、Foundation、CryptoKit 和系统 SQLite3，没有第三方 Swift 包或 Python 运行依赖。它调用用户选择的本机 Codex 后端。后端验证通过后，仍需用户在原 GUI 中主动续聊，核对上下文与实际请求路径。

## 构建与开发

要求 macOS 13+、Swift 5.9+ 和包含 XCTest 的完整 Xcode。仅有 Command Line Tools 时，可能可以编译应用，但不能执行本项目的 XCTest；构建脚本会明确停止。

在仓库根目录运行，或双击 `Build App.command`：

```bash
bash "Build App.command"
```

如果系统当前选择了 Command Line Tools，而 Xcode 位于 `/Applications/Xcode.app`，可以只为这次构建指定开发工具：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash "Build App.command"
```

脚本先执行全部测试，再编译 release，将两个可执行文件组装为 `dist/<时间戳>/Miruun.app`，最后在 Finder 中显示。测试或编译失败即停止。它不会安装应用、启动 Codex 后端或读取真实会话。每次输出独立目录。

开发时可直接运行：

```bash
swift test
swift build -c release
```

CI 或不需要打开 Finder 时使用 `bash scripts/build-app.sh --no-reveal`。在禁止 SwiftPM 子进程沙盒的受限开发环境中可显式追加 `--disable-sandbox`；此参数不改变应用安全门。构建缓存保存在仓库 `.build/` 内。

请运行完整 `.app` 使用界面。`swift run Miruun` 缺少应用包元数据；`MiruunEngine` 是内置协议 helper，其独立调用不提供界面的持久未决标记保护。

## 使用流程

1. 在原 GUI 中核对标题、完整 ID、项目和模型，正常退出相关客户端与后端，并保持关闭。
2. 在 Miruun 中明确选择实际后端和对应 `CODEX_HOME`。启动时仅发现应用候选，不自动执行候选或读取会话。
3. 点击“读取对话与供应商”，按真实标题查找原对话；归档对话单独查询。列表最多返回一页 100 条，仅包含身份元数据。
4. 选择配置中的目标 provider，并在接入配置中独立核对实际地址。菜单显示脱敏 origin，不证明网关或环境覆盖后的路由。
5. 独立选择预期项目，确认客户端关闭，运行预检。确认面板绑定完整身份、原模型、目标、后端版本与配置摘要；有效期十分钟，只能使用一次。
6. 逐项确认后，工具备份选中 rollout 和共享状态数据库，执行同 ID 恢复，再关闭变更后端，以新的进程、不带 provider/model 覆盖地验证。
7. 后端验证通过后，重新打开原 GUI 对话，由用户主动续聊并核对实际请求路径。

当前变更候选严格限于 `codex-cli 0.159.2` 和 `codex-cli 0.159.0-alpha.7`，还需输入协议与实际功能检查通过。版本与 schema 匹配不等于二进制来源认证或运行兼容保证。

## 数据与失败处理

Miruun 不读取或修改 `auth.json`，不管理账户、额度或登录。所选后端自身可能读取认证配置并联网。启动、恢复和验证即使没有 `turn/start`，仍可能传输基础指令、工具元数据并产生费用；主动续聊还可能发送历史。

备份可能包含其他线程的私人元数据。记录保存在 `~/Library/Application Support/Miruun/`，目录权限 0700、文件权限 0600；不自动上传、清理或回滚。选中 rollout 上限 64 MiB，配置上限 1 MiB；共享数据库使用只读源连接和 SQLite backup API，包含已提交 WAL 数据，新建快照可独立只读打开。

明确在恢复前停止时，会保存停止回执并解除临时操作标记，下一次操作仍需新预检和确认。超时、意外回合、断连或回执失败等不确定结果保留备份并只读锁定；不自动重试、回滚或另建线程。强制退出后，未决标记继续有效。“仅只读复核”只报告存储元数据，不执行恢复，也不解除未决状态。

## 项目结构与验证

| 路径 | 职责 |
| --- | --- |
| `Sources/Miruun` | 菜单栏、确认面板、引擎子进程与持久未决标记 |
| `Sources/MiruunEngine` | 有界单次请求 / JSONL 结果入口 |
| `Sources/BridgeCore` | UI 与引擎间的信封、身份确认和操作状态门 |
| `Sources/BridgeEngine` | 发现、配置目录、预检、RPC、备份、事务与回执 |
| `Sources/CSQLite` | 系统 SQLite3 模块映射 |
| `Tests` | 合成存储、状态机、事务、跨层与子进程测试 |

[产品说明](docs/product.md)保留用户提供的需求与历史交付背景；[代码分析](docs/analysis.md)说明迁移依据和修复；当前验收事实以 [VALIDATION.md](VALIDATION.md) 为准。

图标母版未包含在本次源目录中，菜单栏暂用系统单色符号。应用尚未完成 Developer ID 签名、公证、真实对话验收或洁净机器验收。

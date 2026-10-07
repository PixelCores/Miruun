# Miruun 验证记录

## 未发布：聊天与记忆的本地版本备份

日期：2026 年 10 月 7 日。基于 `origin/main@217330da1adb08b01e874d03514a5e9373def2cb`，分支 `feature/codex-history-backups`；源码版本未变。

概览新增与连续性守护并列的原生备份开关，备份页同步同一状态并单独选择每小时/每天。默认关闭；开启后按所选目录最近尝试时间检查是否到期，备份不依赖接入守护。增加立即备份、版本选择和校验后导出，采用文件 SHA-256 去重、独立源目录清单、SQLite 在线备份与私有权限；配置/认证不属于本功能范围。

| 验证 | 结果 |
| --- | --- |
| 完整 XCTest | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox`：160 项通过，0 失败（BridgeEngine 147、BridgeCore 13）；日志 `/private/tmp/miruun-history-tests.log` |
| 新增备份回归 | 24 项合成测试：全部白名单目录与六类 SQLite、凭据排除、往返字节/权限、去重及删除历史、多 home、已提交 WAL 与源字节保留、路径穿越/链接/FIFO、无数据/损坏对象与清单、跨实例锁、导出拒绝覆盖及原子发布 |
| Release | 加入原生备份开关后 `swift build -c release --disable-sandbox` 通过；使用完整 Xcode，日志 `/private/tmp/miruun-history-release.log` |
| 合成 GUI | 独立 bundle ID 与 `CFFIXED_USER_HOME`，使用临时合成 Codex 目录；守护关闭时从概览开启备份，生成 4 文件版本；再次手动备份保持同一版本；备份页开关与概览同步，每天间隔可单独选择，关闭后仍可导出 |
| GUI 导出核验 | 通过目录选择面板导出到新的文件夹，重新核对全部对象 SHA-256、字节数、清单，并查询导出的 SQLite；全部通过 |
| 布局 | 实际检查概览 332 × 368 pt 与备份页 332 × 462 pt；两个开关、列表、长导出路径滚动区和底部按钮可见，无裁切重叠 |
| 独立复核 | 修复刷新列表覆盖失败详情，以及暂停接入守护导致备份回调/定时器被丢弃的问题；再次审查 UI 与存储发布/导出链路，未发现未解决问题 |

GUI 验证只备份合成文件，未读取或备份真实聊天、记忆或数据库，未更改已安装 Miruun 的守护和登录项。临时预览包采用独立标识，未替换或安装正式应用，验证结束已退出。全量测试后仅调整开关/布局及说明，核心存储未再修改，复用其测试结果并重新完成 Release 与 GUI 验证。

未做整小时/整天等待、系统睡眠唤醒、真实大规模历史、断电/磁盘耗尽故障注入、签名/公证或真实 Codex GUI 导入续聊验收。各 SQLite 单独一致，不保证跨库和文件整体事务；普通文件在备份窗口变动时失败，未引用对象可能保留。只覆盖所选 home 的明确白名单，外部数据库目录、云端记录与工作区文件不包含在内；导出不会自动覆盖 live Codex 或重放任务。


## 未发布：半透明玻璃、守护开关与配置目录发现

日期：2026 年 10 月 5 日。沿用 `main@d78f7fa78c4f4297c4cc99c0e2bc86eeab1891cd` 与 `codex/glass-core-panel` 分支；源码版本未变。

当前首页仅保留 Miruun 标题、实际状态入口、原生 `NSSwitch` 连续性守护及底部设置/退出；移除首页“打开 Codex”按钮与蓝色底板，手动启动保留在应用菜单中。移除副标题、自动打开选项及首次启动/reopen 的自动请求，清理旧 `autoOpenCodex` 偏好。原版月球保留；首页缩为 332 × 246 pt，设置与完整状态仍为 332 × 350 pt，窗口、遮罩和底部按钮同步按页尺寸更新。

设置显示自动发现的 Codex/Claude 全局配置目录。发现复用 worker 与有界登录 shell，只获取两个目录变量并检查文件元数据；默认结果不永久固定，非默认旧路径迁移为手选。显式无效路径、链接和 shell 失败可观察；目录未确定前禁用守护和启动，维护中不替换目录，退出阻止发现回调再次开启守护。Claude 仅发现并展示目录。

| 验证 | 结果 |
| --- | --- |
| 目录发现提交 XCTest | `8d53beb` 的 136 项通过，0 失败（BridgeEngine 123、BridgeCore 13），日志 `/private/tmp/miruun-directory-switch-final-tests.log`；本轮仅移除首页按钮并调整布局，未重复运行未受影响的核心测试 |
| 目录回归 | 新增 12 项合成测试，覆盖默认/缺失/自定义路径、shell 合并与 unset、无效覆盖不回退、链接、手动优先及畸形记录；独立复核发现的分隔符截断问题已修复并补回归 |
| Release 与打包 | 移除首页按钮后重编译通过，无 warning/error；plist、压缩包内容与可执行权限检查通过，日志 `/private/tmp/miruun-guard-only-release.log` |
| 实际 GUI | 最新首页已无“打开 Codex”按钮，664 × 492 px；设置与状态页为 664 × 700 px，返回恢复紧凑首页，遮罩、文字与底部控件无裁切。目录发现提交曾验证开关启停、暂停后自动查找及目录面板取消，原路径保持 |
| 最终包 | 实际运行 `dist/20261005-121828-guard-only/Miruun.app`，启动只显示面板，没有待启动请求；发现 `/Users/pixelkernel/.codex` 和 `/Users/pixelkernel/.claude`，守护启用、配置就绪及登录项已选状态保持 |
| 独立复核 | 所选 Codex URL 同时用于守护与手动启动；删除自动请求后稳定采样和 UUID 取消链保留，未发现未解决问题 |

最新截图为 `/private/tmp/miruun-guard-only-overview-ui.png`、`/private/tmp/miruun-guard-only-settings-ui.png` 与 `/private/tmp/miruun-guard-only-status-ui.png`，应用包为 `/private/tmp/Miruun-guard-only.zip`。本次没有关闭当前 Codex、发送真实回合或读取历史数据库；没有更改登录项注册。真实客户端冷启动与其他系统版本仍未额外验收。

### 初版玻璃界面验收

日期：2026 年 10 月 3 日。基于已合并 PR #2 的 `main@d78f7fa78c4f4297c4cc99c0e2bc86eeab1891cd`，在独立工作树的 `codex/glass-core-panel` 分支实现；源码版本未变。

浮窗改为 332 × 350 pt，使用 `NSVisualEffectView` 的 `.popover`、`.behindWindow` 与原生暗色外观合成毛玻璃，背景和前景共用圆角与箭头 mask。去掉八个快捷图标、模拟滑轨与重复状态行；概览保留连续性守护、自动打开、实际状态入口和主要“打开 Codex”按钮。设置、配置备份、目录选择、登录项和完整状态仍可访问。

| 验证 | 结果 |
| --- | --- |
| XCTest | 124 项通过，0 失败（BridgeEngine 111、BridgeCore 13），未修改核心源码或测试 |
| Release 与打包 | 最终原生背景/透明前景拆分后重新编译通过，无 warning/error；plist 校验通过；相关 UI 源码另按 macOS 13 deployment target 类型检查通过 |
| 最终 GUI | 664 × 700 px（Retina 2×），对应 332 × 350 pt；土星、箭头、玻璃卡片、原生控件、设置和返回正常绘制，文字可读 |
| 等待与取消 | 已有 Codex 活动时启动入口进入等待并禁用，完整状态说明可读；Esc 收起后用 `⌘,` 打开设置，等待保留；暂停取消，重新启用恢复就绪 |
| 偏好与目录 | 自动打开开/关与显示一致；守护启用时禁止选择目录，暂停时可打开目录面板，取消后原路径不变；登录项的已选状态和可访问名称保持 |
| 独立静态复核 | 背景/前景持有关系无循环，arrow 更新重建 mask；worker、稳定采样、启动事务、UUID 取消和退出保持原样；隐藏与菜单 tracking 保护保留 |

首次预览发现 `NSVisualEffectView` 子类自绘内容未显示，改由系统背景承载透明的既有 `MenuPanelView` 前景，最终包已实际复核。全量测试日志为 `/private/tmp/miruun-glass-build.log`，最终 Release 日志为 `/private/tmp/miruun-glass-final-release.log`。应用为 `dist/20261003-210537-glass/Miruun.app`，压缩包为 `/private/tmp/Miruun-glass-core.zip`。截图为 `/private/tmp/miruun-glass-ui.png` 与 `/private/tmp/miruun-glass-settings-ui.png`。

验证后恢复本次开始时的守护启用、自动打开关闭、登录项已选状态，验证用待启动请求已取消。没有关闭当前 Codex、发送真实回合或读取历史数据库；临时彩色背景页及本地服务已关闭。

界面边界：目标窗口截图不包含其他窗口，无法据此证明桌面背景的实际采样颜色；原生材质属性与本机“降低透明度”关闭状态已核对，最终背景融合仍需用户在实际桌面上查看。未完成 VoiceOver、其他屏幕/系统版本、签名或公证验收；真实冷启动及两种模式往返续聊仍遵循后面的记录。

后续按用户要求，将菜单栏与浮窗的土星统一换为月球：共用 `moonImage` 矢量绘图，以 alpha 层次呈现月面凹坑；菜单栏为 18 × 18 pt，浮窗为 28 × 28 pt。仅修改图标绘制、两处调用和对应文案，没有新增资源或实体。Release 重编译与 plist 检查通过，实际运行 `dist/20261003-212845-moon/Miruun.app`，浮窗月球显示正常；原守护及自动打开偏好保持，当前就绪。截图为 `/private/tmp/miruun-moon-ui.png`，压缩包为 `/private/tmp/Miruun-glass-moon.zip`。本次纯图标修改未重复运行未受影响的核心 XCTest，前述 124 项证据保留；Release 日志为 `/private/tmp/miruun-moon-release.log`。

2026 年 10 月 5 日，按用户要求恢复加猫爪前的原版月球 Logo。`MenuPanelView.swift` 与 `e0841c3` 逐字节一致，移除尚未提交的生成图像及打包接入，保留毛玻璃与核心操作界面。本次 Release 重编译通过，无 warning/error；plist 和压缩包内容及执行权限检查通过。实际运行 `dist/20261005-114748-original-moon/Miruun.app`，确认原版月面凹坑显示正常，守护启用、自动打开关闭、配置就绪保持。截图为 `/private/tmp/miruun-original-moon-ui.png`，压缩包为 `/private/tmp/Miruun-original-moon.zip`，Release 日志为 `/private/tmp/miruun-original-moon-release.log`。纯 Logo 恢复未重复运行未受影响的核心 XCTest，前述 124 项证据保留。

## 已合并：参考图深色菜单栏浮窗

日期：2026 年 10 月 3 日。沿用启动入口分支及 `main@1a43f2dae5fee5ce7d4fbebc60a9fe4872747d4d` 基线，源码版本未变。

按照用户参考图重做 AppKit 界面：332 × 379 pt 深色箭头浮窗、土星图标、八个快捷图标、三行卡片与底部设置/退出。概览三行连接 Miruun 守护、Codex 启动与自动打开的实际状态；滑轨表达开关或等待状态，不展示音量、账户或进度。设置和完整状态复用同一浮窗，保持真实目录选择、配置备份、登录项及可选择的完整状态文字。

| 验证 | 结果 |
| --- | --- |
| XCTest | 界面重构后全量 124 项通过（BridgeEngine 111、BridgeCore 13），未修改核心源码或测试 |
| Release 与打包 | 最终样式和浮窗清理修正后重新编译通过，无 warning/error；plist 校验通过 |
| 参考布局 | 实际运行窗口截图为 664 × 758 px（Retina 2×），即 332 × 379 pt；检查深色表面、土星、导航、卡片、行间距与底部居中按钮 |
| 概览与偏好 | 自动打开下拉关闭后状态文字同步；快捷图标重新开启后一致；重开包保留偏好。守护启用/暂停、启动入口禁用/恢复均可见 |
| 最终包等待与取消 | 已有 Codex 活动时保持等待，入口禁用；Esc 后通过 `⌘,` 打开设置，等待状态保留；暂停取消请求，重新启用恢复就绪与启动入口 |
| 设置与完整状态 | 最终包设置、状态与返回实际可用，目录和完整等待原因可读，登录项名称保留可访问标签；守护启用时禁止选目录。先行同一界面包已打开目录面板并取消，原路径不变 |
| 独立静态复核 | worker、稳定采样、启动事务和 UUID 取消流程保持原样；下拉使用 selectedTag；隐藏/退出清理监听，目录面板与菜单 tracking 有保护 |

首次测试中，既有合成进程测试 `NativeProcessTests.testTruncatedOrInvalidTrailingOutputPreventsCleanShutdown` 出现初始化超时；单项重试通过，随后两次完整构建测试通过。没有弱化断言或修改测试。全量构建日志为 `/private/tmp/miruun-reference-ui-polished-build.log`，最终 Release 日志为 `/private/tmp/miruun-reference-ui-release.log`。

最终应用：`dist/20261003-203014-reference-ui/Miruun.app`。已正常退出先行包并运行此包；进程路径核对一致。守护及自动打开已恢复启用，登录项保持关闭，验证用待启动请求已取消；没有关闭当前 Codex、发送真实回合或读取历史数据库。压缩包为 `/private/tmp/Miruun-reference-ui.zip`，两份可执行文件及 plist 与应用一致，执行权限保留。

界面边界：外部点击与失活收起经过静态复核，未单独取得全局点击的运行证据；没有执行系统登录项注册，也未完成 VoiceOver 或其他屏幕/系统版本验收。核心启动入口的真实冷启动与两种模式往返续聊仍遵循下方记录的未验收边界。

## 已合并：启动前自动准备接入配置

日期：2026 年 10 月 3 日。基于 `main@1a43f2dae5fee5ce7d4fbebc60a9fe4872747d4d`；本次不调整应用版本号。

新增菜单与设置中的“打开 Codex”，以及“打开 Miruun 时自动打开 Codex”选项。启动请求复用串行守护与两秒定时检查，重新读取当前配置和认证，确认相同样本及客户端退出后，通过 `NSWorkspace` 启动 `com.openai.codex`，传入所选 `CODEX_HOME`。暂停或退出取消尚未发出的请求；系统登录项仍静默。

| 验证 | 结果 |
| --- | --- |
| 全量 XCTest | 124 项通过，0 失败（BridgeEngine 111、BridgeCore 13） |
| 连续性守护 | 41 项通过；新增 5 项启动前检查回归，全部使用临时合成配置与注入的进程状态 |
| Release 与打包 | Miruun / MiruunEngine 成功，日志无 warning 或 error；plist 校验通过 |
| 独立复核 | 检查主线程与 worker 边界、请求合并、暂停/退出取消、旧回调失效及失败状态保留；未发现未解决问题 |
| GUI | 先行包及最终包均已实际打开；最终包布局正常，显示官方配置就绪，菜单和设置启动入口、自动打开选项可见 |
| 活跃客户端与暂停 | 最终包复核通过：点击启动后按钮及菜单入口禁用并等待已有 Codex 退出；暂停取消请求，重新启用后按钮恢复，无 Codex 重启 |
| 手动再次打开 | 先行包关闭设置后通过 Finder 双击进入自动等待；最终包保留设置窗口时再次双击同样进入自动等待。暂停并重新启用后请求取消，自动打开偏好保留 |
| GitHub CI | PR #2 的 [macOS run #6](https://github.com/PixelCores/Miruun/actions/runs/37105407166) 已通过，对应功能提交 `cf989e058649f340d6aafb5523583b86a36f0439` |

新增测试覆盖官方与代理的配置无需写入时仍等待客户端、首次就绪配置也需稳定采样、客户端退出后重新采样、较早就绪结果不掩盖新配置变化、不支持的新配置拒绝，以及无法确认进程状态时不写入文件。

随后核对本机桌面包 `26.928.21956`，发现登录 shell 可能覆盖传入的目录。补上目录预检及 4 项进程测试，覆盖 shell 元字符与中文路径、初始化输出、覆盖或 unset、非零退出，以及临时 HOME 中真实 zsh 的 `.zprofile` 覆盖；不执行用户的真实登录 shell。检查后重新读取配置和客户端，并改为单次 timer 完成后隔两秒重新安排，防止慢检查导致紧接着补采样。

构建命令：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-app.sh --no-reveal --disable-sandbox
```

最终产物：`dist/20261003-135308-3064/Miruun.app`。日志：`/private/tmp/miruun-mode-launch-final-build.log`。先行 GUI 产物为 `dist/20261003-133049-91459/Miruun.app`，截图为 `/private/tmp/miruun-mode-launch-ui.png`。之后已正常退出先行包并运行最终包，进程路径复核一致；最终包的设置布局、等待、取消与再次打开均已复核。保留守护启用及自动打开偏好，登录项关闭；本次验证的待启动请求已取消。`/private/tmp/Miruun-auto-mode-launch.zip` 内两个可执行文件和 plist 与最终产物逐字节一致，执行权限保留。未关闭当前 Codex，未发送真实回合，也未读取真实会话或数据库。

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

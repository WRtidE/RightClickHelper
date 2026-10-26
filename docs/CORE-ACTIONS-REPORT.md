# 0.3.0 核心功能与恢复验证

> 原始证据仅保留在本地，不纳入 Git；本报告保留测试结论与适用范围，详见 [证据说明](./evidence/README.md)。

日期：2026-10-21。最终版本：0.3.0（build 6）。环境：macOS 26.5.2 / Apple Silicon，Apple Development 签名的沙盒 Debug 构建。按用户要求依次推进稳定性、安装验证、Terminal、常用应用。

## 1. 稳定性与权限恢复

已实现并验证：

- 新增专用测试目录授权后，将目录改名移动；“验证目录授权”解析原书签，设置列表与共享覆盖配置更新为新路径。
- 删除该空测试目录后，记录保留为失效状态；通过“重新授权…”选择新测试目录，在其中成功创建 `重新授权成功.txt`。最终版本补充了明确的重新授权错误文字，避免暴露难理解的底层书签错误。
- 创建对话框打开时，向本工具主进程发送 SIGKILL；重新启动后显示新增中断记录，没有产生文件或重新显示创建表单。检查目标目录并确认记录后移入完成历史。
- 独立子进程在创建前、文件写完后、写入阶段记录完成后分别 `_exit`，重启检查均拒绝重新领取。结果分别为 0、1、1 个文件；不会产生第二个文件。这是进程中断测试，不是断电耐久性保证。
- 每个候选文件在排他创建前写入 Journal；写入成功后记录 written。候选路径可能已存在，UI 不把“存在”当作本次创建成功，也不自动删除或覆盖。
- 启动、请求结束和手动操作执行历史清理：完成记录 7 天 / 500 条，近 10 分钟全部保留以覆盖请求有效期；1 小时前的残留 `.tmp` 清理。未确认中断不自动清理；100 条时拒绝新提交并提示检查。OSLog 由系统管理，不建立无上限自有日志文件。

此前 0.2.0 遗留的两个测试中断记录已通过新界面检查目标目录、逐项确认。未重放、删除或覆盖测试目录中的文件。最终 Pending、Processing 和 Journal 均无未完成记录。

## 2. 安装验证与明确的缺口

最终构建的签名严格校验通过，PlugInKit 仅列出一个已启用的本工具扩展，位置为 `~/Applications/RightClickHelper.app`。覆盖安装前后的 `grants.json`、`applications.json` SHA-256 完全一致。更新后通过 Finder 冷启动并连续创建三种 Office 文件。

新增 `scripts/install-preflight.sh` 提供只读环境、签名、扩展和 Gatekeeper 检查。当前开发签名包的 Gatekeeper 分发评估为 rejected，与“尚未公证”的状态一致，没有绕过该评估或将其标成公开分发可用。

**未完成：干净账户首次安装、注销 / 系统重启后验证、macOS 14 与其他版本实机、Intel 实机、Developer ID 和公证下载。** 本机当前账户已有配置，不能代替这些环境。详见 [安装验收矩阵](./INSTALL-TEST-MATRIX.md)。本轮未重启 Finder 或整台电脑，未改变其他 Finder 扩展开关。

## 3. 在此打开终端

Finder 单目录空白处、单选目录和单选文件分别捕获当前目录、所选目录、文件父目录。多选、包、替身和符号链接不提供入口。主应用再次检查授权和各级目录，使用 `NSWorkspace.open` 向系统 Terminal 传递目录 URL；不生成脚本、命令字符串或自动化授权。

实机结果：

| 上下文 | 实际核对 |
| --- | --- |
| 主应用退出，中文空格目录空白处右键 | Finder 唤醒新主进程，Terminal shell 的 cwd 为目标目录 |
| 名称含单引号、美元符号、分号和反引号的目录内单选文件 | shell cwd 为原始文件父目录，字符完整保留 |
| 单选名称含换行的文件夹 | shell cwd 为该文件夹 |
| 5 个目录多选 | 终端 / 常用应用入口隐藏，复制路径仍显示 |

电脑操作工具禁止直接操作 Terminal 界面，因此通过进程父子关系与 `lsof` 核对 Terminal 所启动 shell 的 cwd，而不是仅以“应用启动”判断成功。证据中的换行显示为 `\n`，是 lsof 的输出转义。

## 4. 常用应用

“常用应用”设置页支持添加本机应用、按 bundle ID 去重、移除、持久化和最多 5 个的校验。默认只对文件显示，用户确认目录能力后可勾选支持文件夹。扩展读取版本化配置，只传应用 ID 和目标上下文；执行时重新核对当前配置、目标与权限。应用定位优先 Launch Services，再使用用户选择的书签，配置中移除或应用不可用都会明确报错。

| 用例 | 结果 |
| --- | --- |
| 冷启动后用文本编辑打开 `示例.txt` | 正确窗口、文件 URL 和预期文本，文件内容未改变 |
| 用 VS Code 打开 `示例 Swift 包` 文件夹 | 正确窗口和资源管理器完整路径，可见 Sources / Package.swift |
| 目录右键筛选 | 仅显示支持目录的 VS Code，文本编辑不出现 |
| 重复添加文本编辑 | 仍为 2 个应用，更新已有记录 |
| 模拟应用失效 | 专用夹具应用的可执行文件移走后，显示“找不到 MissingFixture，请重新添加”；未执行该夹具 |
| 删除应用配置 | 下一次菜单中不再出现夹具应用 |
| 覆盖安装和重启主应用 | 文本编辑、VS Code 与目录支持选项保留 |

尝试用 Xcode 打开目录时，系统返回打开错误，应用正确显示失败并结束请求；随后移除该测试配置，改用实际接受文件夹 URL 的 VS Code 验证成功。不会承诺所有应用均支持目录或所有文件格式。成功提示只表示已提交打开请求。

## 自动化与已有功能回归

- `swift test`：**21 项通过，0 失败**。覆盖原有文件创建 / 并发 / 路径边界 / Office 模板、请求监听和序列化，以及恢复计划、日志失败停止创建、历史保留、v1 请求 / 配置迁移、常用应用上限和重复 ID、Terminal 上下文与特殊路径。
- `bash scripts/test-crash-recovery.sh`：三种独立进程中断通过。工具仅用于开发测试，不打包到主应用。
- Xcode Debug 构建成功，主应用和扩展仍保留原有 sandbox / App Group 权限，没有新增自动化、网络、辅助功能或完全磁盘访问权限。
- 最终构建由 Finder 创建 `核心功能回归.docx/.pptx/.xlsx`，恰好 3 个文件，均与内置模板逐字节相同。ZIP / XML / 命名空间 / 内部引用 / 无宏及外部链接检查通过。模板未改变，本轮没有再次在 Office 中逐个打开；此前实际 Office 打开验证见 POC-REPORT。
- 中途发现嵌套 ScrollView/List 布局无法被电脑操作工具读取；移除外层 ScrollView，改为原生分栏设置后，窗口和全部操作恢复可访问。该现象不用于推断 macOS 本身缺陷。

## 证据

- 自动测试（本地证据：`evidence/core-actions/tests.log`）、进程中断结果（本地证据：`evidence/core-actions/crash-results.json`）
- 安装日志（本地证据：`evidence/core-actions/final-install.log`）、签名与扩展状态（本地证据：`evidence/core-actions/install-preflight.log`）
- 终端实际工作目录（本地证据：`evidence/core-actions/terminal-cwd.log`）、多选菜单（本地证据：`evidence/core-actions/multi-selection-menu.txt`）
- 文本编辑目标（本地证据：`evidence/core-actions/textedit-open.txt`）、VS Code 目录（本地证据：`evidence/core-actions/vscode-folder.txt`）、失效应用错误（本地证据：`evidence/core-actions/missing-application.txt`）
- Office 格式验证（本地证据：`evidence/core-actions/office-validation.log`）、最终文件与队列检查（本地证据：`evidence/core-actions/final-checks.json`）、请求日志（本地证据：`evidence/core-actions/request-lifecycle.log`）

实现依据：[Apple NSWorkspace URL 打开接口](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:))、[URL 书签](https://developer.apple.com/documentation/foundation/url/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:))。行为支持范围以本文本机实测为准。

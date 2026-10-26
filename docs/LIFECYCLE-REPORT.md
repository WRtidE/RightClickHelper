# 连续重装与创建流程修复验证

> 原始证据仅保留在本地，不纳入 Git；本报告保留测试结论与适用范围，详见 [证据说明](./evidence/README.md)。

日期：2026-10-21；交付版本：0.2.1（build 4）。环境：macOS 26.5.2 / Apple Silicon，本机 Apple Development 签名 Debug 构建。

## 故障复现与定位

在保留旧处理逻辑、仅增加日志的诊断构建（0.2.0 / build 3）上，第一次安装后的新建正常；第二次同构建重装后，再次出现“菜单点击后仍停留在主窗口”的现象。

11:30:38–11:30:39 的同一个请求 `5CE29D5E-CB0A-447C-8A63-7F45FE9132A4` 已经过 `request-submitted → companion-open-ok → url-callback → request-claimed → dialog-present`，但可访问界面没有显示创建对话框。11:31:32 按 Esc 后才出现 `request-finished`。因此，本次复现并非菜单未注册、URL 未送达或文件写入失败，而是旧版直接在 URL 回调里进入独立 `NSAlert.runModal()` 后的窗口呈现问题。日志反证了最初“URL 可能丢失”的假设；没有据此声称 macOS 自身存在已确认的缺陷。

原始记录：baseline.log（本地证据：`evidence/lifecycle/baseline.log`）。

## 修复内容

1. 用 AppKit 明确持有唯一主窗口和应用委托，保留原 SwiftUI 设置视图。关闭窗口时隐藏，后续请求能重新显示同一窗口。
2. 新建与错误提示使用附着主窗口的异步 `beginSheetModal`。不再在启动/URL 回调里调用同步创建弹窗；表单结束、AppKit 完成移除之后才进行下一步。
3. `RequestInbox` 监听共享容器的 `Pending` 目录，先订阅再扫描；URL 和应用激活只负责唤醒检查。即使缺少 URL 回调，已运行的应用也能看到完整写入的请求。
4. 一次只领取和呈现一个请求；表单结束后重新扫描。重复 URL、文件系统通知合并、重复 completion 都不会重复创建。未完成的历史请求仍不自动重放。
5. 过期、损坏和过大的请求在校验失败后进入终态，不再遗留成新的“中断请求”并阻塞后续动作。
6. 安装时等待旧进程退出，校验临时副本后再替换，并保留旧版本。增加只记录阶段和请求 UUID 的本机日志，不记录目录路径、文件名或书签。

使用的系统机制参考：[Apple NSAlert 异步表单](https://developer.apple.com/documentation/appkit/nsalert/beginsheetmodal(for:completionhandler:))、[AppKit URL 委托回调](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:open:))、[Dispatch 文件系统事件源](https://developer.apple.com/documentation/dispatch/dispatchsource/makefilesystemobjectsource(filedescriptor:eventmask:queue:))。

## 实机回归结果

| 场景 | 实际结果 |
| --- | --- |
| 升级：0.2.0 → 0.2.1 | 通过；启用后立即创建 `更新第1轮.docx` |
| 同版本覆盖安装第 1 次 | 通过；立即创建 `更新第2轮.pptx` |
| 同版本覆盖安装第 2 次 | 通过；立即创建 `更新第3轮.xlsx` |
| 授权与注册 | 原测试目录授权保留；最终只有一个已注册、已启用的本工具扩展，版本 0.2.1 |
| 冷启动 | 先确认主应用进程不存在、扩展仍运行，再由 Finder 唤醒新主应用进程；创建 `冷启动验证.xlsx` |
| 表单未完成时连续提交 | Word 表单打开时继续从 Finder 提交 PPTX、XLSX；Word 表单未被替换，完成后依次显示 PPTX、XLSX |
| 连续新建同名 Office 文件 | 三种类型各创建两次，共六个文件；第二个自动编号 ` 2`，旧文件内容不变 |
| 取消后继续 | 取消一个 Word 请求后，下一个请求正常出现；取消没有产生文件 |
| 错误后继续 | 非法名称 `非法/文件名` 显示错误表单；确认后成功创建 `错误后继续.json`，错误没有产生文件 |
| 关闭主窗口后新建 | 主窗口关闭隐藏后，Finder 新建会重新显示主窗口与表单；创建 `关闭窗口后继续.md` |
| 安装保护 | 无效源应用、旧进程仍在运行两种情形均拒绝安装；安装前后主程序与 Info.plist 哈希相同 |
| 签名与格式 | 安装副本深度严格签名验证通过；10 个 Office 产物与内置模板逐字节相同，ZIP/XML/命名空间/关系检查通过 |

全部回归期间没有重启 Finder、重置系统隐私数据库或更改其他 Finder 扩展；每轮更新只停用/启用本工具。

最终日志按 UUID 核对：**14 个请求全部恰好领取、附着表单和结束一次；12 次创建成功、1 次取消、1 次非法名称失败；没有重复表单或额外文件。** 测试目录中的文件集合与预期 12 个文件完全一致。

证据：

- 请求阶段日志（本地证据：`evidence/lifecycle/fixed.log`） 与 逐请求计数（本地证据：`evidence/lifecycle/request-summary.json`）
- 文件大小和 SHA-256（本地证据：`evidence/lifecycle/files.json`）
- 安装记录：第 1 轮（本地证据：`evidence/lifecycle/install-fixed-1.log`）、第 2 轮（本地证据：`evidence/lifecycle/install-fixed-2.log`）、第 3 轮（本地证据：`evidence/lifecycle/install-fixed-3.log`）
- 拒绝路径：无效源应用（本地证据：`evidence/lifecycle/install-rejected-invalid.log`）、旧进程仍运行（本地证据：`evidence/lifecycle/install-rejected-running.log`）

队列等待时仍显示第一个 Word 表单（本地证据：`evidence/lifecycle/queued-word-sheet.png`）

最终应用状态（本地证据：`evidence/lifecycle/final-app.png`）

## 自动化回归

`swift test`：15 项通过、0 失败。新增四项覆盖真实文件系统监听（不调用 URL 唤醒）、启动前已存在请求与窗口就绪门控、表单占用时的 10 请求突发/重复通知/旧 completion，以及过期/损坏/过大/未完成文件不会阻塞有效请求。原有排他创建、同名并发、目录边界、符号链接、只读目录和 Office 模板测试继续通过。

代码入口：`Shared/RequestInbox.swift`、`App/AppState.swift`、`App/RightClickHelperApp.swift`、`Shared/SharedStore.swift`、`scripts/install.sh`。

## 范围与剩余边界

本次验证的是本机已有安装的升级和重复覆盖安装，没有将其等同于干净账户首次安装、跨 macOS 版本、系统重新登录/重启或公证下载流程。安装失败回滚已实现，但没有注入磁盘断电或 LaunchServices 故障。0.2.0 历史测试留下的两个中断记录仍保留且不自动重放；本次 14 个请求全部终结，没有新增未完成记录。崩溃中断恢复和历史记录清理仍是独立工作。

# 0.5.2 · 新建窗口与菜单栏图标

> 原始证据仅保留在本地，不纳入 Git；本报告保留测试结论与适用范围，详见 [证据说明](./evidence/README.md)。

2026-10-22，macOS 26.5.2 / Apple Silicon，build 16。已安装到 `~/Applications/RightClickHelper.app`。

## 修改

- 新建文件不再调用 `showWindow()` 或附着到设置窗口。独立 `ActionDialog` 用非激活 NSPanel 展示标题、目录、名称及按钮，异步完成；请求仍由 RequestInbox 串行管理。
- 确认、取消、关闭、Esc 都只回调一次。按钮快捷键清空默认修饰键，面板同时处理 `cancelOperation`，避免取消后请求未结束。
- 首次授权用 `NSOpenPanel.begin`，不再显示设置窗口。服务格式选择与错误提示也复用独立小窗口。
- Finder 唤起主应用时不激活所有窗口；冷启动根据 AppKit 默认启动标记与待处理请求决定是否打开设置。正常打开应用和显式“打开右键助手”仍显示设置。
- 菜单栏使用 `cursorarrow.click.2`，与 Finder 根菜单同一符号，18 点模板图标，随菜单栏外观显示。

## 验证

- 36 项核心测试通过，双架构构建及安装后的严格签名校验通过。
- Finder 真实菜单新建 Markdown、Word、Excel、PowerPoint、文本成功；同名 Markdown 生成 `独立窗口测试 2.md`，未覆盖原文件。Office ZIP 完整性检查通过。
- 退出主应用后从 Finder 新建 Word，观察到独立新建对话框；正常启动应用仍显示设置。
- Excel 请求未结束时继续提交 PowerPoint，后者排队并在前者完成后显示，最终均创建成功。
- Esc 取消验证发现问题后修复并重装，最终 Finished 记录为“用户取消”，Pending/Processing 均为空；取消按钮同样通过。
- 未授权测试目录只显示独立授权窗口，点击取消后记录“用户取消授权”；没有新增授权。
- 非法文件名显示独立错误窗口；随后成功创建 `取消后继续创建.txt`，无请求残留。
- grants、applications 和 configuration 三份文件的 SHA-256 与更新前一致。旧 RightButton Finder 扩展仍停用，新版扩展启用。

截图和结构化结果位于 evidence/action-dialog（本地证据：`evidence/action-dialog/`）。测试文件保留在 `build/POCFixtures/工作目录/M2验收/独立窗口验收`；空授权测试目录在 `build/POCFixtures/独立授权验收`。

本轮未重复验证双 Shift 自动粘贴，剪贴板弹窗和粘贴逻辑未改动；菜单栏图标代码已核对为与 Finder 相同符号。未做系统重启或跨系统版本验证。

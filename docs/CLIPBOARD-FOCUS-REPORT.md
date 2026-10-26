# 0.5.1 历史面板窗口激活修复

> 原始证据仅保留在本地，不纳入 Git；本报告保留测试结论与适用范围，详见 [证据说明](./evidence/README.md)。

日期：2026-10-21。版本：0.5.1（build 15）。已安装到 `~/Applications/RightClickHelper.app`。

用户在其他应用中双击左 Shift 时，历史卡片出现的同时，右键助手的设置窗口也被带到了前台。原实现对普通浮动面板调用 `makeKeyAndOrderFront` 后，又执行了应用级 `NSApp.activate`，导致整个应用激活。

改为从创建时就使用 `NSPanel` 的 `.nonactivatingPanel`，并在紧凑/管理样式切换时持续保留该标志。紧凑面板不再调用应用激活；主动打开搜索管理界面仍保留激活行为。没有通过关闭设置窗口来掩盖问题，没有新增权限。

该标志的公开语义见 [Apple 文档](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)。实际修复同时移除了紧凑面板路径上的显式激活调用，不能仅凭设置标志就判定修复。

验证结果：

- universal 构建成功，安装包完整签名校验通过；36 项核心测试全部通过，没有新增镜像实现的断言测试。
- 原目录授权、常用应用和菜单配置文件哈希未变。Finder 扩展重新启用；文本历史及自动粘贴开关、新权限保留。
- 用户实际从其他应用触发后反馈：“只弹小卡片，自动粘贴正常”。自动化工具不能单独模拟 Shift，因此窗口顺序的验收由用户完成。
- 应用状态显示已发送粘贴快捷键。本轮读取的预置 TextEdit 测试文稿仍为占位文字，故不将该文稿作为自动粘贴成功的独立证据；此项依据用户反馈，具体测试宿主未再确认。

证据见 evidence/clipboard-focus（本地证据：`evidence/clipboard-focus`），包括构建、测试、安装、设置文件哈希和应用状态。跨桌面/全屏应用、真实休眠和其他宿主的兼容性不在本次单点修复的已测范围内。

# 0.6.2 · Dock 后台运行验证

2026-11-02，版本 0.6.2（build 20）。

## 问题与修复

此前仅抑制设置窗口，主应用仍使用 regular 激活策略，因此 Finder 新建文件时仍会出现 Dock 运行图标。

主应用 Info.plist 增加 LSUIElement=true，从启动时即按后台应用处理；入口同时设置 accessory 激活策略，避免主动打开窗口后恢复为普通 Dock 应用。项目生成脚本同步维护该配置，Finder 扩展不添加此项。

## 本机验证

- Xcode 构建与覆盖安装成功，安装版本为 0.6.2 / 20，安装包 LSUIElement=true。
- 安装后与界面操作后，均读取到一个运行实例，activationPolicy 为 accessory。
- Finder 右键新建 TXT：仅出现 action-dialog，创建“回归-Dock后台.txt”成功，返回 Finder 并选中新文件。
- Finder “打开右键助手…”正常显示 0.6.2 设置窗口；关闭后保持后台运行。
- Dock 偏好的固定应用与最近应用中均无右键助手条目。
- Dock 的辅助功能读取超时，未直接截图确认 Dock；无普通运行图标的结论依据已安装配置与运行时激活策略。

构建、安装和运行模式证据保存在本机忽略目录 docs/evidence/dock-agent/。本次仅改变应用呈现模式，未重复运行 0.6.1 已通过的 42 项核心测试。

# M2 产品化验收报告

> 原始证据仅保留在本地，不纳入 Git；本报告保留测试结论与适用范围，详见 [证据说明](./evidence/README.md)。

日期：2026-10-21。交付版本：**0.4.0（build 9）**。安装位置：`~/Applications/RightClickHelper.app`。

结论：M2 的设置、引导、动态菜单、常用应用管理和系统服务补充入口已完成，本机可日常试用。当前仍是开发签名版本；发行与跨环境支持验证进入 M3。

## 已实现

| 项目 | 交付行为 |
| --- | --- |
| 菜单设置 | 六类动作开关、上移/下移、六种内置格式显示选择；下次构建菜单时生效；保留设置入口 |
| 默认常用应用 | 适用时排在首位并标注“默认”；服务选择框预选；目录能力过滤保持有效；不修改系统文件关联 |
| 恢复默认 | 重置动作、排序、模板和默认应用，保留目录授权、应用列表与覆盖范围 |
| 配置迁移与恢复 | 共享配置 v4，兼容 v1/v2/v3；损坏快照先备份再恢复，显示提示；私有授权独立存储 |
| 首次使用引导 | 扩展启用 → 测试目录 → Finder 菜单/复制/新建；逐项显示待验证/已通过；完成状态持久化；重新测试用新会话 |
| 诊断 | 区分扩展、覆盖、有效授权、实际操作；保留中断检查和历史清理；提供服务刷新入口 |
| 系统服务 | 复制路径、新建文件、Terminal、常用应用；仅接收明确文件 URL；复用授权和串行执行，交互选择使用异步附着表单 |

设置分成“使用引导、菜单设置、工作目录、常用应用、诊断”五页。Finder 子菜单延续此前已验收的紧凑布局，不重新加入导致大空行的分隔符。

## 自动验证

- `swift test`：**30 项通过，0 失败**，其中新增 7 项覆盖配置迁移/持久化、菜单规则、损坏备份、引导会话隔离、服务输入和请求来源兼容。见 测试日志（本地证据：`evidence/m2/tests.log`）。
- 独立子进程崩溃注入 **3 项通过**：写入前、写入后、落盘日志后退出，均保留中断记录且不重放。原脚本改为编译完整共享源文件，补齐 M2 模型依赖。见 崩溃回归日志（本地证据：`evidence/m2/crash-recovery.log`）。
- Xcode Debug universal 构建成功，已安装应用与嵌入扩展的 `codesign --verify --deep --strict` 通过。macOS 14 / Intel 仅为编译目标，不视为实测。
- 本轮实际生成的 5 份 Office 文件均通过 ZIP、XML、引用关系、空白内容和无宏/外链校验。见 Office 校验日志（本地证据：`evidence/m2/office-validation.log`）。

## 本机操作验收

环境：macOS 26.5.2（25F84）、Apple Silicon、Xcode 26.3。使用独立目录 `build/POCFixtures/工作目录/M2验收`，没有清空用户配置模拟首次安装。

| 场景 | 实际结果与证据 |
| --- | --- |
| 更新安装 | 0.3.1 → 0.4.0 build 8 → build 9；按停用自身扩展、退出主应用、覆盖安装、重新启用流程成功。见 最终安装日志（本地证据：`evidence/m2/install-final.log`） |
| 原有数据保留 | 首次 M2 更新前后私有目录/应用配置哈希一致；引导随后只添加 M2 测试目录。最终常用应用文件仍与更新前哈希一致，保留原有 2 个应用、4 个目录并新增 1 个测试目录 |
| 菜单设置生效 | 关闭“复制文件名”和 JSON，将复制完整路径移到首位；退出重开设置仍保留，真实 Finder 菜单顺序与隐藏项一致。见 菜单证据（本地证据：`evidence/m2/finder-custom-menu.txt`） |
| 恢复默认 | 界面及 Finder 恢复默认动作和格式。最终交付恢复全六类动作、六种格式、默认应用“不指定”，保留原有全 Finder 覆盖与应用列表 |
| 引导闭环 | 开始时不能完成；真实 Finder 复制目录路径，随后创建 Word，才允许完成。关闭重开和更新后仍显示已完成。见 完成记录（本地证据：`evidence/m2/guide-complete.txt`） |
| 服务注册 | 在 Finder“访达 → 服务”观察到四个入口。发现新建在选中文件时也显示后，build 9 将该服务仅声明为 `public.folder`，去掉会形成“或”匹配的通用 URL 类型 |
| 服务动作 | 通过公开 `NSPerformService` 调用已安装应用，主应用界面完成真实操作。测试时 Finder 扩展停用，证明补充入口不依赖扩展；不是直接调用内部处理函数 |
| 多选复制 | 同时传入 Word 和文件夹，剪贴板与两条完整路径逐字一致。见 复制结果（本地证据：`evidence/m2/services-copy.log`） |
| 服务冷启动 | 确认主应用进程退出后发起复制，系统启动已安装副本并成功复制。首次测试客户端立即读取剪贴板过早；改为最多 2 秒检查最终值后，74 ms 内通过，未改动产品执行逻辑。保留 首次记录（本地证据：`evidence/m2/services-cold-start.log`） 与 复验记录（本地证据：`evidence/m2/services-cold-start-retry.log`） |
| 连续新建 | 服务依次创建 PPTX、DOCX、XLSX；新建流程和目标目录正确，无重复对话框。文件结构校验全部通过 |
| 取消与同名保护 | 取消服务选择后再次新建成功；重复 `M2-引导验证` 自动生成 `M2-引导验证 2.docx`，原文件保留。见 重试证据（本地证据：`evidence/m2/service-retry-name-conflict.txt`） |
| 默认应用 | 设置文本编辑为默认后，服务预选“文本编辑（默认）”；实际打开目标 Word，TextEdit 窗口 URL 匹配。见 打开证据（本地证据：`evidence/m2/service-textedit-open.txt`）。测试后恢复“不指定” |
| Terminal | 服务调用后实际 zsh 工作目录等于 M2 测试目录，未拼接或执行业务命令。见 目录证据（本地证据：`evidence/m2/terminal-cwd.log`） |
| 收尾状态 | Finder 扩展已重新启用；Pending、Processing、Journal 均为 0；配置 v4。见 最终检查（本地证据：`evidence/m2/final-checks.json`） 和 设置界面（本地证据：`evidence/m2/final-menu-settings.txt`） |

服务动作由系统 API 驱动，并以实际应用表单、文件、剪贴板及终端工作目录验证。Finder 菜单栏自动化在展开服务后出现失效的辅助功能元素，因此没有把“逐个点击全部服务菜单”或“所有宿主的上下文过滤”列为通过。build 9 的文件夹服务声明已检查，跨宿主显示矩阵留到 M3。

收尾时电脑自动化连接返回 `native pipe closed before response`，重连未恢复；主应用和扩展进程仍在运行，未发现主应用崩溃报告。因此诊断页的最后一次视觉复查未完成，不列为已验证。此前的菜单设置、引导、服务表单和实际动作证据均已保存。

## 实现边界

- Finder 菜单开关和排序只控制 Finder 扩展；内置格式选择同时影响新建服务。服务不接收任意文本路径，新建/终端/常用应用要求单选。
- 引导验证按会话和目标目录隔离；只把 Finder 来源的创建成功计入新建步骤，服务和应用内测试不会误判为 Finder 已通过。
- 恢复配置的自动测试使用独立临时目录，没有破坏用户真实配置。未用真实账户故障注入替代这项测试。
- 服务没有取得整盘写权限。新建和打开继续使用已有目录书签，缺少授权时仍走目标目录选择流程。
- 新增 `scripts/service-probe.swift` 是开发期集成测试客户端，不随应用运行，也不构成常驻组件。

## M3 待完成

独立干净账户、注销/重新登录、整机重启、macOS 14 与 Intel 实机、云盘/网络盘支持边界、性能采样、不同宿主服务显示、Developer ID 签名、公证下载安装和小范围内测。当前 Gatekeeper 评估仍拒绝开发签名包，不能作为公开下载发行物，详见 安装检查（本地证据：`evidence/m2/install-preflight.log`） 与 [环境矩阵](./INSTALL-TEST-MATRIX.md)。

本轮没有注销或重启用户电脑，也没有改变其他扩展的开关。

## 系统接口依据

- [Apple：Providing a Service](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html)：服务提供者、回调、注册与刷新。
- [Apple：Services Properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html)：文件类型、粘贴板类型、上下文和用户数据声明。

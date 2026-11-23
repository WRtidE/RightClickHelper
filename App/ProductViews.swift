import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "cursorarrow.click.2").font(.system(size: 32)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("右键助手").font(.title.bold())
                    Text("让常用文件操作，就在右键里。 ").foregroundStyle(.secondary)
                }
                Spacer()
                Text("0.7.2 · 本机测试版").font(.caption).padding(8).background(.quaternary, in: Capsule())
            }
            HStack {
                Label(state.extensionEnabled ? "Finder 扩展已启用" : "Finder 扩展尚未启用",
                      systemImage: state.extensionEnabled ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(state.extensionEnabled ? .green : .orange)
                Spacer()
                Button("打开扩展设置") { state.enableExtension() }
                Button("刷新状态") { state.activate() }
            }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            if let notice = state.configurationNotice {
                HStack {
                    Label(notice, systemImage: "exclamationmark.triangle").font(.caption)
                    Button("知道了") { state.configurationNotice = nil }
                }.foregroundStyle(.orange)
            }
            TabView(selection: $state.selectedTab) {
                GeneralSettingsPane().tabItem { Text(SettingsTab.general.rawValue) }.tag(SettingsTab.general)
                GuidePane(state: state).tabItem { Text(SettingsTab.guide.rawValue) }.tag(SettingsTab.guide)
                MenuPane(state: state).tabItem { Text(SettingsTab.menu.rawValue) }.tag(SettingsTab.menu)
                DirectoryPane(state: state).tabItem { Text(SettingsTab.directories.rawValue) }.tag(SettingsTab.directories)
                ApplicationsPane(state: state).tabItem { Text(SettingsTab.applications.rawValue) }.tag(SettingsTab.applications)
                ClipboardSettingsPane().tabItem { Text(SettingsTab.clipboard.rawValue) }.tag(SettingsTab.clipboard)
                DiagnosticsPane(state: state).tabItem { Text(SettingsTab.diagnostics.rawValue) }.tag(SettingsTab.diagnostics)
            }.frame(minHeight: 400, maxHeight: .infinity)
            Text(state.message).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Text("本机处理，无需联网。当前为开发签名测试版，尚未公证。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
}

private struct GuidePane: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(state.guideFinished ? "已完成首次使用测试" : "用三步，确认右键助手可以正常工作").font(.headline)
            guideRow("1. 启用 Finder 扩展", detail: state.extensionEnabled ? "扩展已启用，下面继续测试实际菜单。" : "点击上方“打开扩展设置”，启用 RightClickHelper。", done: state.extensionEnabled)
            VStack(alignment: .leading, spacing: 7) {
                guideRow("2. 选择测试文件夹", detail: state.guideAccessStatus, done: state.guideHasAuthorization)
                HStack {
                    Button(state.guideSession == nil ? "选择测试文件夹…" : "重新选择并测试…") { state.addDirectory(forGuide: true) }
                    Button("使用所选工作目录") { state.useSelectedForGuide() }.disabled(state.selectedDirectory == nil)
                    Button("打开测试文件夹") { state.openGuideFolder() }.disabled(state.guideSession == nil)
                }
                if let session = state.guideSession {
                    Text(session.directoryPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("3. 在测试文件夹空白处右键 → 右键助手").font(.subheadline.bold())
                HStack(spacing: 18) {
                    step("显示菜单", .menu)
                    step("复制路径", .copy)
                    step("新建文件", .create)
                }
                Text("先选择“复制完整路径”，再通过任一“新建”格式创建文件，再返回这里检查结果。只统计本次测试文件夹中的 Finder 操作。")
                    .font(.caption).foregroundStyle(.secondary)
                if !state.guideActionsEnabled {
                    Button("启用引导所需的新建与复制动作") { state.enableGuideActions() }
                }
                HStack {
                    Button("检查测试结果") { state.activate() }
                    Button("完成引导") { state.finishGuide() }.disabled(!state.guideCanFinish || state.guideFinished)
                    if state.guideFinished { Label("已完成", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                }
            }
            Text("已有目录无需重复授权。复制路径不读取文件内容；新建只写入你选定的文件夹。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(16).disabled(!state.ready)
    }
    private func guideRow(_ title: String, detail: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func step(_ title: String, _ step: GuideStep) -> some View {
        Label(title + (state.guideSteps.contains(step) ? "：已通过" : "：待验证"),
              systemImage: state.guideSteps.contains(step) ? "checkmark.circle.fill" : "circle")
            .font(.caption).foregroundStyle(state.guideSteps.contains(step) ? .green : .secondary)
    }
}

private struct MenuPane: View {
    @ObservedObject var state: AppState
    private var selectedIndex: Int? { state.selectedMenuAction.flatMap { state.menuPreferences.order.firstIndex(of: $0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("显示哪些动作，以及它们的顺序").font(.headline)
                Spacer()
                Button("恢复默认菜单") { state.restoreMenuDefaults() }
            }
            List(selection: $state.selectedMenuAction) {
                ForEach(Array(state.menuPreferences.order.enumerated()), id: \.element) { index, action in
                    HStack {
                        Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 20)
                        Toggle(action.title, isOn: Binding(get: { state.menuPreferences.isEnabled(action) }, set: { enabled in
                            state.updateMenu { $0.setEnabled(action, enabled) }
                        })).accessibilityIdentifier("menu-\(action.rawValue)")
                        Spacer()
                    }.tag(action)
                }
            }.frame(height: 190)
            HStack {
                Text("选中一行后调整位置").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("上移") { if let action = state.selectedMenuAction { state.updateMenu { $0.move(action, offset: -1) } } }
                    .disabled(selectedIndex == nil || selectedIndex == 0)
                Button("下移") { if let action = state.selectedMenuAction { state.updateMenu { $0.move(action, offset: 1) } } }
                    .disabled(selectedIndex == nil || selectedIndex == state.menuPreferences.order.count - 1)
            }
            Divider()
            Text("新建文件的格式").font(.subheadline.bold())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading) {
                ForEach(FileTemplate.allCases, id: \.self) { template in
                    Toggle(template.title, isOn: Binding(get: { state.menuPreferences.templates.contains(template) }, set: { state.setTemplate(template, enabled: $0) }))
                        .font(.caption).accessibilityIdentifier("template-\(template.rawValue)")
                }
            }
            Text("动作开关与排序仅影响 Finder 菜单；服务入口独立。新建格式同时用于两种入口。“打开右键助手”始终保留。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(16).disabled(!state.ready)
    }
}

private struct DirectoryPane: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("在桌面和所有 Finder 文件夹显示菜单", isOn: Binding(get: { state.showsMenuEverywhere }, set: { state.setMenuCoverage($0) }))
            Text(state.showsMenuEverywhere ? "菜单覆盖普通文件夹；首次新建或打开时，再为目标目录授权。" : "菜单只在下方有效授权目录及其子目录中显示。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("已授权目录").font(.headline)
                Spacer()
                Button("添加目录…") { state.addDirectory() }
                Button("移除") { state.removeSelectedDirectory() }.disabled(state.selectedDirectory == nil)
            }
            List(selection: $state.selectedID) {
                ForEach(state.directories) { directory in
                    VStack(alignment: .leading) {
                        Label(directory.path, systemImage: "folder").lineLimit(2)
                        if let issue = state.directoryIssues[directory.id] { Text(issue).font(.caption).foregroundStyle(.orange) }
                    }.tag(directory.id)
                }
            }.frame(minHeight: 140, maxHeight: 210)
                .overlay { if state.directories.isEmpty { Text("首次操作时授权，或点击“添加目录…”提前设置。").foregroundStyle(.secondary).allowsHitTesting(false) } }
            HStack {
                Button("在 Finder 中打开") { state.openSelectedDirectory() }
                Button("验证目录授权") { state.verifySelectedAccess() }
                Button("新建测试文本…") { state.createTestFile() }
                Button("重新授权…") { state.addDirectory(replacing: state.selectedID) }
            }.disabled(state.selectedDirectory == nil)
            Text("移除只删除本工具保存的授权记录，不删除文件。全 Finder 模式下菜单仍可见，之后操作会重新询问授权。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(16).disabled(!state.ready)
    }
}

private struct ApplicationsPane: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("常用应用（\(state.applications.count)/5）").font(.headline)
                Spacer()
                Button("添加应用…") { state.addApplication() }
                Button("移除应用") { state.removeSelectedApplication() }.disabled(state.selectedApplicationID == nil)
            }
            List(selection: $state.selectedApplicationID) {
                ForEach(state.applications) { app in
                    Text(app.name + (app.supportsDirectories ? " · 文件和文件夹" : " · 文件") + (app.id == state.menuPreferences.defaultApplicationID ? " · 默认" : ""))
                        .tag(app.id)
                }
            }.frame(minHeight: 140, maxHeight: 190)
            Toggle("所选应用支持文件夹", isOn: Binding(get: {
                state.applications.first { $0.id == state.selectedApplicationID }?.supportsDirectories ?? false
            }, set: { state.setDirectorySupport($0) })).disabled(state.selectedApplicationID == nil)
            Picker("默认常用应用", selection: Binding(get: { state.menuPreferences.defaultApplicationID?.uuidString ?? "" }, set: { value in
                state.updateMenu { $0.defaultApplicationID = UUID(uuidString: value) }
            })) {
                Text("不指定").tag("")
                ForEach(state.applications) { app in Text(app.name).tag(app.id.uuidString) }
            }
            Text("默认应用在适用的菜单中排在首位，并在服务选择框中预选。不会修改系统默认打开方式。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(16).disabled(!state.ready)
    }
}

private struct DiagnosticsPane: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("菜单没出现，或点击后没有完成？").font(.headline)
            Text("① 检查扩展开关；桌面和普通文件夹可用，网页与搜索空白页不提供入口。\n② 检查菜单动作开关与覆盖范围；多选时只显示复制类动作。\n③ 目录授权失效时，到“工作目录”重新授权。只读磁盘仍不能新建。")
                .font(.callout)
            HStack {
                Text(state.showsMenuEverywhere ? "覆盖范围：全 Finder 普通目录" : "覆盖范围：有效授权目录")
                Spacer()
                Text("有效授权：\(state.directories.filter { state.directoryIssues[$0.id] == nil }.count) / \(state.directories.count)")
            }.font(.caption).foregroundStyle(.secondary)
            GroupBox("服务补充入口") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("选中文件或文件夹 → 访达菜单 → 服务 → 右键助手。新建需单选文件夹；终端和常用应用需单选；复制支持多选。")
                        .font(.caption)
                    Button("刷新服务注册") { state.refreshServices() }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            DisclosureGroup("最近操作记录（仅保存在本机）") {
                Text(state.diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("清理过期记录") { state.cleanHistory() }
            }
            if !state.interrupted.isEmpty {
                GroupBox("中断请求（不会自动重试）") {
                    List(selection: $state.selectedInterruptedID) {
                        ForEach(state.interrupted) { item in
                            Text(item.journal?.outputPath ?? item.request?.directoryPath ?? "未知目标")
                                .font(.caption).lineLimit(2).tag(item.id)
                        }
                    }.frame(height: 70)
                    HStack {
                        Button("检查目标目录") { state.inspectInterrupted() }
                        Button("我已检查，确认记录") { state.acknowledgeInterrupted() }
                    }.disabled(state.selectedInterruptedID == nil)
                }
            }
            Spacer(minLength: 0)
        }.padding(16)
    }
}

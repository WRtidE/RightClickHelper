import AppKit

enum SettingsTab: String, CaseIterable {
    case general = "通用"
    case guide = "使用引导", menu = "菜单设置", directories = "工作目录", applications = "常用应用", clipboard = "剪贴板", diagnostics = "诊断"
}

extension AppState {
    var guideHasAuthorization: Bool {
        guard let session = guideSession else { return false }
        return directories.contains {
            directoryIssues[$0.id] == nil && (try? DirectoryBoundary.relativeComponents(
                of: URL(fileURLWithPath: session.directoryPath), within: URL(fileURLWithPath: $0.path))) != nil
        }
    }
    var guideCanFinish: Bool { extensionEnabled && guideHasAuthorization && guideSteps.count == GuideStep.allCases.count }

    var guideActionsEnabled: Bool {
        menuPreferences.isEnabled(.create) && menuPreferences.isEnabled(.copyPath) && !menuPreferences.templates.isEmpty
    }

    var guideAccessStatus: String {
        guard let session = guideSession else { return "尚未选择测试文件夹" }
        let target = URL(fileURLWithPath: session.directoryPath)
        let covered = directories.filter {
            (try? DirectoryBoundary.relativeComponents(of: target, within: URL(fileURLWithPath: $0.path))) != nil
        }
        if covered.contains(where: { directoryIssues[$0.id] == nil }) {
            return guideSteps.contains(.create) ? "目录授权有效，已实际创建文件" : "已保存目录授权，实际写入尚待新建验证"
        }
        return "测试目录授权不可用，请重新选择文件夹"
    }

    func updateMenu(_ change: (inout MenuPreferences) -> Void) {
        let previous = menuPreferences
        change(&menuPreferences)
        do {
            try publishDirectories()
            message = "菜单设置已保存，下次打开 Finder 菜单时生效。"
        } catch { menuPreferences = previous; showError(error) }
    }

    func setTemplate(_ template: FileTemplate, enabled: Bool) {
        updateMenu {
            var selected = Set($0.templates)
            if enabled { selected.insert(template) } else { selected.remove(template) }
            $0.templates = FileTemplate.allCases.filter { selected.contains($0) }
        }
    }

    func restoreMenuDefaults() {
        updateMenu { $0 = MenuPreferences() }
        message = "已恢复菜单动作、排序、内置模板和默认常用应用。目录授权、应用列表及覆盖范围保留。"
    }

    func enableGuideActions() {
        updateMenu {
            $0.setEnabled(.create, true)
            $0.setEnabled(.copyPath, true)
            if $0.templates.isEmpty { $0.templates = FileTemplate.allCases }
        }
    }

    func refreshGuide() {
        guideSession = store?.guideSession()
        if let session = guideSession {
            guideSteps = Set(GuideStep.allCases.filter { store?.guidePassed($0, session: session) == true })
            guideFinished = UserDefaults.standard.string(forKey: "completedGuideID") == session.id.uuidString
        } else { guideSteps = []; guideFinished = false }
    }

    func beginGuide(in directory: URL) throws {
        try withAuthorizedDirectory(directory) { target, _ in _ = try store?.startGuide(in: target) }
        refreshGuide()
        selectedTab = .guide
        message = "在测试文件夹空白处右键，依次完成复制完整路径和新建文件；返回这里检查结果。"
        NSWorkspace.shared.open(directory)
    }

    func useSelectedForGuide() {
        guard let directory = selectedDirectory else { selectedTab = .directories; return }
        do { try beginGuide(in: URL(fileURLWithPath: directory.path)) } catch { showError(error) }
    }

    func openGuideFolder() {
        guard let session = guideSession else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: session.directoryPath))
    }

    func finishGuide() {
        refresh()
        guard guideCanFinish, let session = guideSession else { return }
        UserDefaults.standard.set(session.id.uuidString, forKey: "completedGuideID")
        guideFinished = true
        message = "首次使用测试完成。可以到“菜单设置”保留常用操作并调整顺序。"
    }

    func refreshServices() {
        NSUpdateDynamicServices()
        message = "已请求系统刷新服务。请在 Finder 选中文件或文件夹，再查看“访达 → 服务”。若未出现，在系统“键盘 → 键盘快捷键 → 服务”中启用。"
    }

    func performService(_ action: ServiceAction, urls: [URL]) throws {
        guard ready, let store else { throw PrototypeError.message("应用尚未准备好，请打开右键助手检查状态。") }
        try ServiceSelection.validate(urls, action: action)
        store.record("service", message: "收到 \(action.rawValue) 服务，\(urls.count) 个对象")
        switch action {
        case .copyPath:
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(PathText.absolute(urls), forType: .string) else {
                throw PrototypeError.message("剪贴板写入失败，请重试。")
            }
            store.record("clipboard", message: "服务复制完整路径成功")
            message = "已复制 \(urls.count) 个对象的完整路径。"
            refresh()
        case .terminal:
            let directory = try ActionContext.terminalDirectory(for: urls)
            try store.submit(ActionRequest(directoryPath: directory.path, action: .openTerminal, origin: .service))
            inbox?.wake()
        case .create, .applications:
            guard !isPresentingAction, window?.attachedSheet == nil, NSApp.modalWindow == nil, inbox?.activeID == nil else {
                throw PrototypeError.message("请先完成当前对话框，再使用此服务。")
            }
            // Return to the Services caller immediately; never run a nested modal loop.
            DispatchQueue.main.async { [weak self] in self?.presentServiceChoice(action, target: urls[0]) }
        }
    }

    private func presentServiceChoice(_ action: ServiceAction, target: URL) {
        guard !isPresentingAction, window?.attachedSheet == nil, NSApp.modalWindow == nil, inbox?.activeID == nil else {
            message = "当前还有操作正在处理，请稍后重试服务。"; return
        }
        hideSettingsForExternalAction()
        do {
            try ServiceSelection.validate([target], action: action)
            let directory = try ActionContext.terminalDirectory(for: [target])
            let isDirectory = try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let choices = menuPreferences.eligibleApplications(applications, forDirectory: isDirectory)
            let templates = menuPreferences.templates
            let titles = action == .create ? templates.map(\.title) : choices.map { $0.name + ($0.id == menuPreferences.defaultApplicationID ? "（默认）" : "") }
            guard !titles.isEmpty else {
                throw PrototypeError.message(action == .create ? "请先在菜单设置中启用至少一种新建格式。" : "没有适用的常用应用，请添加应用并确认它是否支持文件夹。")
            }
            let alert = NSAlert()
            alert.messageText = action == .create ? "选择新建文件类型" : "选择常用应用"
            alert.informativeText = "目标：\(target.path)"
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
            popup.addItems(withTitles: titles)
            popup.setAccessibilityLabel(action == .create ? "新建格式" : "常用应用")
            alert.accessoryView = popup
            presentActionDialog(alert) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self else { return }
                    defer { self.inbox?.wake() }
                    guard response == .alertFirstButtonReturn else { self.message = "已取消服务操作。"; return }
                    do {
                        let index = popup.indexOfSelectedItem
                        guard titles.indices.contains(index) else { return }
                        let request = action == .create
                            ? ActionRequest(directoryPath: target.path, template: templates[index], origin: .service)
                            : ActionRequest(directoryPath: directory.path, action: .openApplication,
                                            applicationID: choices[index].id, itemPath: target.path, origin: .service)
                        try self.store?.submit(request)
                    } catch { self.showError(error) }
                }
            }
        } catch { showError(error) }
    }
}

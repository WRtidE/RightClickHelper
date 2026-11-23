import AppKit
import FinderSync
import SwiftUI
import UniformTypeIdentifiers

private struct DirectoryGrant: Codable {
    var directory: ManagedDirectory
    var bookmark: Data
}

private struct ApplicationGrant: Codable {
    var application: FavoriteApplication
    var bookmark: Data
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var directories: [ManagedDirectory] = []
    @Published var extensionEnabled = false
    @Published var message = "启用 Finder 扩展后，可在桌面和普通文件夹中右键。首次新建时选择并授权目标目录。"
    @Published var showsMenuEverywhere = true
    @Published var diagnostics = "尚未收到 Finder 操作。"
    @Published var selectedID: UUID?
    @Published var ready = false
    @Published var directoryIssues: [UUID: String] = [:]
    @Published var interrupted: [InterruptedRequest] = []
    @Published var selectedInterruptedID: UUID?
    @Published var applications: [FavoriteApplication] = []
    @Published var selectedApplicationID: UUID?
    @Published var menuPreferences = MenuPreferences()
    @Published var selectedMenuAction: MenuAction? = .create
    @Published var selectedTab: SettingsTab = .guide
    @Published var guideSession: GuideSession?
    @Published var guideSteps: Set<GuideStep> = []
    @Published var guideFinished = false
    @Published var configurationNotice: String?
    private var grants: [DirectoryGrant] = []
    private var applicationGrants: [ApplicationGrant] = []
    private(set) var store: SharedStore?
    private(set) var inbox: RequestInbox?
    private(set) weak var window: NSWindow?
    private var initialized = false
    private var actionDialog: ActionDialog?
    private var authorizationPanel: NSOpenPanel?
    var isPresentingAction: Bool { actionDialog != nil || authorizationPanel != nil }

    var selectedDirectory: ManagedDirectory? { directories.first { $0.id == selectedID } }

    func attachWindow(_ window: NSWindow) { self.window = window }

    func activate() {
        if initialized { reconcileDirectories() }
        refresh()
        inbox?.wake()
    }

    func showWindow() {
        guard let window else { return }
        RequestTrace.event("settings-present")
        if window.contentView?.identifier?.rawValue != "settings-content" {
            let content = NSHostingView(rootView: ContentView(state: self)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
            content.identifier = NSUserInterfaceItemIdentifier("settings-content")
            window.contentView = content
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideSettingsForExternalAction() {
        // A visible settings window can otherwise be raised by activation/key-window
        // changes, even though the action itself uses a nonactivating panel.
        if window?.isVisible == true { RequestTrace.event("settings-hidden-for-action") }
        window?.orderOut(nil)
    }

    func initialize() {
        guard !initialized else { return }
        initialized = true
        RequestTrace.event("app-initialize")
        do {
            store = try SharedStore()
            do {
                let configuration = try store?.configuration() ?? SharedConfiguration()
                showsMenuEverywhere = configuration.showsMenuEverywhere
                menuPreferences = configuration.menu
            } catch {
                _ = try store?.backUpInvalidConfiguration()
                configurationNotice = "菜单配置损坏，已保留原始备份并恢复默认菜单。目录授权与常用应用保留。"
                // Bookmarks and applications have independent private stores.
                showsMenuEverywhere = true
                menuPreferences = MenuPreferences()
            }
            if FileManager.default.fileExists(atPath: grantsURL.path) {
                grants = try JSONDecoder().decode([DirectoryGrant].self, from: Data(contentsOf: grantsURL))
            }
            if FileManager.default.fileExists(atPath: applicationsURL.path) {
                applicationGrants = try JSONDecoder().decode([ApplicationGrant].self, from: Data(contentsOf: applicationsURL))
                try SharedConfiguration(applications: applicationGrants.map(\.application)).validate()
            }
            applications = applicationGrants.map(\.application)
            if !applications.contains(where: { $0.id == menuPreferences.defaultApplicationID }) {
                menuPreferences.defaultApplicationID = nil
            }
            reconcileDirectories()
            try store?.pruneHistory()
            let interrupted = try store?.interruptedCount() ?? 0
            if interrupted > 0 {
                message = "有 \(interrupted) 个上次中断的请求。请检查目标文件夹；为避免重复创建，不会自动重试。"
            }
            refresh()
            guard let store else { return }
            let inbox = RequestInbox(store: store, canPresent: { [weak self] in
                self?.window != nil && self?.isPresentingAction == false && self?.window?.attachedSheet == nil && NSApp.modalWindow == nil
            }, present: { [weak self] request, completion in
                self?.execute(request, completion: completion)
            }, failed: { [weak self] error in
                // Rejected stale requests must not queue a series of modal alerts.
                self?.message = error.localizedDescription
                self?.store?.record("creation", message: "请求处理或状态保存异常，请检查最近结果。")
                self?.refresh()
            })
            self.inbox = inbox
            try inbox.start()
            ready = true
            selectedID = directories.first?.id
        } catch { showError(error) }
    }

    func refresh() {
        extensionEnabled = FIFinderSyncController.isExtensionEnabled
        let keys = [("extension", "扩展"), ("menu", "菜单"), ("clipboard", "复制"), ("creation", "创建"), ("open", "打开"), ("service", "服务")]
        diagnostics = keys.compactMap { key, label in
            guard let event = store?.event(key) else { return nil }
            return "\(label) · \(event.time.formatted(date: .omitted, time: .standard)) · \(event.message)"
        }.joined(separator: "\n")
        if diagnostics.isEmpty { diagnostics = "尚未收到 Finder 操作。" }
        interrupted = (try? store?.interruptedRequests(excluding: inbox?.activeID)) ?? []
        refreshGuide()
    }

    func enableExtension() { FIFinderSyncController.showExtensionManagementInterface() }

    func setMenuCoverage(_ everywhere: Bool) {
        let previous = showsMenuEverywhere
        showsMenuEverywhere = everywhere
        do {
            try publishDirectories()
            message = everywhere ? "菜单已扩展至 Finder 的普通文件夹与桌面；新目录首次操作时再授权。" : "菜单仅在已授权目录及子目录显示。"
        } catch { showsMenuEverywhere = previous; showError(error) }
    }

    func addDirectory(replacing id: UUID? = nil, forGuide: Bool = false) {
        defer { inbox?.wake() }
        let panel = NSOpenPanel()
        panel.title = forGuide ? "选择一个测试文件夹" : (id == nil ? "添加已授权目录" : "重新选择并授权工作目录")
        panel.message = "允许在所选目录及子目录中新建文件、打开终端与常用应用。"
        panel.prompt = "添加并授权"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try saveDirectoryGrant(url, replacing: id)
            if forGuide { try beginGuide(in: url); return }
            message = "目录已授权。请打开该目录，在空白处或文件上右键。"
        } catch { showError(error) }
    }

    private func saveDirectoryGrant(_ url: URL, replacing id: UUID? = nil) throws {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true,
                  url.path != "/" else {
                throw PrototypeError.message("请选择普通工作目录；原型不接受整个磁盘、包或符号链接。")
            }
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            if let id, let index = grants.firstIndex(where: { $0.directory.id == id }) {
                guard !grants.contains(where: { $0.directory.id != id && $0.directory.path == url.path }) else {
                    throw PrototypeError.message("该目录已存在，请选择已有目录或移除重复记录。")
                }
                grants[index] = DirectoryGrant(directory: ManagedDirectory(id: id, path: url.path), bookmark: bookmark)
                directoryIssues.removeValue(forKey: id)
                selectedID = id
            } else if let index = grants.firstIndex(where: { $0.directory.path == url.path }) {
                grants[index].bookmark = bookmark
                directoryIssues.removeValue(forKey: grants[index].directory.id)
                selectedID = grants[index].directory.id
            } else {
                guard grants.count < 100 else { throw PrototypeError.message("最多保存 100 个目录，请先移除不再使用的授权。") }
                let directory = ManagedDirectory(id: UUID(), path: url.path)
                grants.append(DirectoryGrant(directory: directory, bookmark: bookmark))
                selectedID = directory.id
            }
            try saveGrants()
            try publishDirectories()
    }

    func removeSelectedDirectory() {
        guard let id = selectedID else { return }
        grants.removeAll { $0.directory.id == id }
        do {
            try saveGrants()
            try publishDirectories()
            selectedID = directories.first?.id
            message = showsMenuEverywhere ? "已移除保存的目录授权；菜单仍可见，下次操作会重新请求授权。" : "已移除保存的目录授权与菜单覆盖。"
        } catch { showError(error) }
    }

    func openSelectedDirectory() {
        guard let directory = selectedDirectory else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: directory.path))
    }

    func verifySelectedAccess() {
        reconcileDirectories()
        guard let directory = selectedDirectory else { return }
        do {
            try withAuthorizedDirectory(URL(fileURLWithPath: directory.path)) { target, _ in
                _ = try target.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
            }
            message = "目录授权可解析。实际写入权限请通过“新建测试文本…”验证。"
        } catch { showError(error) }
    }

    func createTestFile() {
        guard let directory = selectedDirectory else { return }
        do {
            try store?.submit(CreateRequest(directoryPath: directory.path, template: .txt, origin: .app))
            inbox?.wake()
        } catch { showError(error) }
    }

    func receive(_ urls: [URL]) {
        RequestTrace.event("url-callback")
        initialize()
        for url in urls {
            guard url.scheme == "rightclickhelper-prototype" else { continue }
            if url.host == "settings" { showWindow(); continue }
            guard url.host == "request", url.query == nil, url.fragment == nil,
                  let id = UUID(uuidString: String(url.path.dropFirst())) else {
                message = "已忽略无效的外部调用。"
                continue
            }
            RequestTrace.event("url-received", id: id)
            inbox?.wake()
        }
    }

    private func execute(_ request: ActionRequest, completion: @escaping RequestInbox.Completion) {
        if request.origin != .app { hideSettingsForExternalAction() }
        reconcileDirectories()
        let target = URL(fileURLWithPath: request.directoryPath)
        let hasGrant = grants.contains {
            directoryIssues[$0.directory.id] == nil &&
            (try? DirectoryBoundary.relativeComponents(of: target, within: URL(fileURLWithPath: $0.directory.path))) != nil
        }
        guard hasGrant else { authorizeRequest(request, completion: completion); return }
        executeAuthorized(request, completion: completion)
    }

    /// Keep the queue's active request claimed while the user grants exactly its
    /// captured directory. Cancelling must finish it so later requests can run.
    private func authorizeRequest(_ request: ActionRequest, completion: @escaping RequestInbox.Completion) {
        let target = URL(fileURLWithPath: request.directoryPath, isDirectory: true)
        let panel = NSOpenPanel()
        panel.title = "授权此文件夹"
        panel.message = "首次使用，请选择当前目标文件夹：\n\(target.path)\n授权后继续本次操作，并记住此目录。取消不会执行操作。"
        panel.prompt = "授权并继续"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.directoryURL = target
        authorizationPanel = panel
        panel.begin { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { completion("主应用关闭，未执行"); return }
                self.authorizationPanel = nil
                guard response == .OK, let selected = panel.url else {
                    self.message = "已取消授权，未执行操作。"
                    completion("用户取消授权")
                    return
                }
                do {
                    try ActionContext.validateAuthorizationSelection(selected, for: target)
                    try self.saveDirectoryGrant(selected)
                    self.executeAuthorized(request, completion: completion)
                } catch { self.showError(error) { completion("目录授权未完成，未执行") } }
            }
        }
    }

    private func executeAuthorized(_ request: ActionRequest, completion: @escaping RequestInbox.Completion) {
        switch request.action {
        case .create: presentCreation(request, completion: completion)
        case .openTerminal:
            do {
                guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                    throw PrototypeError.message("找不到系统 Terminal。")
                }
                try withAuthorizedDirectory(URL(fileURLWithPath: request.directoryPath)) { directory, root in
                    try openTarget(directory, application: application, root: root, completion: completion)
                }
            } catch { showError(error) { completion("终端打开失败") } }
        case .openApplication:
            do {
                guard let grant = applicationGrants.first(where: { $0.application.id == request.applicationID }), let path = request.itemPath else {
                    throw PrototypeError.message("此常用应用已移除，请重新打开菜单或添加应用。")
                }
                let target = URL(fileURLWithPath: path)
                let application = try resolveApplication(grant)
                try withAuthorizedDirectory(URL(fileURLWithPath: request.directoryPath)) { container, root in
                    let actual = try ActionContext.terminalDirectory(for: [target])
                    guard actual.standardizedFileURL.path == container.standardizedFileURL.path else {
                        throw PrototypeError.message("目标上下文已改变，请重新打开菜单。")
                    }
                    let isDirectory = try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                    guard !isDirectory || grant.application.supportsDirectories else {
                        throw PrototypeError.message("该应用尚未设置为支持文件夹。")
                    }
                    try openTarget(target, application: application, root: root, completion: completion)
                }
            } catch { showError(error) { completion("常用应用打开失败") } }
        }
    }

    private func openTarget(_ target: URL, application: URL, root: URL, completion: @escaping RequestInbox.Completion) throws {
        guard root.startAccessingSecurityScopedResource() else { throw PrototypeError.message("授权失效，请重新授权目录。") }
        let appScoped = application.startAccessingSecurityScopedResource()
        // Keep a second scoped reference alive until the asynchronous open completes.
        // URLs are data: do not generate shell scripts, AppleScript, or command strings.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([target], withApplicationAt: application, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                root.stopAccessingSecurityScopedResource()
                if appScoped { application.stopAccessingSecurityScopedResource() }
                guard let self else { completion("应用关闭"); return }
                if let error {
                    self.store?.record("open", message: "打开失败：\((error as NSError).domain)/\((error as NSError).code)")
                    self.showError(error) { completion("打开失败") }
                } else {
                    self.message = "已向 \(application.deletingPathExtension().lastPathComponent) 提交打开请求。"
                    self.store?.record("open", message: "打开请求已提交")
                    completion("已提交打开请求")
                    self.refresh()
                }
            }
        }
    }

    private func presentCreation(_ request: CreateRequest, completion: @escaping RequestInbox.Completion) {
        let directory = URL(fileURLWithPath: request.directoryPath)
        guard let template = request.template else { completion("模板缺失，未执行"); return }
        do {
            try withAuthorizedDirectory(directory) { _, _ in }
            let alert = NSAlert()
            alert.messageText = "新建\(template.title)"
            alert.informativeText = "创建到：\(directory.path)\n同名时自动添加序号，不覆盖已有文件。"
            alert.addButton(withTitle: "创建")
            alert.addButton(withTitle: "取消")
            let field = NSTextField(string: "未命名")
            field.frame = NSRect(x: 0, y: 0, width: 340, height: 26)
            field.placeholderString = "文件名（不含 .\(template.rawValue)）"
            field.setAccessibilityLabel("新文件名称")
            alert.accessoryView = field
            RequestTrace.event("dialog-present", id: request.id)
            presentActionDialog(alert) { [weak self] response in
                guard let self else { completion("主应用关闭"); return }
                // Complete the UI callback before processing the next request.
                DispatchQueue.main.async {
                    guard response == .alertFirstButtonReturn else {
                        self.message = "已取消新建，未创建文件。"
                        completion("用户取消")
                        return
                    }
                    do {
                        let started = DispatchTime.now().uptimeNanoseconds
                        let output = try self.withAuthorizedDirectory(directory) { target, root in
                            try FileCreator.create(in: target, authorizedRoot: root, name: field.stringValue, template: template) { candidate in
                                try self.store?.journal(request.id, output: candidate, stage: .planned)
                            }
                        }
                        // Never describe a post-write bookkeeping failure as a failed create.
                        do { try self.store?.journal(request.id, output: output, stage: .written) }
                        catch {
                            self.message = "文件已创建，但状态保存失败。请检查目标目录，不要重复创建。"
                            completion("文件已创建，日志保存失败，请检查")
                            self.refresh()
                            return
                        }
                        self.message = "已创建：\(output.lastPathComponent)"
                        self.store?.record("creation", message: "\(template.rawValue.uppercased()) 创建成功")
                        if request.origin == .finder { self.store?.recordGuideStep(.create, targets: [directory]) }
                        RequestTrace.event("file-created", id: request.id)
                        RequestTrace.duration("create-file", since: started)
                        completion("创建成功")
                        self.refresh()
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    } catch {
                        self.creationFailed(error, id: request.id, completion: completion)
                    }
                }
            }
        } catch {
            creationFailed(error, id: request.id, completion: completion)
        }
    }

    private func creationFailed(_ error: Error, id: UUID, completion: @escaping RequestInbox.Completion) {
        let result = "创建失败：\((error as NSError).domain)/\((error as NSError).code)"
        store?.record("creation", message: result)
        RequestTrace.event("creation-failed", id: id)
        showError(error) { completion(result) }
    }

    func withAuthorizedDirectory<T>(_ target: URL, operation: (URL, URL) throws -> T) throws -> T {
        reconcileDirectories()
        let matching = grants.indices.filter {
            (try? DirectoryBoundary.relativeComponents(of: target, within: URL(fileURLWithPath: grants[$0].directory.path))) != nil
        }.sorted { grants[$0].directory.path.count > grants[$1].directory.path.count }
        guard let index = matching.first else {
            throw PrototypeError.message("此目录未授权或已移除。请在主窗口重新添加目标目录。")
        }
        if let issue = directoryIssues[grants[index].directory.id] {
            throw PrototypeError.message(issue + "。在工作目录中选中该记录，点击“重新授权…”。")
        }
        var stale = false
        let root = try URL(resolvingBookmarkData: grants[index].bookmark,
                           options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard root.startAccessingSecurityScopedResource() else {
            throw PrototypeError.message("目录授权已不可用，请重新选择并授权该目录。")
        }
        defer { root.stopAccessingSecurityScopedResource() }
        guard root.standardizedFileURL.path == grants[index].directory.path else {
            throw PrototypeError.message("授权目录已移动，请移除旧记录并重新添加目录。")
        }
        try ActionContext.validateOrdinaryDirectory(target, within: root)
        let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey])
        guard values.isDirectory == true, values.isPackage != true,
              values.isSymbolicLink != true, values.isAliasFile != true else {
            throw PrototypeError.message("目标不是普通目录，或是包、替身、符号链接。请选择真实目录。")
        }
        if stale {
            grants[index].bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            try saveGrants()
        }
        return try operation(target, root)
    }

    /// Resolve moved bookmarks before publishing coverage; retain invalid grants
    /// in the settings list so they can be explicitly repaired or removed.
    private func reconcileDirectories() {
        let oldGrants = grants
        var issues: [UUID: String] = [:]
        for index in grants.indices {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: grants[index].bookmark,
                    options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw PrototypeError.message("授权失效，请重新授权") }
                defer { url.stopAccessingSecurityScopedResource() }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey])
                guard values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true, values.isAliasFile != true else {
                    throw PrototypeError.message("目录不可用，请重新选择")
                }
                if stale || url.path != grants[index].directory.path {
                    grants[index].bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    grants[index].directory.path = url.path
                }
            } catch { issues[grants[index].directory.id] = "目录不可用或授权失效，请重新授权" }
        }
        directoryIssues = issues
        do {
            if oldGrants.map(\.directory) != grants.map(\.directory) || zip(oldGrants, grants).contains(where: { pair in pair.0.bookmark != pair.1.bookmark }) {
                try saveGrants()
            }
            try publishDirectories()
        } catch { message = error.localizedDescription }
    }

    func inspectInterrupted() {
        guard let item = interrupted.first(where: { $0.id == selectedInterruptedID }),
              let path = item.request?.directoryPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        message = item.journal.map { "上次候选文件：\($0.outputPath)；\($0.stage == .written ? "已完成写入，仍请检查文件" : "创建结果不确定，请检查，可能是已有同名文件")。不会自动重试或删除。" }
            ?? "请求在记录目标前中断；请检查目录。不会自动重试。"
    }

    func acknowledgeInterrupted() {
        guard let id = selectedInterruptedID, interrupted.contains(where: { $0.id == id }) else { return }
        do {
            try store?.finish(id, message: "用户已检查中断请求；不重试、不修改文件")
            selectedInterruptedID = nil
            refresh()
            message = "已确认该中断记录，未修改任何用户文件。"
        } catch { showError(error) }
    }

    func cleanHistory() {
        do {
            let count = try store?.pruneHistory() ?? 0
            message = "已清理 \(count) 条过期记录；保留最近 7 天最多 500 条结果和全部近 10 分钟记录。未确认的中断记录保留。"
            refresh()
        } catch { showError(error) }
    }

    private var grantsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RightClickHelper/grants.json")
    }

    private var applicationsURL: URL { grantsURL.deletingLastPathComponent().appendingPathComponent("applications.json") }

    func addApplication() {
        defer { inbox?.wake() }
        let panel = NSOpenPanel()
        panel.title = "添加常用应用（最多 5 个）"
        panel.prompt = "添加应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
                  bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
                  identifier != Bundle.main.bundleIdentifier else {
                throw PrototypeError.message("请选择有效的本机应用，不能选择右键助手自身。")
            }
            var updated = applicationGrants
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            if let index = updated.firstIndex(where: { $0.application.bundleIdentifier == identifier }) {
                updated[index].bookmark = bookmark
                updated[index].application.name = name
                selectedApplicationID = updated[index].application.id
            } else {
                guard updated.count < 5 else { throw PrototypeError.message("最多添加 5 个常用应用，请先移除一个。") }
                let app = FavoriteApplication(bundleIdentifier: identifier, name: name)
                updated.append(ApplicationGrant(application: app, bookmark: bookmark))
                selectedApplicationID = app.id
            }
            try saveApplications(updated)
            message = "已添加应用。只有确认应用能打开文件夹后，才勾选“支持文件夹”。"
            refresh()
        } catch { showError(error) }
    }

    func removeSelectedApplication() {
        do {
            try saveApplications(applicationGrants.filter { $0.application.id != selectedApplicationID })
            selectedApplicationID = nil
        } catch { showError(error) }
    }

    func setDirectorySupport(_ enabled: Bool) {
        guard let index = applicationGrants.firstIndex(where: { $0.application.id == selectedApplicationID }) else { return }
        var updated = applicationGrants
        updated[index].application.supportsDirectories = enabled
        do { try saveApplications(updated) } catch { showError(error) }
    }

    private func saveApplications(_ updated: [ApplicationGrant]) throws {
        try SharedConfiguration(applications: updated.map(\.application)).validate()
        try FileManager.default.createDirectory(at: applicationsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: applicationsURL, options: .atomic)
        applicationGrants = updated
        applications = updated.map(\.application)
        if !applications.contains(where: { $0.id == menuPreferences.defaultApplicationID }) {
            menuPreferences.defaultApplicationID = nil
        }
        try publishDirectories()
    }

    private func resolveApplication(_ grant: ApplicationGrant) throws -> URL {
        // Launch Services follows normal application moves and updates. Fall back
        // to the user-selected bookmark; never accept an arbitrary request app path.
        var stale = false
        let bookmarked = try? URL(resolvingBookmarkData: grant.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let candidates = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: grant.application.bundleIdentifier), bookmarked].compactMap { $0 }
        for candidate in candidates {
            let scoped = candidate.startAccessingSecurityScopedResource()
            defer { if scoped { candidate.stopAccessingSecurityScopedResource() } }
            if let bundle = Bundle(url: candidate), bundle.bundleIdentifier == grant.application.bundleIdentifier,
               bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
               let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) { return candidate }
        }
        throw PrototypeError.message("找不到 \(grant.application.name)。应用可能已卸载，请在“常用应用”中重新添加。")
    }

    private func saveGrants() throws {
        try FileManager.default.createDirectory(at: grantsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(grants).write(to: grantsURL, options: .atomic)
    }

    func publishDirectories() throws {
        directories = grants.map(\.directory)
        let valid = directories.filter { directoryIssues[$0.id] == nil }
        let previous = try? store?.configuration()
        guard previous?.directories != valid || previous?.applications != applications ||
              previous?.showsMenuEverywhere != showsMenuEverywhere || previous?.menu != menuPreferences || previous?.version != 4 else { return }
        try store?.saveConfiguration(SharedConfiguration(directories: valid, applications: applications,
                                                        showsMenuEverywhere: showsMenuEverywhere, menu: menuPreferences))
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(SharedStore.configurationChanged), object: nil, userInfo: nil, deliverImmediately: true)
    }

    func presentActionDialog(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !isPresentingAction else { completion(.cancel); return }
        let dialog = ActionDialog(alert: alert) { [weak self] response in
            self?.actionDialog = nil
            completion(response)
            self?.inbox?.wake()
        }
        actionDialog = dialog
        dialog.show()
    }

    func showError(_ error: Error, completion: @escaping () -> Void = {}) {
        message = error.localizedDescription
        guard !isPresentingAction, window?.attachedSheet == nil else { completion(); return }
        let alert = NSAlert()
        alert.messageText = "操作未完成"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        presentActionDialog(alert) { [weak self] _ in
            DispatchQueue.main.async {
                completion()
                self?.inbox?.wake()
            }
        }
    }
}

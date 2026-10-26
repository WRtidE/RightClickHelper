import Cocoa
import FinderSync
import OSLog

final class FinderSync: FIFinderSync {
    private var store: SharedStore?
    private var watcher: DispatchSourceFileSystemObject?
    private var applications: [FavoriteApplication] = []
    private var preferences = MenuPreferences()
    private enum Payload {
        case copy(String, String, [URL])
        case create(CreateRequest)
    }
    private var payloads: [Int: (Date, Payload)] = [:]
    private var nextTag = 1
    private let logger = Logger(subsystem: "dev.rightclickhelper.prototype", category: "FinderExtension")

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = []
        do {
            store = try SharedStore()
            reloadConfiguration()
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(configurationChanged),
                name: Notification.Name(SharedStore.configurationChanged), object: nil)
            if let root = store?.root {
                let fd = open(root.path, O_EVTONLY)
                if fd >= 0 {
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
                    source.setEventHandler { [weak self] in self?.reloadConfiguration() }
                    source.setCancelHandler { close(fd) }
                    source.resume()
                    watcher = source
                }
            }
            store?.record("extension", message: "扩展已加载，目录数：\(FIFinderSyncController.default().directoryURLs.count)")
        } catch { logger.error("Shared container initialization failed: \(error.localizedDescription, privacy: .private)") }
    }

    deinit {
        watcher?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func configurationChanged() { reloadConfiguration() }

    private func reloadConfiguration() {
        do {
            let configuration = try store?.configuration() ?? SharedConfiguration()
            applications = configuration.applications
            preferences = configuration.menu
            let controller = FIFinderSyncController.default()
            if controller.directoryURLs != configuration.menuDirectoryURLs {
                controller.directoryURLs = configuration.menuDirectoryURLs
            }
        } catch {
            applications = []
            FIFinderSyncController.default().directoryURLs = []
            logger.error("Configuration unavailable")
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let started = DispatchTime.now().uptimeNanoseconds
        payloads = payloads.filter { Date().timeIntervalSince($0.value.0) < 600 }
        let controller = FIFinderSyncController.default()
        let target = controller.targetedURL()
        let selected = controller.selectedItemURLs() ?? []
        let urls: [URL]
        switch menuKind {
        case .contextualMenuForContainer, .contextualMenuForSidebar: urls = target.map { [$0] } ?? []
        case .contextualMenuForItems: urls = selected
        default: return nil
        }
        guard !urls.isEmpty, urls.count <= 1000, urls.allSatisfy(\.isFileURL) else { return nil }
        let menu = NSMenu()
        let root = NSMenuItem(title: "右键助手", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil)
        root.image?.size = NSSize(width: 16, height: 16)
        root.image?.isTemplate = true
        let actions = NSMenu()
        actions.autoenablesItems = false
        // Finder renders separators as full-height empty rows on macOS 26.
        root.submenu = actions
        menu.addItem(root)
        let container = menuKind == .contextualMenuForContainer ? target : nil
        let ordinaryDirectory = urls.count == 1 ? urls.first.flatMap { url -> URL? in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey]),
                  values.isDirectory == true, values.isPackage != true,
                  values.isSymbolicLink != true, values.isAliasFile != true else { return nil }
            return url
        } : nil
        // Metadata may not yet be readable for a background target. The app
        // checks the exact directory again after its own authorization flow.
        let creationDirectory = ordinaryDirectory ?? container
        let openDirectory = (try? ActionContext.terminalDirectory(for: urls)) ?? container
        let favorites = preferences.eligibleApplications(applications, forDirectory: creationDirectory != nil)
        for action in preferences.visibleActions(canCreate: creationDirectory != nil,
                                                  canOpen: openDirectory != nil, hasApplications: !favorites.isEmpty) {
            let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.target = self
            switch action {
            case .create:
                guard let directory = creationDirectory else { continue }
                let templates = NSMenu()
                for template in preferences.templates {
                    templates.addItem(requestItem(template.title + "…", request: ActionRequest(directoryPath: directory.path, template: template)))
                }
                item.submenu = templates
            case .copyPath, .copyName, .copyShell:
                let value: String
                switch action {
                case .copyPath: value = PathText.absolute(urls)
                case .copyName: value = PathText.names(urls)
                default: value = PathText.shell(urls)
                }
                item.action = #selector(copyText(_:))
                item.tag = retain(.copy(action.title, value, urls))
            case .terminal:
                guard let directory = openDirectory else { continue }
                item.action = #selector(createFile(_:))
                item.tag = retain(.create(ActionRequest(directoryPath: directory.path, action: .openTerminal)))
            case .applications:
                guard let directory = openDirectory, let target = urls.first else { continue }
                let choices = NSMenu()
                for app in favorites {
                    let name = app.name + (app.id == preferences.defaultApplicationID ? "（默认）" : "")
                    choices.addItem(requestItem(name, request: ActionRequest(directoryPath: directory.path, action: .openApplication,
                                                                            applicationID: app.id, itemPath: target.path)))
                }
                item.submenu = choices
            }
            actions.addItem(item)
        }
        // Always keep the recovery/settings entry, even when all actions are off.
        let settings = NSMenuItem(title: "打开右键助手…", action: #selector(openSettings), keyEquivalent: "")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.target = self
        actions.addItem(settings)
        store?.record("menu", message: "菜单已显示，\(urls.count) 个对象")
        store?.recordGuideStep(.menu, targets: urls)
        RequestTrace.duration("menu-build", since: started)
        return menu
    }

    private func requestItem(_ title: String, request: ActionRequest) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(createFile(_:)), keyEquivalent: "")
        item.target = self
        item.tag = retain(.create(request))
        return item
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        let started = DispatchTime.now().uptimeNanoseconds
        guard case let .copy(title, value, targets) = payloads[sender.tag]?.1 else {
            store?.record("clipboard", message: "菜单上下文已失效，请重新打开菜单。")
            return
        }
        NSPasteboard.general.clearContents()
        let success = NSPasteboard.general.setString(value, forType: .string)
        store?.record("clipboard", message: success ? "\(title)成功" : "剪贴板写入失败")
        if success { store?.recordGuideStep(.copy, targets: targets) }
        else { NSSound.beep() }
        RequestTrace.duration("copy-path", since: started)
    }

    @objc private func createFile(_ sender: NSMenuItem) {
        guard case var .create(request) = payloads[sender.tag]?.1, let store else { return }
        // A fresh invocation has a fresh identity, but retains the captured target.
        request.id = UUID()
        request.createdAt = Date()
        do {
            try store.submit(request)
            let url = URL(string: "rightclickhelper-prototype://request/\(request.id.uuidString)")!
            openCompanion(url)
        } catch {
            store.record("creation", message: "请求提交失败，请打开主应用检查。")
            logger.error("Request failed: \(error.localizedDescription, privacy: .private)")
            NSSound.beep()
        }
    }

    @objc private func openSettings() {
        openCompanion(URL(string: "rightclickhelper-prototype://settings")!)
    }

    // Finder proxies menu items across processes. representedObject is not a
    // reliable transport; the integer tag addresses our immutable local snapshot.
    private func retain(_ payload: Payload) -> Int {
        let tag = nextTag
        nextTag += 1
        payloads[tag] = (Date(), payload)
        if payloads.count > 2048, let oldest = payloads.keys.min() { payloads.removeValue(forKey: oldest) }
        return tag
    }

    private func openCompanion(_ url: URL) {
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { [weak self] _, error in
            RequestTrace.event(error == nil ? "companion-open-ok" : "companion-open-failed")
            if error != nil {
                self?.store?.record("creation", message: "无法启动主应用；请手动打开右键助手处理请求。")
            }
        }
    }
}

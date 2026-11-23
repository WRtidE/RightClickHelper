import SwiftUI
import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        prepareWindow()
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        ClipboardController.shared.setup()
        // Finder URL launches and Services must not open the settings window.
        // Pending work also covers recovery launches before the URL callback arrives.
        let isDefaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber)?.boolValue ?? false
        let hasPending = ((try? AppState.shared.store?.pendingIDs()) ?? []).isEmpty == false
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLoginItem = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        LoginItemController.shared.refresh()
        RequestTrace.event(isLoginItem ? "launch-login-item" : "launch-interactive-or-action")
        if LaunchPresentation.shouldShowSettings(isDefaultLaunch: isDefaultLaunch, isLoginItem: isLoginItem,
                                                 hasPendingRequests: hasPending,
                                                 hasActiveRequest: AppState.shared.inbox?.activeID != nil) {
            AppState.shared.showWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppState.shared.activate()
        LoginItemController.shared.refresh()
        ClipboardController.shared.refreshPermissions()
    }
    func applicationWillTerminate(_ notification: Notification) { ClipboardController.shared.stop() }
    func application(_ application: NSApplication, open urls: [URL]) {
        prepareWindow()
        AppState.shared.receive(urls)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        prepareWindow()
        let state = AppState.shared
        // Launch Services may send reopen while waking the app for a Finder action.
        // The inbox may already have claimed the request before this callback runs.
        let pending = (try? state.store?.pendingIDs()) ?? []
        if LaunchPresentation.shouldShowSettingsOnReopen(hasPendingRequests: !pending.isEmpty,
                                                         hasActiveRequest: state.inbox?.activeID != nil,
                                                         hasActionDialog: state.isPresentingAction) {
            state.showWindow()
        } else {
            RequestTrace.event("reopen-settings-suppressed")
        }
        state.activate()
        // All presentation is handled above. Do not let AppKit reorder old windows.
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the single settings window available for explicit reopening.
        sender.orderOut(nil)
        // Settings state lives in AppState; background work does not need its view tree.
        sender.contentView = nil
        return false
    }

    private func prepareWindow() {
        guard mainWindow == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "右键助手"
        window.contentMinSize = NSSize(width: 760, height: 740)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Build SwiftUI settings only when explicitly shown, not on Finder/login launch.
        window.center()
        mainWindow = window
        AppState.shared.attachWindow(window)
        AppState.shared.initialize()
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "右键助手")
        appMenu.addItem(withTitle: "关于右键助手", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏右键助手", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出右键助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                                     ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}

@main
enum RightClickHelperApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Remain an agent even when an action or settings window becomes key.
        // LSUIElement also prevents a transient Dock icon before main() runs.
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

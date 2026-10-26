import AppKit
import SwiftUI
import Carbon
import QuartzCore

private final class ClipboardFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipboardController: NSObject, ObservableObject, NSWindowDelegate, NSMenuDelegate {
    static let shared = ClipboardController()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "clipboardHistoryEnabled")
    @Published private(set) var paused = false
    @Published private(set) var autoPaste = UserDefaults.standard.bool(forKey: "clipboardAutoPasteEnabled")
    @Published private(set) var history = ClipboardHistory()
    @Published private(set) var shortcutStatus = "尚未启用"
    @Published private(set) var recordingStatus = "尚未启用"
    @Published private(set) var pasteAllowed = false
    @Published var message = "启用后记录新复制的文本；历史只保存在内存中。"
    @Published var query = ""
    @Published var selectedID: UUID?
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount = 0
    private var timer: Timer?
    private var panel: NSPanel?
    private enum PanelStyle { case compact, manager }
    private var panelStyle: PanelStyle = .compact
    private var presentationGeneration = UUID()
    private var isHidingPanel = false
    private var panelKeys: Any?
    private var statusItem: NSStatusItem?
    private var sourceApplication: NSRunningApplication?
    private var pasteGeneration = UUID()
    private var sleeping = false
    private var sessionInactive = false
    private var suspended: Bool { sleeping || sessionInactive }
    private var prepared = false
    private lazy var shortcut = LeftShiftMonitor { [weak self] in
        guard let self, self.enabled, !self.suspended, !IsSecureEventInputEnabled() else { return }
        self.togglePanel()
    }

    var filteredItems: [ClipboardHistoryItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? history.items : history.items.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    func setup() {
        guard !prepared else { return }
        prepared = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(suspend(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(suspend(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(resume(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(resume(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        if enabled { start() }
        refreshPermissions()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "clipboardHistoryEnabled")
        if value {
            start()
            message = "已启用。请检查剪贴板读取与左 Shift 监听权限，再复制测试文字。"
        } else {
            stop()
            history.clear()
            hidePanel()
            message = "已停用并清空内存历史。"
        }
        refreshPermissions()
    }

    func setPaused(_ value: Bool) {
        paused = value
        lastChangeCount = pasteboard.changeCount
        message = value ? "记录已暂停，仍可查看已有历史。" : "已恢复记录，只收集之后新复制的文本。"
        refreshPermissions()
    }

    func setAutoPaste(_ value: Bool) {
        autoPaste = value
        UserDefaults.standard.set(value, forKey: "clipboardAutoPasteEnabled")
        pasteGeneration = UUID()
        refreshPermissions()
        message = value ? "自动粘贴已选择；需要辅助功能权限，未授权时仅复制。" : "选择历史后仅复制，可在目标应用按 ⌘V。"
    }

    func requestClipboardAccess() {
        guard enabled else { return }
        // One explicit attempt only. Do not add the existing clipboard to history.
        _ = pasteboard.string(forType: .string)
        lastChangeCount = pasteboard.changeCount
        refreshPermissions()
        message = "如系统询问，请允许右键助手读取剪贴板。后台历史需要设为“始终允许”；完成后点击“刷新权限状态”。"
    }

    func requestShortcutAccess() {
        guard enabled else { return }
        _ = CGRequestListenEventAccess()
        refreshPermissions()
        message = "在系统“隐私与安全性 → 输入监控”中允许 RightClickHelper；完成后刷新权限状态。若系统要求，退出再打开本应用。"
    }

    func requestPasteAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
        message = "在系统“隐私与安全性 → 辅助功能”中允许 RightClickHelper；自动粘贴只在你选择记录后触发。"
    }

    func refreshPermissions() {
        pasteAllowed = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        if enabled && !suspended {
            if CGPreflightListenEventAccess() {
                shortcutStatus = shortcut.start() ? "双击左 Shift：已启用" : "监听暂不可用，请退出应用后重开"
            } else {
                shortcut.stop()
                shortcutStatus = "双击左 Shift：等待输入监控授权"
            }
        } else {
            shortcutStatus = suspended ? "休眠或会话未激活期间暂停" : "尚未启用"
        }
        recordingStatus = captureStatus
    }

    private var captureStatus: String {
        if !enabled { return "尚未启用" }
        if suspended { return "休眠或会话未激活期间暂停" }
        if paused { return "记录已暂停" }
        if IsSecureEventInputEnabled() { return "安全键盘输入期间暂停记录" }
        if #available(macOS 15.4, *) {
            switch pasteboard.accessBehavior {
            case .alwaysAllow: break
            case .alwaysDeny: return "剪贴板访问被拒绝，请在系统设置中允许"
            default: return "等待剪贴板读取授权，请点击下方按钮并设为始终允许"
            }
        }
        return "正在记录新复制的文本"
    }

    private func start() {
        lastChangeCount = pasteboard.changeCount
        if timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let icon = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "右键助手")
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            item.button?.image = icon
            item.button?.toolTip = "右键助手 · 文本历史"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        refreshPermissions()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        shortcut.stop()
        pasteGeneration = UUID()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func suspend(_ notification: Notification) {
        if notification.name == NSWorkspace.willSleepNotification { sleeping = true }
        else { sessionInactive = true }
        shortcut.stop()
        pasteGeneration = UUID()
        lastChangeCount = pasteboard.changeCount
        hidePanel()
        refreshPermissions()
    }

    @objc private func resume(_ notification: Notification) {
        if notification.name == NSWorkspace.didWakeNotification { sleeping = false }
        else { sessionInactive = false }
        lastChangeCount = pasteboard.changeCount
        refreshPermissions()
    }

    private func poll() {
        let status = captureStatus
        if recordingStatus != status { recordingStatus = status }
        guard enabled, !paused, !suspended, !IsSecureEventInputEnabled() else {
            lastChangeCount = pasteboard.changeCount
            return
        }
        if #available(macOS 15.4, *), pasteboard.accessBehavior != .alwaysAllow {
            lastChangeCount = pasteboard.changeCount
            return
        }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard ClipboardHistory.mayCapture(types: (pasteboard.types ?? []).map(\.rawValue)),
              let text = pasteboard.string(forType: .string), pasteboard.changeCount == count else { return }
        _ = history.insert(text)
    }

    func clearHistory() {
        history.clear(); selectedID = nil
        lastChangeCount = pasteboard.changeCount
        pasteGeneration = UUID()
        message = "历史已清空；系统剪贴板保留。"
    }
    func remove(_ id: UUID) { history.remove(id); if selectedID == id { selectedID = nil } }

    @objc func togglePanel() {
        if panel?.isVisible == true && !isHidingPanel { hidePanel(); return }
        guard !history.items.isEmpty else {
            message = enabled ? "还没有文本历史，请先复制一些文字。" : "请先启用文本历史。"
            return
        }
        showPanel(style: .compact)
    }

    func showHistoryManager() {
        dismissPanel(animated: false)
        showPanel(style: .manager)
    }

    private func showPanel(style: PanelStyle) {
        guard !suspended else { return }
        sourceApplication = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0
        }
        pasteGeneration = UUID()
        presentationGeneration = UUID()
        isHidingPanel = false
        panelStyle = style
        query = ""; selectedID = history.items.first?.id
        if panel == nil { makePanel() }
        guard let panel else { return }
        // Keep nonactivatingPanel from construction through both presentations.
        // A shortcut must not activate the app and raise its settings window.
        panel.styleMask = style == .compact
            ? [.borderless, .nonactivatingPanel]
            : [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        panel.isOpaque = style != .compact
        panel.backgroundColor = style == .compact ? .clear : .windowBackgroundColor
        panel.hasShadow = style != .compact
        if style == .compact {
            panel.contentView = NSHostingView(rootView: CompactClipboardHistoryPane(controller: self))
        } else {
            panel.contentView = NSHostingView(rootView: ClipboardHistoryPane(controller: self))
            panel.setContentSize(NSSize(width: 440, height: 460))
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let finalFrame: NSRect
        if style == .compact {
            finalFrame = ClipboardPanelLayout.frame(at: mouse, visibleFrame: frame, count: history.items.count)
        } else {
            let x = min(max(mouse.x - 24, frame.minX), max(frame.minX, frame.maxX - panel.frame.width))
            let y = min(max(mouse.y - panel.frame.height - 12, frame.minY), max(frame.minY, frame.maxY - panel.frame.height))
            finalFrame = NSRect(origin: NSPoint(x: x, y: y), size: panel.frame.size)
        }
        let animated = style == .compact && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animated ? 0 : 1
        panel.setFrame(animated ? finalFrame.offsetBy(dx: 0, dy: -20) : finalFrame, display: false)
        panel.makeKeyAndOrderFront(nil)
        if style == .manager { NSApp.activate(ignoringOtherApps: true) }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(finalFrame, display: true)
            }
        }
    }

    func hidePanel() { dismissPanel(animated: panelStyle == .compact) }

    private func dismissPanel(animated: Bool) {
        sourceApplication = nil
        guard let panel, panel.isVisible, !isHidingPanel else { return }
        isHidingPanel = true
        let generation = UUID()
        presentationGeneration = generation
        let finish: @MainActor @Sendable () -> Void = { [weak self, weak panel] in
            guard let self, self.presentationGeneration == generation else { return }
            panel?.orderOut(nil)
            panel?.alphaValue = 1
            self.isHidingPanel = false
        }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
                panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -20), display: true)
            }, completionHandler: { Task { @MainActor in finish() } })
        } else { finish() }
    }

    func resizeCompactPanel() {
        guard panelStyle == .compact, let panel, panel.isVisible, !isHidingPanel else { return }
        guard !history.items.isEmpty else { hidePanel(); return }
        let screen = panel.screen?.visibleFrame ?? panel.frame
        var frame = panel.frame
        let height = min(ClipboardPanelLayout.height(for: history.items.count), screen.height)
        frame.origin.y = max(screen.minY, frame.maxY - height)
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hidePanel(); return false }
    func windowDidResignKey(_ notification: Notification) { hidePanel() }

    private func makePanel() {
        let newPanel = ClipboardFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        newPanel.title = "文本历史 · 右键助手"
        newPanel.identifier = NSUserInterfaceItemIdentifier("clipboardHistory")
        newPanel.level = .floating
        newPanel.isReleasedWhenClosed = false
        newPanel.hidesOnDeactivate = false
        newPanel.delegate = self
        panel = newPanel
        panelKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 { self.hidePanel(); return nil }
            if event.keyCode == 36 || event.keyCode == 76 {
                if let item = self.filteredItems.first(where: { $0.id == self.selectedID }) ?? self.filteredItems.first { self.choose(item) }
                return nil
            }
            return event
        }
    }

    func choose(_ item: ClipboardHistoryItem) {
        guard history.items.contains(where: { $0.id == item.id }), !suspended else { return }
        let target = sourceApplication
        let generation = UUID()
        pasteGeneration = generation
        pasteboard.clearContents()
        guard pasteboard.setString(item.text, forType: .string) else { message = "复制失败，请重试。"; return }
        lastChangeCount = pasteboard.changeCount
        let expectedCount = lastChangeCount
        history.insert(item.text)
        dismissPanel(animated: false)
        message = "已复制，可在目标应用按 ⌘V。"
        guard let target, !target.isTerminated else { return }
        let shouldPaste = autoPaste && AXIsProcessTrusted() && CGPreflightPostEventAccess()
        target.activate(options: [])
        guard shouldPaste else { return }
        waitAndPaste(to: target, expectedCount: expectedCount, generation: generation, attempts: 16)
    }

    private func waitAndPaste(to target: NSRunningApplication, expectedCount: Int, generation: UUID, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.pasteGeneration == generation, self.enabled, self.autoPaste,
                  !self.suspended, !IsSecureEventInputEnabled(), !target.isTerminated else { return }
            let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let ownPID = ProcessInfo.processInfo.processIdentifier
            // Never paste into a newly focused third app or overwrite a newer copy.
            guard (current == target.processIdentifier || current == ownPID),
                  self.pasteboard.changeCount == expectedCount else {
                self.message = "焦点或剪贴板已变化，已取消自动粘贴；可手动按 ⌘V。"; return
            }
            let blockedFlags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
            if PasteBackGuard.canSend(targetPID: target.processIdentifier, frontmostPID: current,
                targetIsAlive: !target.isTerminated, permission: AXIsProcessTrusted() && CGPreflightPostEventAccess(),
                expectedChangeCount: expectedCount, currentChangeCount: self.pasteboard.changeCount,
                modifiersAreReleased: NSEvent.modifierFlags.intersection(blockedFlags).isEmpty) {
                guard let source = CGEventSource(stateID: .privateState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
                down.flags = .maskCommand; up.flags = .maskCommand
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                self.message = "已向原应用发送粘贴快捷键。"
            } else if attempts > 1 {
                self.waitAndPaste(to: target, expectedCount: expectedCount, generation: generation, attempts: attempts - 1)
            } else { self.message = "原应用尚未就绪或权限不可用，已复制，可手动按 ⌘V。" }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (title, action) in [("打开文本历史", #selector(togglePanel)),
                                (paused ? "恢复记录" : "暂停记录", #selector(togglePaused)),
                                ("清空历史", #selector(clearFromMenu)),
                                ("剪贴板设置…", #selector(openSettings))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出右键助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    @objc private func togglePaused() { setPaused(!paused) }
    @objc private func clearFromMenu() { clearHistory() }
    @objc private func openSettings() { AppState.shared.selectedTab = .clipboard; AppState.shared.showWindow() }
}

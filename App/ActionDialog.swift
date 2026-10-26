import AppKit

/// A modeless, independently owned dialog. Keeping a request active in RequestInbox
/// serializes operations without a settings-window sheet or a nested modal loop.
@MainActor
final class ActionDialog: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        var onCancel: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }

    private let panel: Panel
    private var completion: ((NSApplication.ModalResponse) -> Void)?

    init(alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        self.completion = completion
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
                      styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "右键助手"
        panel.identifier = NSUserInterfaceItemIdentifier("action-dialog")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.finish(.cancel) }

        let title = NSTextField(wrappingLabelWithString: alert.messageText)
        title.font = .boldSystemFont(ofSize: 16)
        let detail = NSTextField(wrappingLabelWithString: alert.informativeText)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.isSelectable = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(detail)
        if let accessory = alert.accessoryView { stack.addArrangedSubview(accessory) }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.addArrangedSubview(NSView())
        for (index, original) in alert.buttons.enumerated().reversed() {
            let button = NSButton(title: original.title, target: self, action: #selector(choose(_:)))
            button.bezelStyle = .rounded
            button.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index
            button.keyEquivalent = index == 0 ? "\r" : "\u{1b}"
            button.keyEquivalentModifierMask = []
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            buttons.addArrangedSubview(button)
            if index == 0 { panel.defaultButtonCell = button.cell as? NSButtonCell }
        }
        stack.addArrangedSubview(buttons)
        for view in stack.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
            ])
        }
        panel.setContentSize(NSSize(width: 460, height: stack.fittingSize.height + 40))
        panel.initialFirstResponder = alert.accessoryView
        panel.center()
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        if let field = panel.initialFirstResponder as? NSTextField { field.selectText(nil) }
    }

    @objc private func choose(_ sender: NSButton) {
        finish(NSApplication.ModalResponse(rawValue: sender.tag))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.cancel)
        return false
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard let callback = completion else { return }
        completion = nil
        panel.orderOut(nil)
        // Leave the button/window callback before releasing this dialog or opening another.
        DispatchQueue.main.async { callback(response) }
    }
}

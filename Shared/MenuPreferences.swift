import Foundation

enum MenuAction: String, Codable, CaseIterable, Identifiable {
    case create, copyPath, copyName, copyShell, terminal, applications
    var id: String { rawValue }
    var title: String {
        switch self {
        case .create: return "新建文件"
        case .copyPath: return "复制完整路径"
        case .copyName: return "复制文件名"
        case .copyShell: return "复制终端转义路径"
        case .terminal: return "在此打开 Git 终端"
        case .applications: return "用常用应用打开"
        }
    }
    var symbol: String {
        switch self {
        case .create: return "doc.badge.plus"
        case .copyPath: return "link"
        case .copyName: return "doc.on.doc"
        case .copyShell: return "text.badge.checkmark"
        case .terminal: return "terminal"
        case .applications: return "square.grid.2x2"
        }
    }
}

struct MenuPreferences: Codable, Equatable {
    var order: [MenuAction] = MenuAction.allCases
    var disabled: [MenuAction] = []
    var templates: [FileTemplate] = FileTemplate.allCases
    var defaultApplicationID: UUID?

    func isEnabled(_ action: MenuAction) -> Bool { !disabled.contains(action) }

    mutating func setEnabled(_ action: MenuAction, _ enabled: Bool) {
        disabled.removeAll { $0 == action }
        if !enabled { disabled.append(action) }
    }

    mutating func move(_ action: MenuAction, offset: Int) {
        guard abs(offset) == 1, let index = order.firstIndex(of: action),
              order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
    }

    func validate() throws {
        guard order.count == MenuAction.allCases.count, Set(order) == Set(MenuAction.allCases),
              Set(disabled).count == disabled.count,
              Set(templates).count == templates.count else {
            throw PrototypeError.message("菜单配置重复或缺失，请恢复默认菜单。")
        }
    }

    func visibleActions(canCreate: Bool, canOpen: Bool, hasApplications: Bool) -> [MenuAction] {
        order.filter { action in
            guard isEnabled(action) else { return false }
            switch action {
            case .create: return canCreate && !templates.isEmpty
            case .terminal: return canOpen
            case .applications: return canOpen && hasApplications
            default: return true
            }
        }
    }

    func eligibleApplications(_ applications: [FavoriteApplication], forDirectory: Bool) -> [FavoriteApplication] {
        let available = applications.filter { !forDirectory || $0.supportsDirectories }
        // Stable ordering: only bring the selected default to the front.
        return available.filter { $0.id == defaultApplicationID } + available.filter { $0.id != defaultApplicationID }
    }
}

enum ServiceAction: String, CaseIterable { case copyPath, create, terminal, applications }

enum ServiceSelection {
    static func validate(_ urls: [URL], action: ServiceAction) throws {
        guard !urls.isEmpty, urls.count <= 1000,
              urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") &&
                  $0.path.hasPrefix("/") && !$0.path.contains("\0") && $0.path.utf8.count <= 8192 }) else {
            throw PrototypeError.message("服务需要 1–1000 个本地文件或文件夹；不接受网页或文本路径。")
        }
        if action != .copyPath {
            guard urls.count == 1 else { throw PrototypeError.message("此服务一次只能处理一个文件或文件夹。") }
            if action == .create { try ActionContext.validateOrdinaryDirectory(urls[0], within: urls[0]) }
            else { _ = try ActionContext.terminalDirectory(for: urls) }
        }
    }
}

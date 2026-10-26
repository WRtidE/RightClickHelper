import Foundation

enum PrototypeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

enum FileTemplate: String, Codable, CaseIterable {
    case docx, pptx, xlsx, txt, md, json
    var title: String {
        switch self {
        case .docx: return "Word 文档 (.docx)"
        case .pptx: return "PowerPoint 演示文稿 (.pptx)"
        case .xlsx: return "Excel 工作簿 (.xlsx)"
        case .txt: return "文本文件 (.txt)"
        case .md: return "Markdown (.md)"
        case .json: return "JSON (.json)"
        }
    }

    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    func loadContent(bundle: Bundle = FileTemplate.resourceBundle) throws -> Data {
        switch self {
        case .txt, .md: return Data()
        case .json: return Data("{}\n".utf8)
        case .docx, .pptx, .xlsx:
            guard let url = bundle.url(forResource: "blank", withExtension: rawValue),
                  let data = try? Data(contentsOf: url),
                  data.count > 4, data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
                throw PrototypeError.message("\(title)的内置模板缺失或损坏，请重新安装应用。")
            }
            return data
        }
    }
}

struct ManagedDirectory: Codable, Identifiable, Equatable {
    var id: UUID
    var path: String
}

struct FavoriteApplication: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleIdentifier: String
    var name: String
    var supportsDirectories = false
}

struct SharedConfiguration: Codable {
    var version = 4
    var directories: [ManagedDirectory] = []
    var applications: [FavoriteApplication] = []
    // Menu visibility is not a sandbox grant. Only the companion app holds bookmarks.
    var showsMenuEverywhere = true
    var menu = MenuPreferences()

    init(directories: [ManagedDirectory] = [], applications: [FavoriteApplication] = [], showsMenuEverywhere: Bool = true,
         menu: MenuPreferences = MenuPreferences()) {
        self.directories = directories
        self.applications = applications
        self.showsMenuEverywhere = showsMenuEverywhere
        self.menu = menu
    }
    private enum CodingKeys: String, CodingKey { case version, directories, applications, showsMenuEverywhere, menu }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        directories = try c.decode([ManagedDirectory].self, forKey: .directories)
        applications = try c.decodeIfPresent([FavoriteApplication].self, forKey: .applications) ?? []
        showsMenuEverywhere = try c.decodeIfPresent(Bool.self, forKey: .showsMenuEverywhere) ?? true
        menu = try c.decodeIfPresent(MenuPreferences.self, forKey: .menu) ?? MenuPreferences()
    }

    func validate() throws {
        try menu.validate()
        guard [1, 2, 3, 4].contains(version), directories.count <= 100, applications.count <= 5,
              menu.defaultApplicationID == nil || applications.contains(where: { $0.id == menu.defaultApplicationID }),
              Set(applications.map(\.id)).count == applications.count,
              Set(applications.map(\.bundleIdentifier)).count == applications.count,
              applications.allSatisfy({ !$0.name.isEmpty && !$0.bundleIdentifier.isEmpty }) else {
            throw PrototypeError.message("配置版本、目录或常用应用数量无效。")
        }
    }

    var menuDirectoryURLs: Set<URL> {
        var roots = Set(directories.map { URL(fileURLWithPath: $0.path, isDirectory: true) })
        if showsMenuEverywhere { roots.insert(URL(fileURLWithPath: "/", isDirectory: true)) }
        return roots
    }
}

enum ActionKind: String, Codable { case create, openTerminal, openApplication }
enum ActionOrigin: String, Codable { case finder, service, app }

struct ActionRequest: Codable {
    var version = 2
    var id = UUID()
    var createdAt = Date()
    var directoryPath: String
    var template: FileTemplate?
    var action: ActionKind = .create
    var applicationID: UUID?
    var itemPath: String?
    var origin: ActionOrigin = .finder

    init(directoryPath: String, template: FileTemplate? = nil, action: ActionKind = .create,
         applicationID: UUID? = nil, itemPath: String? = nil, origin: ActionOrigin = .finder) {
        self.directoryPath = directoryPath
        self.template = template
        self.action = action
        self.applicationID = applicationID
        self.itemPath = itemPath
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey { case version, id, createdAt, directoryPath, template, action, applicationID, itemPath, origin }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        directoryPath = try c.decode(String.self, forKey: .directoryPath)
        template = try c.decodeIfPresent(FileTemplate.self, forKey: .template)
        action = try c.decodeIfPresent(ActionKind.self, forKey: .action) ?? .create
        applicationID = try c.decodeIfPresent(UUID.self, forKey: .applicationID)
        itemPath = try c.decodeIfPresent(String.self, forKey: .itemPath)
        origin = try c.decodeIfPresent(ActionOrigin.self, forKey: .origin) ?? .finder
    }

    func validate(now: Date = Date()) throws {
        guard [1, 2].contains(version), directoryPath.hasPrefix("/"), !directoryPath.contains("\0"),
              directoryPath.utf8.count <= 8192,
              now.timeIntervalSince(createdAt) >= -30,
              now.timeIntervalSince(createdAt) <= 300 else {
            throw PrototypeError.message("请求无效或已过期，请重新从 Finder 操作。")
        }
        guard version != 1 || action == .create else { throw PrototypeError.message("旧请求不支持此动作。") }
        switch action {
        case .create:
            guard template != nil, applicationID == nil, itemPath == nil else { throw PrototypeError.message("创建请求参数无效。") }
        case .openTerminal:
            guard template == nil, applicationID == nil, itemPath == nil else { throw PrototypeError.message("终端请求参数无效。") }
        case .openApplication:
            guard template == nil, applicationID != nil, let itemPath,
                  itemPath.hasPrefix("/"), !itemPath.contains("\0"), itemPath.utf8.count <= 8192 else {
                throw PrototypeError.message("应用请求参数无效。")
            }
        }
    }
}

// Preserve source compatibility with the original create-only tests and probes.
typealias CreateRequest = ActionRequest

struct DiagnosticEvent: Codable {
    var time = Date()
    var message: String
}

struct CreationJournal: Codable {
    enum Stage: String, Codable { case planned, written }
    var stage: Stage
    var outputPath: String
    var updatedAt = Date()
}

struct InterruptedRequest: Identifiable {
    var id: UUID
    var request: CreateRequest?
    var journal: CreationJournal?
}

enum PathText {
    static func absolute(_ urls: [URL]) -> String { urls.map(\.path).joined(separator: "\n") }
    static func names(_ urls: [URL]) -> String { urls.map(\.lastPathComponent).joined(separator: "\n") }
    static func shell(_ urls: [URL]) -> String {
        urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }
}

enum DirectoryBoundary {
    static func relativeComponents(of target: URL, within root: URL) throws -> [String] {
        guard target.isFileURL, root.isFileURL else {
            throw PrototypeError.message("仅支持本地文件目录。")
        }
        let base = root.standardizedFileURL.pathComponents
        let destination = target.standardizedFileURL.pathComponents
        guard destination.starts(with: base) else {
            throw PrototypeError.message("目标不在已授权的目录内，请先添加该目录。")
        }
        return Array(destination.dropFirst(base.count))
    }
}

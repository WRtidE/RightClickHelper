import Foundation

final class SharedStore {
    static let configurationChanged = "dev.rightclickhelper.prototype.configurationChanged"
    let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fm = FileManager.default

    convenience init() throws {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "SharedGroupIdentifier") as? String,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw PrototypeError.message("共享容器不可用，请检查主应用与扩展的签名和 App Groups。")
        }
        try self.init(root: root)
    }

    init(root: URL) throws {
        self.root = root
        for name in ["", "Pending", "Processing", "Finished", "Journal"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    func configuration() throws -> SharedConfiguration {
        let url = root.appendingPathComponent("configuration.json")
        guard fm.fileExists(atPath: url.path) else { return SharedConfiguration() }
        let config = try decoder.decode(SharedConfiguration.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    func saveConfiguration(_ configuration: SharedConfiguration) throws {
        try configuration.validate()
        try encoder.encode(configuration).write(to: root.appendingPathComponent("configuration.json"), options: .atomic)
    }

    /// Only the app calls this after a read/validation failure. Preserve the
    /// exact damaged snapshot before replacing menu preferences with defaults.
    func backUpInvalidConfiguration() throws -> URL {
        let original = root.appendingPathComponent("configuration.json")
        let backup = root.appendingPathComponent("configuration-recovery-\(UUID().uuidString).json")
        try fm.copyItem(at: original, to: backup)
        return backup
    }

    func submit(_ request: CreateRequest) throws {
        try request.validate()
        guard !fm.fileExists(atPath: requestURL(request.id, area: "Finished").path),
              !fm.fileExists(atPath: requestURL(request.id, area: "Processing").path) else {
            throw PrototypeError.message("该请求已经处理过，请重新操作。")
        }
        guard try files(in: "Pending").count < 100 else {
            throw PrototypeError.message("待处理请求过多，请先打开右键助手。")
        }
        guard try files(in: "Processing").count < 100 else {
            throw PrototypeError.message("中断记录过多，请先在主应用检查并确认历史请求。")
        }
        let staged = root.appendingPathComponent("Pending").appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? fm.removeItem(at: staged) }
        try encoder.encode(request).write(to: staged, options: .withoutOverwriting)
        try fm.moveItem(at: staged, to: requestURL(request.id, area: "Pending"))
        RequestTrace.event("request-submitted", id: request.id)
    }

    func claim(_ id: UUID) throws -> CreateRequest? {
        guard !fm.fileExists(atPath: requestURL(id, area: "Finished").path),
              !fm.fileExists(atPath: requestURL(id, area: "Processing").path) else { return nil }
        let pending = requestURL(id, area: "Pending")
        guard fm.fileExists(atPath: pending.path) else { return nil }
        // Rename is the claim; a processed ID is never replayed automatically.
        let processing = requestURL(id, area: "Processing")
        try fm.moveItem(at: pending, to: processing)
        do {
            let size = try processing.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16_384 else { throw PrototypeError.message("请求内容过大。") }
            let request = try decoder.decode(CreateRequest.self, from: Data(contentsOf: processing))
            guard request.id == id else { throw PrototypeError.message("请求标识不匹配。") }
            try request.validate()
            return request
        } catch {
            // Invalid/expired requests never ran. Make them terminal instead of
            // leaving false "interrupted" warnings or replaying them on relaunch.
            try finish(id, message: "请求已拒绝（无文件操作）")
            throw error
        }
    }

    func pendingIDs() throws -> [UUID] {
        try files(in: "Pending").sorted {
            let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
        }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    }

    func finish(_ id: UUID, message: String) throws {
        try encoder.encode(DiagnosticEvent(message: message)).write(to: requestURL(id, area: "Finished"), options: .atomic)
        let processing = requestURL(id, area: "Processing")
        if fm.fileExists(atPath: processing.path) { try fm.removeItem(at: processing) }
        let journal = requestURL(id, area: "Journal")
        if fm.fileExists(atPath: journal.path) { try fm.removeItem(at: journal) }
        RequestTrace.event("request-finished", id: id)
    }

    func interruptedCount() throws -> Int { try files(in: "Processing").count }

    func journal(_ id: UUID, output: URL, stage: CreationJournal.Stage) throws {
        guard fm.fileExists(atPath: requestURL(id, area: "Processing").path) else {
            throw PrototypeError.message("请求未领取，无法记录创建计划。")
        }
        try encoder.encode(CreationJournal(stage: stage, outputPath: output.path))
            .write(to: requestURL(id, area: "Journal"), options: .atomic)
    }

    func interruptedRequests(excluding activeID: UUID? = nil) throws -> [InterruptedRequest] {
        try files(in: "Processing").compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), id != activeID else { return nil }
            return InterruptedRequest(id: id,
                request: (try? Data(contentsOf: url)).flatMap { try? decoder.decode(CreateRequest.self, from: $0) },
                journal: (try? Data(contentsOf: requestURL(id, area: "Journal"))).flatMap { try? decoder.decode(CreationJournal.self, from: $0) })
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Keep all recent deduplication markers beyond the five-minute request TTL.
    /// Unresolved requests are NEVER pruned or retried. Only the UI acknowledges them.
    @discardableResult
    func pruneHistory(now: Date = Date()) throws -> Int {
        var removed = 0
        let completed = try files(in: "Finished").sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture)
        }
        for (index, url) in completed.enumerated() {
            guard let event = try? decoder.decode(DiagnosticEvent.self, from: Data(contentsOf: url)),
                  now.timeIntervalSince(event.time) > 600,
                  index >= 500 || now.timeIntervalSince(event.time) > 7 * 86400 else { continue }
            // An interrupted finish may have written Finished before removing Processing.
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            for area in ["Processing", "Journal"] {
                let residual = requestURL(id, area: area)
                if fm.fileExists(atPath: residual.path) { try fm.removeItem(at: residual) }
            }
            try fm.removeItem(at: url)
            removed += 1
        }
        for url in try fm.contentsOfDirectory(at: root.appendingPathComponent("Pending"), includingPropertiesForKeys: [.contentModificationDateKey]) where url.pathExtension == "tmp" {
            if let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(date) > 3600 { try fm.removeItem(at: url); removed += 1 }
        }
        return removed
    }

    func record(_ key: String, message: String) {
        try? encoder.encode(DiagnosticEvent(message: message)).write(to: root.appendingPathComponent(key + ".json"), options: .atomic)
    }

    func event(_ key: String) -> DiagnosticEvent? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(key + ".json")) else { return nil }
        return try? decoder.decode(DiagnosticEvent.self, from: data)
    }

    private func files(in area: String) throws -> [URL] {
        try fm.contentsOfDirectory(at: root.appendingPathComponent(area), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func requestURL(_ id: UUID, area: String) -> URL {
        root.appendingPathComponent(area).appendingPathComponent(id.uuidString + ".json")
    }
}

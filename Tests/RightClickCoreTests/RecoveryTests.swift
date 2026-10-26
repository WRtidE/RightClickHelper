import XCTest
@testable import RightClickCore

final class RecoveryTests: XCTestCase {
    func testPersistedPlanAndWrittenResultAreNeverReplayed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedStore(root: root)
        let output = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let request = CreateRequest(directoryPath: output.path, template: .json)
        try store.submit(request)
        _ = try store.claim(request.id)
        let file = try FileCreator.create(in: output, authorizedRoot: output, name: "恢复", template: .json) {
            try store.journal(request.id, output: $0, stage: .planned)
        }
        let restarted = try SharedStore(root: root)
        XCTAssertNil(try restarted.claim(request.id))
        XCTAssertThrowsError(try restarted.submit(request))
        XCTAssertEqual(try restarted.interruptedRequests().first?.journal?.outputPath, file.path)
        XCTAssertEqual(try restarted.interruptedRequests().first?.journal?.stage, .planned)
        try restarted.journal(request.id, output: file, stage: .written)
        XCTAssertEqual(try restarted.interruptedRequests().first?.journal?.stage, .written)
        try restarted.finish(request.id, message: "用户确认")
        XCTAssertTrue(try restarted.interruptedRequests().isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("{}\n".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 1)
    }

    func testJournalFailurePreventsCreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try FileCreator.create(in: root, authorizedRoot: root, name: "test", template: .txt) { _ in
            throw PrototypeError.message("模拟日志写入失败")
        })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testRetentionKeepsRecentDeduplicationAndUnresolvedRequests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedStore(root: root)
        let request = CreateRequest(directoryPath: root.path, template: .txt)
        try store.submit(request); _ = try store.claim(request.id)
        let oldID = UUID(), recentID = UUID()
        for (id, date) in [(oldID, Date(timeIntervalSinceNow: -8 * 86400)), (recentID, Date())] {
            try JSONEncoder().encode(DiagnosticEvent(time: date, message: "完成"))
                .write(to: root.appendingPathComponent("Finished/\(id).json"))
        }
        XCTAssertEqual(try store.pruneHistory(), 1)
        XCTAssertEqual(try store.interruptedRequests().map(\.id), [request.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Finished/\(recentID).json").path))
        XCTAssertNil(try store.claim(request.id))
        var expired = request
        expired.createdAt = Date(timeIntervalSinceNow: -8 * 86400)
        expired.id = oldID
        XCTAssertThrowsError(try store.submit(expired))
    }
}

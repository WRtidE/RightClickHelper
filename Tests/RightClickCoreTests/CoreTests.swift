import XCTest
@testable import RightClickCore

final class CoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testCreatesValidJSONAndNeverOverwrites() throws {
        let first = try FileCreator.create(in: directory, authorizedRoot: directory, name: "中文 项目 🐱", template: .json)
        let second = try FileCreator.create(in: directory, authorizedRoot: directory, name: "中文 项目 🐱", template: .json)
        XCTAssertEqual(first.lastPathComponent, "中文 项目 🐱.json")
        XCTAssertEqual(second.lastPathComponent, "中文 项目 🐱 2.json")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any])
        XCTAssertEqual(try Data(contentsOf: first), Data("{}\n".utf8))
    }

    func testOfficeFilesUseBundledContentAndDoNotOverwrite() throws {
        for template in [FileTemplate.docx, .pptx, .xlsx] {
            let content = try template.loadContent()
            XCTAssertGreaterThan(content.count, 1_000)
            XCTAssertTrue(content.starts(with: [0x50, 0x4b, 0x03, 0x04]))
            let first = try FileCreator.create(in: directory, authorizedRoot: directory,
                                               name: "中文 项目 🐱." + template.rawValue.uppercased(), template: template)
            let second = try FileCreator.create(in: directory, authorizedRoot: directory,
                                                name: "中文 项目 🐱", template: template)
            XCTAssertEqual(first.lastPathComponent, "中文 项目 🐱." + template.rawValue)
            XCTAssertEqual(second.lastPathComponent, "中文 项目 🐱 2." + template.rawValue)
            XCTAssertEqual(try Data(contentsOf: first), content)
            XCTAssertEqual(try Data(contentsOf: second), content)
        }
    }

    func testMissingOfficeTemplateThrowsInsteadOfReturningEmptyData() {
        for template in [FileTemplate.docx, .pptx, .xlsx] {
            XCTAssertThrowsError(try template.loadContent(bundle: Bundle(for: NSObject.self)))
        }
    }

    func testAllTemplatesSurviveFinderRequestSerialization() throws {
        for template in FileTemplate.allCases {
            let request = CreateRequest(directoryPath: "/tmp/工作目录", template: template)
            let data = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(CreateRequest.self, from: data)
            XCTAssertEqual(decoded.template, template)
            XCTAssertEqual(decoded.id, request.id)
            try decoded.validate()
        }
    }

    func testRejectsTraversalAndInvalidNames() {
        for name in ["", " ", ".", "..", "../bad", "a/b", "a:b", "a\0b"] {
            XCTAssertThrowsError(try FileCreator.create(in: directory, authorizedRoot: directory, name: name, template: .txt))
        }
        XCTAssertThrowsError(try DirectoryBoundary.relativeComponents(of: URL(fileURLWithPath: directory.path + "-sibling"), within: directory))
    }

    func testRejectsSymlinkDirectoryEscape() throws {
        let outside = directory.appendingPathComponent("outside")
        let root = directory.appendingPathComponent("authorized")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try FileCreator.create(in: link, authorizedRoot: root, name: "escape", template: .txt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.txt").path))
    }

    func testReadOnlyDirectoryLeavesNoFile() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try FileCreator.create(in: directory, authorizedRoot: directory, name: "denied", template: .txt))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testConcurrentSameNameCreatesDistinctFiles() throws {
        let lock = NSLock()
        var paths: [URL] = []
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do {
                let result = try FileCreator.create(in: directory, authorizedRoot: directory, name: "same", template: .txt)
                lock.lock(); paths.append(result); lock.unlock()
            } catch { lock.lock(); errors.append(error); lock.unlock() }
        }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(Set(paths).count, 20)
    }

    func testShellPathsRoundTripWithoutExecution() throws {
        let paths = ["/tmp/a b", "/tmp/it's $HOME; `danger`", "/tmp/line\nbreak"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\0' " + PathText.shell(paths.map { URL(fileURLWithPath: $0) })]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(result, Data((paths.joined(separator: "\0") + "\0").utf8))
    }

    func testRequestCannotBeClaimedTwiceOrReplayedAfterFinish() throws {
        let store = try SharedStore(root: directory)
        let request = CreateRequest(directoryPath: "/tmp/work", template: .txt)
        try store.submit(request)
        XCTAssertEqual(try store.claim(request.id)?.id, request.id)
        XCTAssertNil(try store.claim(request.id))
        XCTAssertEqual(try store.interruptedCount(), 1)
        try store.finish(request.id, message: "success")
        XCTAssertEqual(try store.interruptedCount(), 0)
        XCTAssertThrowsError(try store.submit(request))
    }

    func testExpiredAndMalformedRequestsAreRejected() throws {
        var request = CreateRequest(directoryPath: "/tmp/work", template: .txt)
        request.createdAt = Date(timeIntervalSinceNow: -301)
        XCTAssertThrowsError(try request.validate())
        request.createdAt = Date()
        request.directoryPath = "relative"
        XCTAssertThrowsError(try request.validate())
        request.directoryPath = "/tmp/work"
        request.version = 999
        XCTAssertThrowsError(try request.validate())
    }
}

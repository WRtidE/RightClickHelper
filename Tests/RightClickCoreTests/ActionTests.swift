import XCTest
@testable import RightClickCore

final class ActionTests: XCTestCase {
    func testMenuCoverageDoesNotCreateDirectoryGrantsAndCanBeRestricted() throws {
        for version in [1, 2] {
            let legacy = Data("{\"version\":\(version),\"directories\":[]}".utf8)
            let migrated = try JSONDecoder().decode(SharedConfiguration.self, from: legacy)
            try migrated.validate()
            XCTAssertTrue(migrated.showsMenuEverywhere)
            XCTAssertTrue(migrated.directories.isEmpty)
            XCTAssertEqual(migrated.menuDirectoryURLs, [URL(fileURLWithPath: "/", isDirectory: true)])
        }
        let grant = ManagedDirectory(id: UUID(), path: "/tmp/work")
        var restricted = SharedConfiguration(directories: [grant], showsMenuEverywhere: false)
        try restricted.validate()
        let decoded = try JSONDecoder().decode(SharedConfiguration.self, from: JSONEncoder().encode(restricted))
        XCTAssertFalse(decoded.showsMenuEverywhere)
        XCTAssertEqual(decoded.menuDirectoryURLs, [URL(fileURLWithPath: grant.path, isDirectory: true)])
        restricted.directories = []
        XCTAssertTrue(restricted.menuDirectoryURLs.isEmpty)
    }

    func testContextualAuthorizationMustMatchCapturedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("中文 空格")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try ActionContext.validateAuthorizationSelection(target, for: target)
        for wrong in [root, other, URL(fileURLWithPath: "/")] {
            XCTAssertThrowsError(try ActionContext.validateAuthorizationSelection(wrong, for: target))
        }
        XCTAssertThrowsError(try ActionContext.validateAuthorizationSelection(URL(fileURLWithPath: "/"), for: URL(fileURLWithPath: "/")))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ActionContext.validateAuthorizationSelection(link, for: link))
    }

    func testTerminalContextAndSpecialNamesAreOnlyURLs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["中文 空格", "it's $HOME; `danger`", "line\nbreak"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("a.txt")
            try Data().write(to: file)
            XCTAssertEqual(try ActionContext.terminalDirectory(for: [directory]), directory)
            XCTAssertEqual(try ActionContext.terminalDirectory(for: [file]).path, directory.path)
            try ActionContext.validateOrdinaryDirectory(directory, within: root)
            let request = ActionRequest(directoryPath: directory.path, action: .openTerminal)
            let decoded = try JSONDecoder().decode(ActionRequest.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(decoded.directoryPath, directory.path)
            try decoded.validate()
        }
        XCTAssertThrowsError(try ActionContext.terminalDirectory(for: []))
        XCTAssertThrowsError(try ActionContext.terminalDirectory(for: [root, root]))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try ActionContext.terminalDirectory(for: [link]))
        XCTAssertThrowsError(try ActionContext.validateOrdinaryDirectory(link, within: root))
    }

    func testVersionOneCreateRequestsMigrateButCannotRequestOtherActions() throws {
        let original = CreateRequest(directoryPath: "/tmp/work", template: .docx)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["version"] = 1
        object.removeValue(forKey: "action")
        let migrated = try JSONDecoder().decode(ActionRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.action, .create)
        try migrated.validate()
        var invalid = ActionRequest(directoryPath: "/tmp", action: .openTerminal)
        invalid.version = 1
        XCTAssertThrowsError(try invalid.validate())
        invalid.version = 2
        invalid.itemPath = "/bin/sh"
        XCTAssertThrowsError(try invalid.validate())
    }

    func testFavoriteConfigurationMigrationLimitsAndIdentifiers() throws {
        let legacy = Data("{\"version\":1,\"directories\":[]}".utf8)
        let migrated = try JSONDecoder().decode(SharedConfiguration.self, from: legacy)
        XCTAssertTrue(migrated.applications.isEmpty)
        try migrated.validate()
        let apps = (0..<5).map { FavoriteApplication(bundleIdentifier: "dev.fixture.\($0)", name: "App \($0)") }
        var config = SharedConfiguration(applications: apps)
        try config.validate()
        let roundTrip = try JSONDecoder().decode(SharedConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(roundTrip.applications, apps)
        config.applications.append(FavoriteApplication(bundleIdentifier: "dev.fixture.six", name: "Six"))
        XCTAssertThrowsError(try config.validate())
        config.applications = [apps[0], apps[0]]
        XCTAssertThrowsError(try config.validate())
        config = SharedConfiguration(applications: apps)
        config.version = 99
        XCTAssertThrowsError(try config.validate())
        var request = ActionRequest(directoryPath: "/tmp", action: .openApplication, applicationID: apps[0].id, itemPath: "/tmp/readme.txt")
        try request.validate()
        request.itemPath = "https://example.com"
        XCTAssertThrowsError(try request.validate())
        request.itemPath = "/tmp/readme.txt"
        request.applicationID = nil
        XCTAssertThrowsError(try request.validate())
    }
}

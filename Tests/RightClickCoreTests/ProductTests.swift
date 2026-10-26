import AppKit
import XCTest
@testable import RightClickCore

final class ProductTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLegacyPreferencesMigrateAndCustomizedOrderSurvivesReload() throws {
        for version in [1, 2, 3] {
            let json = Data("{\"version\":\(version),\"directories\":[],\"showsMenuEverywhere\":false}".utf8)
            let config = try JSONDecoder().decode(SharedConfiguration.self, from: json)
            try config.validate()
            XCTAssertFalse(config.showsMenuEverywhere)
            XCTAssertEqual(config.menu, MenuPreferences())
        }
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedStore(root: root)
        var preferences = MenuPreferences()
        preferences.move(.copyPath, offset: -1)
        preferences.setEnabled(.terminal, false)
        preferences.templates = [.docx, .xlsx]
        let app = FavoriteApplication(bundleIdentifier: "test.editor", name: "Editor")
        preferences.defaultApplicationID = app.id
        try store.saveConfiguration(SharedConfiguration(applications: [app], showsMenuEverywhere: false, menu: preferences))
        let reloaded = try SharedStore(root: root).configuration()
        XCTAssertEqual(reloaded.version, 4)
        XCTAssertEqual(reloaded.menu, preferences)
        XCTAssertFalse(reloaded.showsMenuEverywhere)
        XCTAssertEqual(reloaded.menu.order.first, .copyPath)
    }

    func testMenuFilteringAllDisabledAndDefaultCompatibility() throws {
        var p = MenuPreferences()
        p.move(.copyPath, offset: -1)
        XCTAssertEqual(p.visibleActions(canCreate: false, canOpen: false, hasApplications: true), [.copyPath, .copyName, .copyShell])
        p.templates = []
        XCTAssertFalse(p.visibleActions(canCreate: true, canOpen: true, hasApplications: false).contains(.create))
        for action in MenuAction.allCases { p.setEnabled(action, false) }
        XCTAssertEqual(p.visibleActions(canCreate: true, canOpen: true, hasApplications: true), [])
        p.setEnabled(.copyName, true)
        p.setEnabled(.copyName, true)
        try p.validate()
        XCTAssertEqual(p.visibleActions(canCreate: false, canOpen: false, hasApplications: false), [.copyName])
        let text = FavoriteApplication(bundleIdentifier: "text", name: "Text")
        var editor = FavoriteApplication(bundleIdentifier: "editor", name: "Editor")
        editor.supportsDirectories = true
        p.defaultApplicationID = text.id
        XCTAssertEqual(p.eligibleApplications([editor, text], forDirectory: false), [text, editor])
        XCTAssertEqual(p.eligibleApplications([editor, text], forDirectory: true), [editor])
        p.order = [.copyName, .copyName]
        XCTAssertThrowsError(try p.validate())
    }

    func testBrokenConfigurationIsBackedUpWithoutLosingOtherFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedStore(root: root)
        let broken = Data("{broken JSON".utf8)
        try broken.write(to: root.appendingPathComponent("configuration.json"))
        let sentinel = Data("preserve request history".utf8)
        try sentinel.write(to: root.appendingPathComponent("unrelated.json"))
        XCTAssertThrowsError(try store.configuration())
        let backup = try store.backUpInvalidConfiguration()
        try store.saveConfiguration(SharedConfiguration())
        XCTAssertEqual(try Data(contentsOf: backup), broken)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("unrelated.json")), sentinel)
        XCTAssertEqual(try store.configuration().menu, MenuPreferences())
        var invalid = SharedConfiguration()
        invalid.menu.defaultApplicationID = UUID()
        XCTAssertThrowsError(try store.saveConfiguration(invalid))
    }

    func testGuideRequiresCurrentSessionAndCapturedFolder() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try SharedStore(root: root.appendingPathComponent("state"))
        let first = try store.startGuide(in: folder)
        store.recordGuideStep(.menu, targets: [root])
        XCTAssertFalse(store.guidePassed(.menu, session: first))
        store.recordGuideStep(.copy, targets: [folder, root])
        XCTAssertFalse(store.guidePassed(.copy, session: first))
        for step in GuideStep.allCases { store.recordGuideStep(step, targets: [folder.appendingPathComponent("file.txt")]) }
        XCTAssertTrue(GuideStep.allCases.allSatisfy { store.guidePassed($0, session: first) })
        let next = try store.startGuide(in: folder)
        XCTAssertNotEqual(first.id, next.id)
        XCTAssertTrue(GuideStep.allCases.allSatisfy { !store.guidePassed($0, session: next) })
        store.recordGuideStep(.create, targets: [folder])
        XCTAssertTrue(store.guidePassed(.create, session: next))
        XCTAssertFalse(store.guidePassed(.copy, session: next))
    }

    func testServicesRequireFilesAndEnforceSingleOrdinaryTargets() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("中文 空格's $.txt")
        try Data().write(to: file)
        try ServiceSelection.validate([root], action: .create)
        try ServiceSelection.validate([file], action: .terminal)
        try ServiceSelection.validate([file, root], action: .copyPath)
        XCTAssertThrowsError(try ServiceSelection.validate([file], action: .create))
        XCTAssertThrowsError(try ServiceSelection.validate([file, root], action: .applications))
        XCTAssertThrowsError(try ServiceSelection.validate([], action: .copyPath))
        XCTAssertThrowsError(try ServiceSelection.validate(Array(repeating: file, count: 1001), action: .copyPath))
        XCTAssertThrowsError(try ServiceSelection.validate([URL(string: "https://example.com")!], action: .copyPath))
        XCTAssertThrowsError(try ServiceSelection.validate([URL(string: "file://remote/tmp/file")!], action: .copyPath))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try ServiceSelection.validate([link], action: .create))
        XCTAssertThrowsError(try ServiceSelection.validate([link], action: .terminal))
    }

    func testServicePasteboardAcceptsFileURLsAndLegacyFilesButNotPlainText() throws {
        let p = NSPasteboard.withUniqueName()
        defer { p.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/tmp/中文 空格.txt"), URL(fileURLWithPath: "/tmp/it's $x.txt")]
        XCTAssertTrue(p.writeObjects(urls as [NSURL]))
        XCTAssertEqual(try ServicePasteboard.fileURLs(from: p), urls)
        p.clearContents()
        p.setPropertyList(urls.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        XCTAssertEqual(try ServicePasteboard.fileURLs(from: p), urls)
        p.clearContents()
        p.setString("/tmp/file.txt", forType: .string)
        XCTAssertThrowsError(try ServicePasteboard.fileURLs(from: p))
        p.clearContents()
        p.setPropertyList(["relative.txt"], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        XCTAssertThrowsError(try ServicePasteboard.fileURLs(from: p))
    }

    func testServiceRequestOriginSurvivesQueueAndDoesNotBecomeFinderTest() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedStore(root: root)
        let request = ActionRequest(directoryPath: "/tmp", template: .xlsx, origin: .service)
        try store.submit(request)
        XCTAssertEqual(try store.claim(request.id)?.origin, .service)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object.removeValue(forKey: "origin")
        let legacy = try JSONDecoder().decode(ActionRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.origin, .finder)
    }
}

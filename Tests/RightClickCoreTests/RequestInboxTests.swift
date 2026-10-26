import XCTest
@testable import RightClickCore

@MainActor
final class RequestInboxTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRunningAppConsumesNewRequestWithoutAnyURLCallback() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedStore(root: root)
        let done = expectation(description: "filesystem delivery, without URL wake")
        let request = CreateRequest(directoryPath: root.path, template: .docx)
        let inbox = RequestInbox(store: store, canPresent: { true }, present: { received, finish in
            XCTAssertEqual(received.id, request.id)
            finish("success")
            done.fulfill()
        }, failed: { XCTFail($0.localizedDescription) })
        try inbox.start()
        // Let the initial scan finish before submitting, so ONLY the watcher can deliver.
        let idle = expectation(description: "initial scan returned")
        DispatchQueue.main.async { idle.fulfill() }
        await fulfillment(of: [idle], timeout: 2)
        try store.submit(request)
        await fulfillment(of: [done], timeout: 3)
        XCTAssertTrue(try store.pendingIDs().isEmpty)
        XCTAssertEqual(try store.interruptedCount(), 0)
        withExtendedLifetime(inbox) {}
    }

    func testColdStartWaitsForWindowReadinessAndFindsExistingRequest() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedStore(root: root)
        let request = CreateRequest(directoryPath: root.path, template: .xlsx)
        try store.submit(request)
        var ready = false
        var received = 0
        let done = expectation(description: "request delivered after window exists")
        let inbox = RequestInbox(store: store, canPresent: { ready }, present: { _, finish in
            received += 1
            finish("success")
            done.fulfill()
        }, failed: { XCTFail($0.localizedDescription) })
        try inbox.start()
        let tick = expectation(description: "startup tick")
        DispatchQueue.main.async { tick.fulfill() }
        await fulfillment(of: [tick], timeout: 2)
        XCTAssertEqual(received, 0)
        XCTAssertEqual(try store.pendingIDs(), [request.id])
        ready = true
        inbox.wake()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(received, 1)
    }

    func testBurstWhileSheetOpenSerializesAndDuplicateWakeCannotReplay() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedStore(root: root)
        let first = CreateRequest(directoryPath: root.path, template: .txt)
        let rest = (0..<9).map { CreateRequest(directoryPath: root.path, template: FileTemplate.allCases[$0 % 6]) }
        var presented: [UUID] = []
        var closeFirst: RequestInbox.Completion?
        let firstShown = expectation(description: "first sheet")
        let othersShown = expectation(description: "remaining sheets")
        othersShown.expectedFulfillmentCount = rest.count
        let inbox = RequestInbox(store: store, canPresent: { true }, present: { request, finish in
            presented.append(request.id)
            if request.id == first.id {
                closeFirst = finish
                firstShown.fulfill()
            } else {
                closeFirst?("duplicate old completion")
                finish("success")
                othersShown.fulfill()
            }
        }, failed: { XCTFail($0.localizedDescription) })
        try inbox.start()
        try store.submit(first)
        await fulfillment(of: [firstShown], timeout: 3)
        for request in rest { try store.submit(request); inbox.wake() }
        XCTAssertEqual(presented, [first.id])
        XCTAssertEqual(inbox.activeID, first.id)
        closeFirst?("cancelled")
        for _ in 0..<10 { inbox.wake() }
        await fulfillment(of: [othersShown], timeout: 3)
        XCTAssertEqual(Set(presented), Set(([first] + rest).map(\.id)))
        XCTAssertEqual(presented.count, 10)
        XCTAssertTrue(try store.pendingIDs().isEmpty)
        XCTAssertEqual(try store.interruptedCount(), 0)
        XCTAssertNil(inbox.activeID)
        for request in [first] + rest { XCTAssertThrowsError(try store.submit(request)) }
    }

    func testRejectedAndPartialRequestsDoNotBlockValidRequestsOrReappearOnRestart() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedStore(root: root)
        var expired = CreateRequest(directoryPath: root.path, template: .txt)
        expired.createdAt = Date(timeIntervalSinceNow: -400)
        let malformed = UUID(), oversized = UUID()
        let pending = root.appendingPathComponent("Pending")
        try JSONEncoder().encode(expired).write(to: pending.appendingPathComponent(expired.id.uuidString + ".json"))
        try Data("broken".utf8).write(to: pending.appendingPathComponent(malformed.uuidString + ".json"))
        try Data(repeating: 0, count: 16_385).write(to: pending.appendingPathComponent(oversized.uuidString + ".json"))
        try Data("incomplete".utf8).write(to: pending.appendingPathComponent(UUID().uuidString + ".tmp"))
        let valid = CreateRequest(directoryPath: root.path, template: .pptx)
        try store.submit(valid)
        let shown = expectation(description: "valid request still presents")
        let rejected = expectation(description: "invalid requests rejected once")
        rejected.expectedFulfillmentCount = 3
        let inbox = RequestInbox(store: store, canPresent: { true }, present: { request, finish in
            XCTAssertEqual(request.id, valid.id)
            finish("success")
            shown.fulfill()
        }, failed: { _ in rejected.fulfill() })
        try inbox.start()
        await fulfillment(of: [shown, rejected], timeout: 3)
        XCTAssertEqual(try store.interruptedCount(), 0)
        XCTAssertTrue(try store.pendingIDs().isEmpty)
        let restarted = try SharedStore(root: root)
        for id in [expired.id, malformed, oversized, valid.id] { XCTAssertNil(try restarted.claim(id)) }
        withExtendedLifetime(inbox) {}
    }
}

import XCTest
@testable import RightClickCore

final class StabilityTests: XCTestCase {
    func testLaunchPresentationDistinguishesLoginFinderAndExplicitLaunch() {
        for isDefault in [false, true] {
            for login in [false, true] {
                for pending in [false, true] {
                    for active in [false, true] {
                        let actual = LaunchPresentation.shouldShowSettings(isDefaultLaunch: isDefault,
                            isLoginItem: login, hasPendingRequests: pending, hasActiveRequest: active)
                        if login || pending || active || !isDefault { XCTAssertFalse(actual) }
                        else { XCTAssertTrue(actual) }
                    }
                }
            }
        }
    }

    func testConcurrentSameNameCreates100DistinctCompleteFilesWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("并发 ' $ 🐈.json")
        let sentinel = Data("existing user content".utf8)
        try sentinel.write(to: original)
        let lock = NSLock()
        var outputs: [URL] = []
        var errors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            do {
                let result = try FileCreator.create(in: root, authorizedRoot: root, name: "并发 ' $ 🐈", template: .json)
                lock.lock(); outputs.append(result); lock.unlock()
            } catch { lock.lock(); errors.append(error.localizedDescription); lock.unlock() }
        }
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        XCTAssertEqual(outputs.count, 100)
        XCTAssertEqual(Set(outputs).count, 100)
        XCTAssertEqual(try Data(contentsOf: original), sentinel)
        for output in outputs {
            XCTAssertEqual(try Data(contentsOf: output), Data("{}\n".utf8))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 101)
    }

    @MainActor
    func test100QueuedRequestsWithCancellationFailuresDuplicateCompletionAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedStore(root: root.appendingPathComponent("store"))
        let requests = (0..<100).map { _ in CreateRequest(directoryPath: root.path, template: .json) }
        for request in requests { try store.submit(request) }
        XCTAssertThrowsError(try store.submit(CreateRequest(directoryPath: root.path, template: .txt)))
        let done = expectation(description: "all queued operations finish")
        done.expectedFulfillmentCount = 100
        var presented = Set<UUID>()
        var outputCount = 0
        var previousCompletion: RequestInbox.Completion?
        let inbox = RequestInbox(store: store, canPresent: { true }, present: { request, finish in
            XCTAssertTrue(presented.insert(request.id).inserted)
            let index = presented.count
            previousCompletion?("late duplicate completion")
            previousCompletion = finish
            DispatchQueue.main.async {
                defer { done.fulfill() }
                if index % 5 == 0 { finish("cancelled"); return }
                do {
                    let output = try FileCreator.create(in: root, authorizedRoot: root,
                        name: index % 7 == 0 ? "invalid/name" : "queue", template: .json) { candidate in
                        try store.journal(request.id, output: candidate, stage: .planned)
                    }
                    try store.journal(request.id, output: output, stage: .written)
                    outputCount += 1
                    finish("created")
                } catch { finish("rejected") }
            }
        }, failed: { XCTFail($0.localizedDescription) })
        try inbox.start()
        for _ in 0..<200 { inbox.wake() }
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(presented.count, 100)
        XCTAssertEqual(outputCount, (1...100).filter { $0 % 5 != 0 && $0 % 7 != 0 }.count)
        XCTAssertNil(inbox.activeID)
        XCTAssertTrue(try store.pendingIDs().isEmpty)
        XCTAssertEqual(try store.interruptedCount(), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("Journal").path).count, 0)
        for request in requests {
            XCTAssertThrowsError(try store.submit(request))
            XCTAssertNil(try store.claim(request.id))
        }
    }

    func testClipboardTenThousandUpdatesRemainBoundedAndDeduplicated() {
        var history = ClipboardHistory()
        let payload = String(repeating: "x", count: 64 * 1024)
        for index in 0..<10_000 {
            XCTAssertTrue(history.insert("\(index % 200):" + payload))
            if index % 100 == 0 {
                XCTAssertLessThanOrEqual(history.items.count, 100)
                XCTAssertLessThanOrEqual(history.items.reduce(0) { $0 + $1.text.utf8.count }, 4 * 1024 * 1024)
                XCTAssertEqual(Set(history.items.map(\.text)).count, history.items.count)
            }
        }
        let newest = history.items[0]
        history.insert(newest.text)
        XCTAssertEqual(history.items[0].id, newest.id)
        history.clear()
        XCTAssertTrue(history.items.isEmpty)
    }

    func testPanelGeometryAcrossDisplayEdgesAndNegativeOrigins() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 875),
                       CGRect(x: -1920, y: -500, width: 1920, height: 1080),
                       CGRect(x: 1440, y: 900, width: 1080, height: 1920)] {
            for x in [screen.minX - 10, screen.minX, screen.midX, screen.maxX, screen.maxX + 10] {
                for y in [screen.minY - 10, screen.minY, screen.midY, screen.maxY, screen.maxY + 10] {
                    for count in [0, 1, 2, 100] {
                        XCTAssertTrue(screen.contains(ClipboardPanelLayout.frame(at: CGPoint(x: x, y: y), visibleFrame: screen, count: count)))
                    }
                }
            }
        }
    }
}

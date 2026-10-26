import XCTest
@testable import RightClickCore

final class ClipboardTests: XCTestCase {
    func testCompactPanelFitsScreenAndFlipsAboveMouseAtBottom() {
        let screen = CGRect(x: -1440, y: 30, width: 1440, height: 870)
        let nearBottom = ClipboardPanelLayout.frame(at: CGPoint(x: -100, y: 35), visibleFrame: screen, count: 100)
        XCTAssertEqual(nearBottom.size, CGSize(width: 180, height: 291))
        XCTAssertEqual(nearBottom.minY, 47)
        XCTAssertTrue(screen.contains(nearBottom))
        let middle = ClipboardPanelLayout.frame(at: CGPoint(x: -800, y: 500), visibleFrame: screen, count: 1)
        XCTAssertEqual(middle, CGRect(x: -800, y: 428, width: 180, height: 60))
        let smallScreen = CGRect(x: 0, y: 0, width: 140, height: 100)
        XCTAssertTrue(smallScreen.contains(ClipboardPanelLayout.frame(at: .zero, visibleFrame: smallScreen, count: 100)))
    }

    func testDoubleLeftShiftRequiresTwoCompleteShortPresses() {
        var detector = LeftShiftDoubleTap()
        XCTAssertFalse(detector.handle(keyCode: 56, isDown: true, hasOtherModifiers: false, at: 1))
        XCTAssertFalse(detector.handle(keyCode: 56, isDown: false, hasOtherModifiers: false, at: 1.08))
        XCTAssertFalse(detector.handle(keyCode: 56, isDown: true, hasOtherModifiers: false, at: 1.2))
        XCTAssertTrue(detector.handle(keyCode: 56, isDown: false, hasOtherModifiers: false, at: 1.28))
        XCTAssertFalse(detector.handle(keyCode: 56, isDown: true, hasOtherModifiers: false, at: 1.35))
        XCTAssertFalse(detector.handle(keyCode: 56, isDown: false, hasOtherModifiers: false, at: 1.4))
    }

    func testRightShiftChordsTypingAndLongPressNeverTrigger() {
        for cancelKind in ["right", "chord", "typing", "long", "gap", "repeatedDown"] {
            var detector = LeftShiftDoubleTap()
            _ = detector.handle(keyCode: 56, isDown: true, hasOtherModifiers: false, at: 1)
            _ = detector.handle(keyCode: 56, isDown: false, hasOtherModifiers: false, at: 1.05)
            switch cancelKind {
            case "right": _ = detector.handle(keyCode: 60, isDown: true, hasOtherModifiers: false, at: 1.1)
            case "chord": _ = detector.handle(keyCode: 56, isDown: true, hasOtherModifiers: true, at: 1.1)
            case "typing": detector.reset()
            case "long":
                _ = detector.handle(keyCode: 56, isDown: true, hasOtherModifiers: false, at: 1.1)
                XCTAssertFalse(detector.handle(keyCode: 56, isDown: false, hasOtherModifiers: false, at: 1.5))
            case "repeatedDown":
                _ = detector.handle(keyCode: 56, isDown: true, hasOtherModifiers: false, at: 1.1)
                _ = detector.handle(keyCode: 56, isDown: true, hasOtherModifiers: false, at: 1.11)
            default: break
            }
            let time = cancelKind == "gap" ? 2.0 : (cancelKind == "long" ? 1.6 : 1.16)
            XCTAssertFalse(detector.handle(keyCode: 56, isDown: true, hasOtherModifiers: false, at: time))
            XCTAssertFalse(detector.handle(keyCode: 56, isDown: false, hasOtherModifiers: false, at: time + 0.05))
        }
    }

    func testHistoryDeduplicatesAllEntriesAndEnforcesCountAndByteLimits() {
        var history = ClipboardHistory(maxCount: 3, maxItemBytes: 12, maxTotalBytes: 15)
        XCTAssertFalse(history.insert(" \n"))
        XCTAssertFalse(history.insert(String(repeating: "x", count: 13)))
        history.insert("一"); let firstID = history.items[0].id
        history.insert("two"); history.insert("three"); history.insert("一")
        XCTAssertEqual(history.items.map(\.text), ["一", "three", "two"])
        XCTAssertEqual(history.items[0].id, firstID)
        history.insert("four")
        XCTAssertEqual(history.items.count, 3)
        history.insert("123456789012")
        XCTAssertLessThanOrEqual(history.items.reduce(0) { $0 + $1.text.utf8.count }, 15)
        history.remove(history.items[0].id)
        history.clear()
        XCTAssertTrue(history.items.isEmpty)
    }

    func testConfidentialTransientAndGeneratedMarkersAreExcluded() {
        for type in ClipboardHistory.excludedTypes {
            XCTAssertFalse(ClipboardHistory.mayCapture(types: ["public.utf8-plain-text", type]))
        }
        XCTAssertTrue(ClipboardHistory.mayCapture(types: ["public.utf8-plain-text"]))
    }

    func testPasteGuardRequiresOriginalFocusUnchangedClipboardAndPermission() {
        func allowed(focus: Int32? = 42, alive: Bool = true, permission: Bool = true,
                     change: Int = 10, released: Bool = true) -> Bool {
            PasteBackGuard.canSend(targetPID: 42, frontmostPID: focus, targetIsAlive: alive,
                permission: permission, expectedChangeCount: 10, currentChangeCount: change,
                modifiersAreReleased: released)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(focus: 43)); XCTAssertFalse(allowed(focus: nil))
        XCTAssertFalse(allowed(alive: false)); XCTAssertFalse(allowed(permission: false))
        XCTAssertFalse(allowed(change: 11)); XCTAssertFalse(allowed(released: false))
    }
}

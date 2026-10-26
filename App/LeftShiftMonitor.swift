import AppKit

// Based on the event-tap approach in RightButtonExtension; rewritten to observe
// without consuming keys, distinguish left Shift and recover disabled taps.
@MainActor
final class LeftShiftMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = LeftShiftDoubleTap()
    private let invoked: () -> Void
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init(invoked: @escaping () -> Void) { self.invoked = invoked }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        stop()
        guard CGPreflightListenEventAccess() else { return false }
        let kinds: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = kinds.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // This tap's run-loop source is installed only on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<LeftShiftMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                    options: .listenOnly, eventsOfInterest: mask, callback: callback,
                    userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else { return false }
        tap = newTap
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        return isRunning
    }

    func stop() {
        detector.reset()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            detector.reset()
            if let tap, CGPreflightListenEventAccess() { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { detector.reset(); return }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let otherFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskSecondaryFn]
        let chord = !event.flags.intersection(otherFlags).isEmpty ||
            CGEventSource.keyState(.combinedSessionState, key: 60)
        let down = CGEventSource.keyState(.combinedSessionState, key: 56)
        if detector.handle(keyCode: code, isDown: down, hasOtherModifiers: chord,
                           at: Double(event.timestamp) / 1_000_000_000) {
            // Keep the event-tap callback short; presentation happens afterwards.
            DispatchQueue.main.async { [weak self] in self?.invoked() }
        }
    }
}

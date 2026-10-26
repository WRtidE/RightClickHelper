import Foundation
import Darwin

/// The durable inbox is the source of truth; URL activation is only a wake-up.
/// All state and completions run on the main queue. One dialog owns one request.
@MainActor
final class RequestInbox {
    typealias Completion = (String) -> Void
    private let store: SharedStore
    private let canPresent: () -> Bool
    private let present: (CreateRequest, @escaping Completion) -> Void
    private let failed: (Error) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var scheduled = false
    private(set) var activeID: UUID?

    init(store: SharedStore, canPresent: @escaping () -> Bool,
         present: @escaping (CreateRequest, @escaping Completion) -> Void,
         failed: @escaping (Error) -> Void) {
        self.store = store
        self.canPresent = canPresent
        self.present = present
        self.failed = failed
    }

    func start() throws {
        guard source == nil else { return }
        let fd = open(store.root.appendingPathComponent("Pending").path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        watcher.setEventHandler { [weak self] in self?.wake() }
        watcher.setCancelHandler { close(fd) }
        source = watcher
        watcher.resume()
        RequestTrace.event("inbox-listening")
        // Subscribe BEFORE scanning, closing the startup delivery race.
        wake()
    }

    deinit { source?.cancel() }

    func wake() {
        guard source != nil, !scheduled, activeID == nil else { return }
        scheduled = true
        // Never enter a modal session from launch, URL or filesystem callbacks.
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.drain()
        }
    }

    private func drain() {
        guard source != nil, activeID == nil, canPresent() else { return }
        do {
            for id in try store.pendingIDs() {
                do {
                    guard let request = try store.claim(id) else { continue }
                    activeID = id
                    RequestTrace.event("request-claimed", id: id)
                    present(request) { [weak self] result in self?.complete(id, result: result) }
                    return
                } catch {
                    RequestTrace.event("request-rejected", id: id)
                    failed(error)
                }
            }
            RequestTrace.event("inbox-idle")
        } catch { failed(error) }
    }

    private func complete(_ id: UUID, result: String) {
        // A duplicated completion or URL must not finish someone else's request.
        guard activeID == id else { return }
        do { try store.finish(id, message: result) } catch { failed(error) }
        activeID = nil
        // Retention errors do not change an action's result or replay it.
        do { try store.pruneHistory() } catch { RequestTrace.event("history-prune-failed") }
        // Always rescan: filesystem notifications may coalesce while a dialog is open.
        wake()
    }
}

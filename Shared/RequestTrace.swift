import Foundation
import OSLog

/// Local lifecycle diagnostics. Never log file paths, bookmark data or filenames.
enum RequestTrace {
    private static let logger = Logger(subsystem: "dev.rightclickhelper.prototype", category: "RequestLifecycle")

    static func event(_ stage: String, id: UUID? = nil) {
        logger.notice("\(stage, privacy: .public) request=\(id?.uuidString ?? "-", privacy: .public)")
    }

    static func duration(_ stage: String, since start: UInt64) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        logger.notice("\(stage, privacy: .public) duration_ms=\(milliseconds, privacy: .public)")
    }
}

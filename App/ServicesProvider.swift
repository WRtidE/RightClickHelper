import AppKit

@MainActor
final class ServicesProvider: NSObject {
    @objc(handleFiles:userData:error:)
    func handleFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        do {
            guard let userData, let action = ServiceAction(rawValue: userData) else {
                throw PrototypeError.message("未知的右键助手服务。")
            }
            let urls = try ServicePasteboard.fileURLs(from: pasteboard)
            try AppState.shared.performService(action, urls: urls)
        } catch let failure {
            error?.pointee = failure.localizedDescription as NSString
            AppState.shared.message = failure.localizedDescription
            AppState.shared.store?.record("service", message: "服务未执行：\((failure as NSError).domain)/\((failure as NSError).code)")
        }
    }
}

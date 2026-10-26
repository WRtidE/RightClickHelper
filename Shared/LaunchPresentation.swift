import Foundation

enum LaunchPresentation {
    static func shouldShowSettings(isDefaultLaunch: Bool, isLoginItem: Bool,
                                   hasPendingRequests: Bool, hasActiveRequest: Bool) -> Bool {
        isDefaultLaunch && !isLoginItem && !hasPendingRequests && !hasActiveRequest
    }
}

import Foundation

enum LaunchPresentation {
    static func shouldShowSettingsOnReopen(hasPendingRequests: Bool, hasActiveRequest: Bool,
                                          hasActionDialog: Bool) -> Bool {
        !hasPendingRequests && !hasActiveRequest && !hasActionDialog
    }

    static func shouldShowSettings(isDefaultLaunch: Bool, isLoginItem: Bool,
                                   hasPendingRequests: Bool, hasActiveRequest: Bool) -> Bool {
        isDefaultLaunch && !isLoginItem && !hasPendingRequests && !hasActiveRequest
    }
}

import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    var isRegistered: Bool { status == .enabled || status == .requiresApproval }
    var statusText: String {
        switch status {
        case .enabled: return "已开启：登录 Mac 后在后台运行，不弹出设置窗口。"
        case .notRegistered: return "未开启：需要手动打开右键助手。"
        case .requiresApproval: return "等待系统允许：请在登录项设置中允许右键助手。"
        case .notFound: return "未开启：尚未注册可用的登录项。"
        @unknown default: return "无法确定登录项状态，请刷新或检查系统设置。"
        }
    }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        refresh()
        errorMessage = nil
        if enabled {
            // Never re-register automatically after the user disables it in System Settings.
            guard status != .enabled, status != .requiresApproval else { return }
            do { try SMAppService.mainApp.register() }
            catch { errorMessage = "未能开启开机启动：\(error.localizedDescription)" }
            refresh()
        } else {
            guard status != .notRegistered else { return }
            isUpdating = true
            SMAppService.mainApp.unregister { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isUpdating = false
                    if let error { self.errorMessage = "未能关闭开机启动：\(error.localizedDescription)" }
                    self.refresh()
                }
            }
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

struct GeneralSettingsPane: View {
    @ObservedObject private var loginItem = LoginItemController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("启动与后台运行").font(.headline)
            Toggle("开机启动（登录后运行）", isOn: Binding(get: { loginItem.isRegistered }, set: loginItem.setEnabled))
                .disabled(loginItem.isUpdating)
                .accessibilityIdentifier("launch-at-login")
            Text(loginItem.statusText).font(.callout).foregroundStyle(.secondary)
            if let error = loginItem.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            HStack {
                Button("系统登录项设置…", action: loginItem.openSystemSettings)
                Button("刷新启动状态", action: loginItem.refresh)
            }
            Divider()
            Text("关闭设置窗口后继续运行；选择“退出右键助手”会结束本次运行。开启开机启动后，下次登录会重新运行。")
                .font(.callout)
            Text("文本历史仍需在“剪贴板”页启用，并具备相应权限。历史仅保存在内存中，退出或重启后清空；开机启动不会自动授予权限。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(16).onAppear { loginItem.refresh() }
    }
}

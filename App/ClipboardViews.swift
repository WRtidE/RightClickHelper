import SwiftUI

struct ClipboardSettingsPane: View {
    @ObservedObject var controller = ClipboardController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("双击左 Shift，找回刚才复制的文字").font(.headline)
            Toggle("启用文本历史", isOn: Binding(get: { controller.enabled }, set: controller.setEnabled))
                .accessibilityIdentifier("clipboard-enabled")
            Text("最多 100 条，仅存内存；退出应用或停用功能即清空。关闭主窗口后仍运行；开机启动可在“通用”页设置。")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("记录与快捷键").font(.subheadline.bold())
                VStack(alignment: .leading, spacing: 8) {
                    Text(controller.recordingStatus).font(.caption)
                    Text(controller.shortcutStatus).font(.caption)
                    HStack {
                        Button("允许读取剪贴板…", action: controller.requestClipboardAccess)
                        Button("允许监听左 Shift…", action: controller.requestShortcutAccess)
                    }.disabled(!controller.enabled)
                    HStack {
                        Toggle("暂停记录", isOn: Binding(get: { controller.paused }, set: controller.setPaused))
                            .disabled(!controller.enabled)
                        Spacer()
                        Button("刷新权限状态", action: controller.refreshPermissions)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 8) {
                Text("选择记录后的行为").font(.subheadline.bold())
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("自动粘贴回原应用（可选）", isOn: Binding(get: { controller.autoPaste }, set: controller.setAutoPaste))
                        .accessibilityIdentifier("clipboard-auto-paste")
                    Text(controller.pasteAllowed ? "辅助功能权限已具备；选择记录后才发送 ⌘V。" : "尚无自动粘贴权限；选择记录仍可复制，然后手动按 ⌘V。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("授权自动粘贴…", action: controller.requestPasteAccess).disabled(!controller.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("打开文本历史", action: controller.togglePanel)
                Button("搜索与管理…", action: controller.showHistoryManager)
                Text("\(controller.history.items.count) / 100 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空历史", action: controller.clearHistory).disabled(controller.history.items.isEmpty)
            }
            Text(controller.message).font(.callout).textSelection(.enabled)
            Text("只记录文本，跳过已标记敏感或临时的内容；不上传、不写入日志。若旧工具也监听 Shift，请关闭旧工具的监听，避免同时弹出两个面板。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(16)
    }
}

// Matches the original RightButtonExtension popover's dimensions and card styling.
// Search and management live in their own window to keep this shortcut compact.
struct CompactClipboardHistoryPane: View {
    @ObservedObject var controller: ClipboardController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ClipboardPanelLayout.rowSpacing) {
                ForEach(controller.history.items) { item in
                    CompactClipboardCard(item: item) { controller.choose(item) }
                }
            }.padding(10)
        }
        .scrollIndicators(.never)
        .frame(width: ClipboardPanelLayout.width)
        .background(Color.white.opacity(0.01))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onChange(of: controller.history.items.count) { _, _ in controller.resizeCompactPanel() }
    }
}

private struct CompactClipboardCard: View {
    let item: ClipboardHistoryItem
    let choose: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(item.text.prefix(500)))
                    .font(.body).foregroundStyle(.black.opacity(0.85))
                    .lineLimit(3).truncationMode(.tail)
                Text(item.date, style: .time).font(.caption2).foregroundStyle(.black.opacity(0.55))
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: ClipboardPanelLayout.rowHeight,
                   maxHeight: ClipboardPanelLayout.rowHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovering ? 0.95 : 0.90)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 1))
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.12), radius: hovering ? 6 : 2,
                    x: 0, y: hovering ? 3 : 1)
            .scaleEffect(hovering && !reduceMotion ? 1.04 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("复制记录：" + String(item.text.prefix(100)))
    }
}

struct ClipboardHistoryPane: View {
    @ObservedObject var controller: ClipboardController
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("搜索历史文本", text: $controller.query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityIdentifier("clipboard-search")
                Button("清空", action: controller.clearHistory).disabled(controller.history.items.isEmpty)
            }
            if controller.filteredItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard").font(.largeTitle).foregroundStyle(.secondary)
                    Text(controller.history.items.isEmpty ? "暂无文本历史" : "没有匹配的记录").font(.headline)
                    Text(controller.enabled ? "复制一些文字后再来看看。记录状态可在剪贴板设置中查看。" : "请先在剪贴板设置中启用文本历史。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $controller.selectedID) {
                    ForEach(controller.filteredItems) { item in
                        HStack(alignment: .top) {
                            Button { controller.choose(item) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(String(item.text.prefix(500))).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(item.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("复制记录：" + String(item.text.prefix(100)))
                            Button { controller.remove(item.id) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).help("删除这条历史").accessibilityLabel("删除记录")
                        }.padding(.vertical, 3).tag(item.id)
                    }
                }.listStyle(.inset)
            }
            HStack {
                Text(controller.paused ? "记录已暂停" : "\(controller.history.items.count) 条 · 仅存内存")
                Spacer()
                Text(controller.autoPaste && controller.pasteAllowed ? "选择后复制并粘贴" : "选择后复制 · ⌘V 粘贴")
            }.font(.caption).foregroundStyle(.secondary)
            Text("Enter 选用记录 · Esc 关闭").font(.caption2).foregroundStyle(.secondary)
        }.padding(14).frame(width: 440, height: 460)
            .onAppear { searchFocused = true }
            .onExitCommand(perform: controller.hidePanel)
    }
}

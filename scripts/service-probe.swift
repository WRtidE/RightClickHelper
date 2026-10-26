// Integration client for the installed app's public macOS Services interface.
// Usage: service-probe <copyPath|create|terminal|applications> <absolute-path> [...]
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let titles = ["copyPath": "右键助手：复制完整路径", "create": "右键助手：新建文件…",
              "terminal": "右键助手：在此打开终端", "applications": "右键助手：用常用应用打开…"]
guard arguments.count >= 2, let title = titles[arguments[0]],
      arguments.dropFirst().allSatisfy({ $0.hasPrefix("/") }) else {
    fputs("Usage: service-probe <action> <absolute-path> [...]\n", stderr)
    exit(2)
}
let app = NSApplication.shared
let pasteboard = NSPasteboard.withUniqueName()
defer { pasteboard.releaseGlobally() }
let urls = arguments.dropFirst().map { URL(fileURLWithPath: $0) }
guard pasteboard.writeObjects(urls as [NSURL]) else { exit(3) }
let succeeded = NSPerformService(title, pasteboard)
print("service=\(arguments[0]) dispatched=\(succeeded) count=\(urls.count)")
guard succeeded else { exit(1) }
if arguments[0] == "copyPath" {
    let expected = urls.map(\.path).joined(separator: "\n")
    let started = Date()
    // Pasteboard-server changes can reach the client after the cold-start
    // service reply. Bound this eventual check; never print clipboard contents.
    while NSPasteboard.general.string(forType: .string) != expected && Date().timeIntervalSince(started) < 2 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    let matches = NSPasteboard.general.string(forType: .string) == expected
    print("clipboardMatchesExpected=\(matches)")
    print("clipboardWaitMilliseconds=\(Int(Date().timeIntervalSince(started) * 1000))")
    if !matches { exit(4) }
}

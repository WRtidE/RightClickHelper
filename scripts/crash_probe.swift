import Foundation
import Darwin

// Developer-only subprocess probe. Never included in the application targets.
@main enum CrashProbe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let stage = CommandLine.arguments[2]
        let store = try SharedStore(root: root.appendingPathComponent("store"))
        let directory = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if stage == "inspect" {
            let records = try store.interruptedRequests()
            precondition(records.count == 1)
            let replay = try store.claim(records[0].id)
            precondition(replay == nil)
            let count = try FileManager.default.contentsOfDirectory(atPath: directory.path).count
            print("unresolved=\(records.count) files=\(count) stage=\(records[0].journal?.stage.rawValue ?? "none") noReplay=true")
            return
        }
        let request = CreateRequest(directoryPath: directory.path, template: .json)
        try store.submit(request); _ = try store.claim(request.id)
        let file = try FileCreator.create(in: directory, authorizedRoot: directory, name: "中断验证", template: .json) {
            try store.journal(request.id, output: $0, stage: .planned)
            if stage == "before-write" { _exit(77) }
        }
        if stage == "after-write" { _exit(78) }
        try store.journal(request.id, output: file, stage: .written)
        _exit(79)
    }
}

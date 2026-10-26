// Headless component benchmark. Does not launch UI, alter permissions or touch the clipboard.
import Foundation

@main
struct StabilityBenchmark {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rch-benchmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = try SharedStore(root: root.appendingPathComponent("store"))
        var creation: [Double] = []
        for index in 0..<100 {
            let request = CreateRequest(directoryPath: output.path, template: .json)
            let start = DispatchTime.now().uptimeNanoseconds
            try store.submit(request)
            guard try store.claim(request.id) != nil else { fatalError("claim failed") }
            let file = try FileCreator.create(in: output, authorizedRoot: output, name: "benchmark", template: .json) {
                try store.journal(request.id, output: $0, stage: .planned)
            }
            try store.journal(request.id, output: file, stage: .written)
            try store.finish(request.id, message: "benchmark")
            creation.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            guard try Data(contentsOf: file) == Data("{}\n".utf8) else { fatalError("incomplete output \(index)") }
        }
        let names = (0..<100).map { URL(fileURLWithPath: "/tmp/中文 空格 ' $/file-\($0).txt") }
        var paths: [Double] = []
        for _ in 0..<1000 {
            let start = DispatchTime.now().uptimeNanoseconds
            let absolute = PathText.absolute(names)
            let shell = PathText.shell(names)
            guard absolute.split(separator: "\n").count == 100, !shell.isEmpty else { fatalError("path output invalid") }
            paths.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        func summary(_ values: [Double]) -> [String: Any] {
            let ordered = values.sorted()
            return ["samples": values.count, "median_ms": ordered[ordered.count / 2],
                    "p95_ms": ordered[Int(ceil(Double(ordered.count) * 0.95)) - 1], "max_ms": ordered.last!]
        }
        let results: [String: Any] = [
            "scope": "Headless components only; excludes UI, Finder menu and launch latency",
            "json_create_with_journal_and_same_name_conflicts": summary(creation),
            "format_100_paths_absolute_and_shell": summary(paths),
            "files": try FileManager.default.contentsOfDirectory(atPath: output.path).count,
            "pending": try store.pendingIDs().count, "processing": try store.interruptedCount()
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}

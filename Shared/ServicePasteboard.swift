import AppKit

enum ServicePasteboard {
    static func fileURLs(from pasteboard: NSPasteboard) throws -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            try ServiceSelection.validate(urls, action: .copyPath)
            return urls
        }
        // Older file-oriented hosts publish the filenames property-list type.
        if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 8192 }) else {
                throw PrototypeError.message("服务收到无效文件路径。")
            }
            let urls = paths.map { URL(fileURLWithPath: $0) }
            try ServiceSelection.validate(urls, action: .copyPath)
            return urls
        }
        throw PrototypeError.message("请选中文件或文件夹后再调用服务；不把普通文本当作文件路径。")
    }
}

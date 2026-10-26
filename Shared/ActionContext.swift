import Foundation

enum ActionContext {
    static func validateAuthorizationSelection(_ selected: URL, for target: URL) throws {
        guard selected.isFileURL, target.isFileURL, target.path != "/",
              selected.standardizedFileURL.path == target.standardizedFileURL.path else {
            throw PrototypeError.message("请选择本次操作的目标文件夹，不能用其他目录或整个磁盘替代。")
        }
        try validateOrdinaryDirectory(selected, within: selected)
    }

    /// Capture only a single ordinary local object. Do not infer directories for
    /// a multi-selection, app package, Finder alias, or symbolic link.
    static func terminalDirectory(for urls: [URL]) throws -> URL {
        guard urls.count == 1, let item = urls.first, item.isFileURL else {
            throw PrototypeError.message("请选择一个普通文件或文件夹。")
        }
        let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey])
        guard values.isPackage != true, values.isSymbolicLink != true, values.isAliasFile != true,
              values.isDirectory == true || values.isRegularFile == true else {
            throw PrototypeError.message("不支持包、替身或符号链接。")
        }
        return values.isDirectory == true ? item : item.deletingLastPathComponent()
    }

    static func validateOrdinaryDirectory(_ target: URL, within root: URL) throws {
        let components = try DirectoryBoundary.relativeComponents(of: target, within: root)
        var current = root
        for component in [""] + components {
            if !component.isEmpty { current.appendPathComponent(component) }
            let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey])
            guard values.isDirectory == true, values.isPackage != true,
                  values.isSymbolicLink != true, values.isAliasFile != true else {
                throw PrototypeError.message("目标目录不可用或包含包、替身、符号链接。")
            }
        }
    }
}

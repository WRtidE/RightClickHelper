import Foundation
import Darwin

enum FileCreator {
    static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\0"),
              name.utf8.count <= 240 else {
            throw PrototypeError.message("文件名不能为空或包含 /、: 等路径字符，且长度须在 240 UTF-8 字节以内。")
        }
    }

    /// Walk relative to an authorized directory descriptor. Never follow symlinks
    /// in target components, and never replace an existing destination.
    static func create(in directory: URL, authorizedRoot: URL, name: String,
                       template: FileTemplate, beforeCreate: (URL) throws -> Void = { _ in }) throws -> URL {
        try validateName(name)
        // Load first: a missing template must never leave an empty Office file.
        let content = try template.loadContent()
        let components = try DirectoryBoundary.relativeComponents(of: directory, within: authorizedRoot)
        var dirFD = Darwin.open(authorizedRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { throw posixError("无法访问授权目录") }
        defer { Darwin.close(dirFD) }
        for component in components {
            let next = Darwin.openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posixError("目标目录不存在、不可访问或包含符号链接") }
            Darwin.close(dirFD)
            dirFD = next
        }
        let suffix = "." + template.rawValue
        let stem = name.lowercased().hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
        guard !stem.isEmpty else { throw PrototypeError.message("请输入文件主体名。") }
        for index in 0..<1000 {
            let filename = stem + (index == 0 ? "" : " \(index + 1)") + suffix
            // Persist the candidate BEFORE any side effect. On interruption the
            // candidate is uncertain (it may pre-exist); never delete or replay it.
            try beforeCreate(directory.appendingPathComponent(filename))
            let fd = Darwin.openat(dirFD, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw posixError("无法创建文件")
            }
            var success = false
            defer {
                Darwin.close(fd)
                if !success { Darwin.unlinkat(dirFD, filename, 0) }
            }
            try content.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, address.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw posixError("文件写入失败") }
                    offset += written
                }
            }
            guard Darwin.fsync(fd) == 0 else { throw posixError("保存文件失败") }
            success = true
            return directory.appendingPathComponent(filename)
        }
        throw PrototypeError.message("同名文件过多，请更换名称。")
    }

    private static func posixError(_ operation: String) -> Error {
        let code = errno
        let reason = String(cString: strerror(code))
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "\(operation)：\(reason)（\(code)）"])
    }
}

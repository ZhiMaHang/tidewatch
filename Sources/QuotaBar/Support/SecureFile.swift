import Foundation

enum SecureFile {
    /// 写入敏感文件:先以 0600 权限落临时文件再原子替换,任何时刻都不会出现宽权限窗口
    static func write(_ data: Data, toPath path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmpPath = (dir as NSString).appendingPathComponent(".quotabar-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmpPath, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw QuotaError.missingCredentials(L("无法写入 \(dir)(临时文件创建失败)", "Cannot write to \(dir) (failed to create temp file)"))
        }
        do {
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                          withItemAt: URL(fileURLWithPath: tmpPath))
            } else {
                try FileManager.default.moveItem(atPath: tmpPath, toPath: path)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: tmpPath)
            throw error
        }
    }
}

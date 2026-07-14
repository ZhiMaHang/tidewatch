import Foundation

/// 账号元数据(非机密)落在 Application Support;token 走 Keychain。
enum AccountsRepository {
    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var directory: URL { appSupport.appendingPathComponent("Tidewatch", isDirectory: true) }
    static var fileURL: URL { directory.appendingPathComponent("accounts.json") }
    /// 改名前的旧目录(QuotaBar),启动首次加载时迁移过来
    private static var legacyFileURL: URL { appSupport.appendingPathComponent("QuotaBar/accounts.json") }

    static func load() -> [Account] {
        if let data = try? Data(contentsOf: fileURL) {
            return (try? JSONDecoder.iso.decode([Account].self, from: data)) ?? []
        }
        // 迁移:新目录还没有,就读旧 QuotaBar 目录并写到新目录
        if let data = try? Data(contentsOf: legacyFileURL),
           let accounts = try? JSONDecoder.iso.decode([Account].self, from: data) {
            save(accounts)
            return accounts
        }
        return []
    }

    static func save(_ accounts: [Account]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.iso.encode(accounts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

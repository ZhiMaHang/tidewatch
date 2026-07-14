import Foundation

/// 账号元数据(非机密)落在 Application Support;token 走 Keychain。
enum AccountsRepository {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("QuotaBar", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("accounts.json") }

    static func load() -> [Account] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.iso.decode([Account].self, from: data)) ?? []
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

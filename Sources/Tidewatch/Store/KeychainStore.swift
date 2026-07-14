import Foundation
import Security

enum KeychainStore {
    static let service = "com.zhimahang.tidewatch.credentials"
    /// 历次改名的旧服务名(新→旧顺序),启动时一次性迁移到当前服务名,避免已添加账号的 token 变孤儿
    static let legacyServices = ["com.zhimahang.quotabar.credentials", "com.quotabar.credentials"]

    /// 把旧服务名下的所有条目(账号 token、rescue 条目)搬到当前服务名,然后删旧。
    /// 只有确实迁完(或本来就没有旧条目)才置标记;读取被拒/失败则下次启动重试,避免账号被永久丢弃。
    static func migrateLegacyServiceIfNeeded() {
        let flag = "migratedTo_tidewatch_service"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }

        for legacy in legacyServices where !migrateOne(from: legacy) {
            return // 某个旧服务读/写失败,不置标记,下次重试
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    /// 迁移单个旧服务;成功(含本来就没有条目)返回 true,读/写失败返回 false
    private static func migrateOne(from legacy: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacy,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return true } // 没有旧条目
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return false }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { continue }
            // 当前服务已有该 account 就不覆盖(更新的迁移优先),否则搬过来
            if load(key: account) == nil, !save(data, key: account) { return false }
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacy,
        ] as CFDictionary)
        return true
    }

    @discardableResult
    static func save(_ data: Data, key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 读取其它应用的 generic password(如 Claude Code / Codex CLI 的凭据),系统会弹一次授权框
    static func readForeign(service: String, account: String? = nil) -> Data? {
        readForeignItem(service: service, account: account)?.data
    }

    /// 连同实际命中的 account 一起返回,写回时必须写到同一个条目,不能凭猜测
    static func readForeignItem(service: String, account: String? = nil) -> (data: Data, account: String)? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let dict = result as? [String: Any],
              let data = dict[kSecValueData as String] as? Data else { return nil }
        let hitAccount = (dict[kSecAttrAccount as String] as? String) ?? account ?? ""
        return (data, hitAccount)
    }

    /// 写回其它应用的 generic password(刷新 CLI token 后保持 CLI 可用);失败必须让调用方知道
    @discardableResult
    static func writeForeign(service: String, account: String? = nil, data: Data) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var attrs = query
            attrs[kSecValueData as String] = data
            if account == nil { attrs[kSecAttrAccount as String] = NSUserName() }
            return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
        }
        return false
    }
}

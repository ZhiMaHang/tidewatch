import Foundation
import Security

enum KeychainStore {
    static let service = "com.quotabar.credentials"

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

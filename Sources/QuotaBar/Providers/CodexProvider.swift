import Foundation
import CryptoKit

/// Codex CLI auth.json 的结构
struct CodexAuthFile: Codable {
    var OPENAI_API_KEY: String?
    var auth_mode: String?
    var last_refresh: String?
    var tokens: CodexTokens?
}

struct CodexTokens: Codable {
    var access_token: String
    var account_id: String?
    var id_token: String?
    var refresh_token: String?
}

enum CodexProvider {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let userAgent = "codex_cli_rs"
    static var defaultAuthPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")
    }

    // MARK: 凭据读写

    static let cliKeychainService = "Codex Auth"

    /// keyring 模式下的钥匙串 account key:"cli|" + sha256(规范化 CODEX_HOME 路径) 前 16 个十六进制字符
    static func keychainKey(forAuthPath path: String) -> String {
        let home = (path as NSString).deletingLastPathComponent
        let canonical = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        let hex = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "cli|" + String(hex.prefix(16))
    }

    static func readCLIAuthData(path: String) -> Data? {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { return data }
        // 新版 Codex CLI 的 keyring 模式:auth.json 被删,凭据在钥匙串 "Codex Auth"
        return KeychainStore.readForeign(service: cliKeychainService, account: keychainKey(forAuthPath: path))
            ?? KeychainStore.readForeign(service: cliKeychainService)
    }

    static func loadTokens(for account: Account) throws -> CodexTokens {
        switch account.source {
        case .codexAuthFile(let path):
            guard let data = readCLIAuthData(path: path) else {
                throw QuotaError.missingCredentials("读不到 \(path)(文件和钥匙串里都没有)")
            }
            guard let file = try? JSONDecoder().decode(CodexAuthFile.self, from: data), let tokens = file.tokens else {
                throw QuotaError.missingCredentials("auth.json 里没有 tokens(可能是纯 API key 模式)")
            }
            return tokens
        case .managed:
            guard let data = KeychainStore.load(key: account.id.uuidString),
                  let tokens = try? JSONDecoder().decode(CodexTokens.self, from: data) else {
                throw QuotaError.missingCredentials("钥匙串里找不到该账号的 token,请重新登录")
            }
            return tokens
        case .claudeCLI:
            throw QuotaError.missingCredentials("账号来源类型不匹配")
        }
    }

    static func persist(_ tokens: CodexTokens, for account: Account) {
        switch account.source {
        case .managed:
            if let data = try? JSONEncoder().encode(tokens) {
                KeychainStore.save(data, key: account.id.uuidString)
            }
        case .codexAuthFile(let path):
            // refresh token 会轮转,必须写回 CLI 的存储,否则会把用户的 Codex CLI 登录搞失效
            let url = URL(fileURLWithPath: path)
            let fileExists = FileManager.default.fileExists(atPath: path)
            var file = readCLIAuthData(path: path).flatMap { try? JSONDecoder().decode(CodexAuthFile.self, from: $0) }
                ?? CodexAuthFile(OPENAI_API_KEY: nil, auth_mode: "chatgpt", last_refresh: nil, tokens: nil)
            file.tokens = tokens
            file.last_refresh = ISO8601DateFormatter.flexible.string(from: Date())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let out = try? encoder.encode(file) else { return }
            if fileExists {
                try? out.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            } else {
                KeychainStore.writeForeign(service: cliKeychainService, account: keychainKey(forAuthPath: path), data: out)
            }
        case .claudeCLI:
            break
        }
    }

    // MARK: 额度

    static func fetchUsage(for account: Account) async throws -> (UsageSnapshot, CodexTokens) {
        var tokens = try loadTokens(for: account)
        do {
            let snapshot = try await fetchUsage(tokens: tokens)
            return (snapshot, tokens)
        } catch QuotaError.unauthorized {
            tokens = try await refresh(tokens)
            persist(tokens, for: account)
            let snapshot = try await fetchUsage(tokens: tokens)
            return (snapshot, tokens)
        }
    }

    static func fetchUsage(tokens: CodexTokens) async throws -> UsageSnapshot {
        var headers = [
            "Authorization": "Bearer \(tokens.access_token)",
            "User-Agent": userAgent,
        ]
        if let accountID = tokens.account_id {
            headers["chatgpt-account-id"] = accountID
        }
        let data = try await HTTP.getJSON(url: usageURL, headers: headers)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaError.parse("usage 响应不是 JSON 对象")
        }
        var windows: [UsageWindow] = []
        if let rateLimit = obj["rate_limit"] as? [String: Any] {
            windows.append(contentsOf: parseRateLimit(rateLimit, namePrefix: nil))
        }
        if let extra = obj["additional_rate_limits"] as? [[String: Any]] {
            for item in extra {
                let name = item["limit_name"] as? String ?? "附加额度"
                if let rl = item["rate_limit"] as? [String: Any] {
                    windows.append(contentsOf: parseRateLimit(rl, namePrefix: name))
                }
            }
        }
        guard !windows.isEmpty else {
            throw QuotaError.parse("usage 响应里没有识别到额度窗口")
        }
        var credits: String?
        if let c = obj["credits"] as? [String: Any] {
            if let unlimited = c["unlimited"] as? Bool, unlimited {
                credits = "不限量"
            } else if let balance = c["balance"] as? String, balance != "0" {
                credits = balance
            }
        }
        return UsageSnapshot(
            windows: windows,
            planType: obj["plan_type"] as? String,
            email: obj["email"] as? String,
            creditsBalance: credits,
            fetchedAt: Date()
        )
    }

    static func parseRateLimit(_ rl: [String: Any], namePrefix: String?) -> [UsageWindow] {
        var out: [UsageWindow] = []
        for (slot, fallback) in [("primary_window", "主窗口"), ("secondary_window", "次窗口")] {
            guard let w = rl[slot] as? [String: Any] else { continue }
            let used = (w["used_percent"] as? Double) ?? (w["used_percent"] as? Int).map(Double.init) ?? 0
            var title = fallback
            if let seconds = (w["limit_window_seconds"] as? Double) ?? (w["limit_window_seconds"] as? Int).map(Double.init) {
                title = windowTitle(seconds: seconds)
            }
            if let prefix = namePrefix { title = "\(prefix) · \(title)" }
            var resetsAt: Date?
            if let t = (w["reset_at"] as? Double) ?? (w["reset_at"] as? Int).map(Double.init) {
                resetsAt = Date(timeIntervalSince1970: t)
            } else if let after = (w["reset_after_seconds"] as? Double) ?? (w["reset_after_seconds"] as? Int).map(Double.init) {
                resetsAt = Date().addingTimeInterval(after)
            }
            out.append(UsageWindow(
                key: (namePrefix ?? "") + slot,
                title: title,
                usedPercent: min(max(used, 0), 100),
                resetsAt: resetsAt
            ))
        }
        return out
    }

    static func windowTitle(seconds: Double) -> String {
        let hours = seconds / 3600
        if hours <= 6 { return "5 小时窗口" }
        if hours <= 25 { return "24 小时窗口" }
        if hours <= 24 * 8 { return "本周" }
        return "\(Int(hours / 24)) 天窗口"
    }

    // MARK: Token 刷新

    static func refresh(_ tokens: CodexTokens) async throws -> CodexTokens {
        guard let refreshToken = tokens.refresh_token else { throw QuotaError.unauthorized }
        // codex-rs 的刷新请求是 JSON 体(授权码兑换才是 form-urlencoded)
        let data: Data
        do {
            data = try await HTTP.postJSON(url: tokenURL, body: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "scope": "openid profile email",
            ])
        } catch QuotaError.http(let code, _) where code == 400 {
            throw QuotaError.unauthorized
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw QuotaError.oauth("刷新响应缺少 access_token")
        }
        var next = tokens
        next.access_token = access
        if let r = obj["refresh_token"] as? String { next.refresh_token = r }
        if let idToken = obj["id_token"] as? String {
            next.id_token = idToken
            if next.account_id == nil {
                next.account_id = accountID(fromIDToken: idToken)
            }
        }
        return next
    }

    static func accountID(fromIDToken idToken: String) -> String? {
        guard let payload = JWT.payload(idToken),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    static func email(fromIDToken idToken: String) -> String? {
        JWT.payload(idToken)?["email"] as? String
    }
}

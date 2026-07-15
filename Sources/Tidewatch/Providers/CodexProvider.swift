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
    // 版本号走单一事实源,避免多处漂移(值同 AppVersion.current;任意 UA 对 Codex 端点都可用)
    static var userAgent: String { "Tidewatch/\(AppVersion.current)" }
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

    /// keyring 模式下的钥匙串条目(带实际命中的 account,写回时必须写同一条目)
    static func keychainAuthItem(path: String) -> (data: Data, account: String)? {
        KeychainStore.readForeignItem(service: cliKeychainService, account: keychainKey(forAuthPath: path))
            ?? KeychainStore.readForeignItem(service: cliKeychainService)
    }

    static func readCLIAuthData(path: String) -> Data? {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { return data }
        // 新版 Codex CLI 的 keyring 模式:auth.json 被删,凭据在钥匙串 "Codex Auth"
        return keychainAuthItem(path: path)?.data
    }

    static func loadTokens(for account: Account) throws -> CodexTokens {
        switch account.source {
        case .codexAuthFile(let path):
            guard let data = readCLIAuthData(path: path) else {
                throw QuotaError.missingCredentials(L("读不到 \(path)(文件和钥匙串里都没有)", "Cannot read \(path) (not in the file or the keychain)"))
            }
            guard let file = try? JSONDecoder().decode(CodexAuthFile.self, from: data), let tokens = file.tokens else {
                throw QuotaError.missingCredentials(L("auth.json 里没有 tokens(可能是纯 API key 模式)", "No tokens in auth.json (may be API-key-only mode)"))
            }
            return tokens
        case .managed:
            guard let data = KeychainStore.load(key: account.id.uuidString),
                  let tokens = try? JSONDecoder().decode(CodexTokens.self, from: data) else {
                throw QuotaError.missingCredentials(L("钥匙串里找不到该账号的 token,请重新登录", "No token for this account in the keychain, please sign in again"))
            }
            return tokens
        case .claudeCLI, .glmApiKey:
            throw QuotaError.missingCredentials(L("账号来源类型不匹配", "Account source type mismatch"))
        }
    }

    static func persist(_ tokens: CodexTokens, for account: Account) throws {
        switch account.source {
        case .managed:
            guard let data = try? JSONEncoder().encode(tokens), KeychainStore.save(data, key: account.id.uuidString) else {
                throw QuotaError.missingCredentials(L("写入 Tidewatch 钥匙串失败", "Failed to write to the Tidewatch keychain"))
            }
        case .codexAuthFile(let path):
            // refresh token 会轮转,必须写回 CLI 的存储,否则会把用户的 Codex CLI 登录搞失效。
            // 用原始 dict 读改写,保留 codex-rs 可能依赖的未知字段(agent_identity 等)
            let fileExists = FileManager.default.fileExists(atPath: path)
            let keychainItem = fileExists ? nil : keychainAuthItem(path: path)
            let raw = fileExists ? (try? Data(contentsOf: URL(fileURLWithPath: path))) : keychainItem?.data
            var obj = (raw.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? ["auth_mode": "chatgpt"]
            var tokensObj = (obj["tokens"] as? [String: Any]) ?? [:]
            tokensObj["access_token"] = tokens.access_token
            if let v = tokens.account_id { tokensObj["account_id"] = v }
            if let v = tokens.id_token { tokensObj["id_token"] = v }
            if let v = tokens.refresh_token { tokensObj["refresh_token"] = v }
            obj["tokens"] = tokensObj
            obj["last_refresh"] = ISO8601DateFormatter.flexible.string(from: Date())
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            if let keychainItem {
                // 写回读到的同一个钥匙串条目,不能凭 hash 猜(读写不对称会把 CLI 的 token 搞丢)
                guard KeychainStore.writeForeign(service: cliKeychainService, account: keychainItem.account, data: out) else {
                    throw QuotaError.missingCredentials(L("写回钥匙串 \(cliKeychainService) 失败", "Failed to write back to keychain \(cliKeychainService)"))
                }
            } else {
                try SecureFile.write(out, toPath: path)
            }
        case .claudeCLI, .glmApiKey:
            throw QuotaError.missingCredentials(L("账号来源类型不匹配", "Account source type mismatch"))
        }
    }

    /// 刷新后的写回失败时,把新 token 暂存到 Tidewatch 自己的钥匙串,避免轮转后的 refresh token 彻底丢失
    static func persistOrRescue(_ tokens: CodexTokens, for account: Account) throws {
        do {
            try persist(tokens, for: account)
        } catch {
            if let data = try? JSONEncoder().encode(tokens) {
                KeychainStore.save(data, key: "rescue-\(account.id.uuidString)")
            }
            throw QuotaError.oauth(L("token 已刷新但写回原存储失败(新 token 已暂存到钥匙串 rescue 条目):", "Token refreshed but writing back to the original store failed (the new token was stashed in a keychain rescue entry): ") + error.localizedDescription)
        }
    }

    // MARK: 额度

    static func fetchUsage(for account: Account) async throws -> (UsageSnapshot, CodexTokens) {
        // 按凭据存储串行化:refresh token 单次有效,同一存储绝不能并发刷新;
        // 锁内才读 token,排队者会拿到前一次刷新后的新 token,不会重放旧的
        try await KeyedLocks.shared.run(credentialLockKey(account)) {
            var tokens = try loadTokens(for: account)
            do {
                let snapshot = try await fetchUsage(tokens: tokens)
                return (snapshot, tokens)
            } catch QuotaError.unauthorized {
                tokens = try await refresh(tokens)
                try persistOrRescue(tokens, for: account)
                let snapshot = try await fetchUsage(tokens: tokens)
                return (snapshot, tokens)
            }
        }
    }

    static func fetchUsage(tokens: CodexTokens) async throws -> UsageSnapshot {
        var headers = [
            "Authorization": "Bearer \(tokens.access_token)",
            "User-Agent": userAgent,
        ]
        if let accountID = tokens.account_id, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let data = try await HTTP.getJSON(url: usageURL, headers: headers)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaError.parse(L("usage 响应不是 JSON 对象", "usage response is not a JSON object"))
        }
        var windows: [UsageWindow] = []
        if let rateLimit = obj["rate_limit"] as? [String: Any] {
            windows.append(contentsOf: parseRateLimit(rateLimit, namePrefix: nil))
        }
        if let extra = obj["additional_rate_limits"] as? [[String: Any]] {
            for item in extra {
                let name = item["limit_name"] as? String ?? L("附加额度", "Extra limit")
                if let rl = item["rate_limit"] as? [String: Any] {
                    windows.append(contentsOf: parseRateLimit(rl, namePrefix: name))
                }
            }
        }
        guard !windows.isEmpty else {
            throw QuotaError.parse(L("usage 响应里没有识别到额度窗口", "No usage windows found in the response"))
        }
        var credits: String?
        if let c = obj["credits"] as? [String: Any] {
            if let unlimited = c["unlimited"] as? Bool, unlimited {
                credits = L("不限量", "Unlimited")
            } else if let balance = c["balance"] as? String, balance != "0" {
                credits = balance
            }
        }
        return UsageSnapshot(
            windows: windows,
            planType: obj["plan_type"] as? String,
            email: obj["email"] as? String,
            creditsBalance: credits,
            subscriptionEndsAt: tokens.id_token.flatMap(subscriptionEnd(fromIDToken:)),
            fetchedAt: Date()
        )
    }

    /// 从 id_token 的 openai auth 声明里读订阅到期/续订日
    static func subscriptionEnd(fromIDToken idToken: String) -> Date? {
        guard let payload = JWT.payload(idToken),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let s = auth["chatgpt_subscription_active_until"] as? String else { return nil }
        return parseISODate(s)
    }

    static func parseRateLimit(_ rl: [String: Any], namePrefix: String?) -> [UsageWindow] {
        var out: [UsageWindow] = []
        for (slot, fallback) in [("primary_window", L("主窗口", "Primary window")), ("secondary_window", L("次窗口", "Secondary window"))] {
            guard let w = rl[slot] as? [String: Any] else { continue }
            let used = (w["used_percent"] as? Double) ?? (w["used_percent"] as? Int).map(Double.init) ?? 0
            let seconds = (w["limit_window_seconds"] as? Double) ?? (w["limit_window_seconds"] as? Int).map(Double.init)
            var title = fallback
            if let seconds {
                title = windowTitle(seconds: seconds)
            }
            if let prefix = namePrefix { title = "\(prefix) · \(title)" }
            var resetsAt: Date?
            if let t = (w["reset_at"] as? Double) ?? (w["reset_at"] as? Int).map(Double.init) {
                resetsAt = Date(timeIntervalSince1970: t)
            } else if let after = (w["reset_after_seconds"] as? Double) ?? (w["reset_after_seconds"] as? Int).map(Double.init) {
                resetsAt = Date().addingTimeInterval(after)
            }
            // 账号级周窗:无模型前缀,且时长落在周区间(与 windowTitle 的分段一致);
            // 接口没给时长时按惯例 secondary=周
            let weeklyByDuration = seconds.map { $0 / 3600 > 25 && $0 / 3600 <= 24 * 8 }
            out.append(UsageWindow(
                key: (namePrefix ?? "") + slot,
                title: title,
                usedPercent: min(max(used, 0), 100),
                resetsAt: resetsAt,
                isAccountWeekly: namePrefix == nil && (weeklyByDuration ?? (slot == "secondary_window"))
            ))
        }
        return out
    }

    static func windowTitle(seconds: Double) -> String {
        let hours = seconds / 3600
        if hours <= 6 { return L("5 小时窗口", "5-hour window") }
        if hours <= 25 { return L("24 小时窗口", "24-hour window") }
        if hours <= 24 * 8 { return L("本周", "This week") }
        return L("\(Int(hours / 24)) 天窗口", "\(Int(hours / 24))-day window")
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
            ])
        } catch QuotaError.http(let code, _) where code == 400 {
            throw QuotaError.unauthorized
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw QuotaError.oauth(L("刷新响应缺少 access_token", "Refresh response is missing access_token"))
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

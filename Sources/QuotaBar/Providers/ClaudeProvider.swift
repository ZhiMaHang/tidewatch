import Foundation

/// Claude Code 同款 OAuth 凭据(钥匙串 JSON 里的 claudeAiOauth 结构)
struct ClaudeCredentials: Codable {
    var accessToken: String
    var refreshToken: String?
    /// 毫秒时间戳(Claude Code 的存储格式)
    var expiresAt: Double?
    var scopes: [String]?
    var subscriptionType: String?
    var rateLimitTier: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt / 1000) < Date().addingTimeInterval(60)
    }
}

enum ClaudeProvider {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    /// 授权码兑换(grll/claude-code-login 验证:JSON 体)
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    /// token 刷新(CodexBar 验证:form-urlencoded 体,platform 是新 host)
    static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let betaHeader = "oauth-2025-04-20"
    /// 不带 claude-code 风格 UA 会被服务端限流(社区实测),格式为 claude-code/<version>
    static let userAgent = "claude-code/2.1.52"
    static let cliKeychainService = "Claude Code-credentials"
    static var defaultCredentialsFile: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
    }

    // MARK: 凭据读写

    static func loadCredentials(for account: Account) throws -> ClaudeCredentials {
        switch account.source {
        case .managed:
            guard let data = KeychainStore.load(key: account.id.uuidString) else {
                throw QuotaError.missingCredentials("钥匙串里找不到该账号的 token,请重新登录")
            }
            guard let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) else {
                throw QuotaError.missingCredentials("token 数据损坏,请重新登录")
            }
            return creds
        case .claudeCLI(let path):
            if let path {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    throw QuotaError.missingCredentials("读不到 \(path)")
                }
                guard let creds = decodeClaudeAiOauth(data) else {
                    throw QuotaError.missingCredentials("\(path) 里没有 claudeAiOauth")
                }
                return creds
            }
            // 钥匙串优先;桌面版登录时条目只有 mcpOAuth 没有主 token,回退到 .credentials.json
            if let kc = KeychainStore.readForeign(service: cliKeychainService), let creds = decodeClaudeAiOauth(kc) {
                return creds
            }
            if let fd = try? Data(contentsOf: URL(fileURLWithPath: defaultCredentialsFile)), let creds = decodeClaudeAiOauth(fd) {
                return creds
            }
            throw QuotaError.missingCredentials("本机没有 Claude Code CLI 的主账号凭据(桌面版登录只有 MCP 子凭据)。请在终端 claude /login 后重试,或改用应用内登录")
        case .codexAuthFile:
            throw QuotaError.missingCredentials("账号来源类型不匹配")
        }
    }

    static func decodeClaudeAiOauth(_ raw: Data) -> ClaudeCredentials? {
        guard let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let oauthObj = obj["claudeAiOauth"],
              let oauthData = try? JSONSerialization.data(withJSONObject: oauthObj) else { return nil }
        return try? JSONDecoder().decode(ClaudeCredentials.self, from: oauthData)
    }

    static func persist(_ creds: ClaudeCredentials, for account: Account) {
        switch account.source {
        case .managed:
            if let data = try? JSONEncoder().encode(creds) {
                KeychainStore.save(data, key: account.id.uuidString)
            }
        case .claudeCLI(let path):
            // 写回 CLI 的存储,保持 CLI 侧 token 同步(refresh token 会轮转);
            // dict 合并,只覆盖我们管理的键,保留其它键(mcpOAuth、未知字段)
            let filePath: String?
            let existingRaw: Data?
            if let path {
                filePath = path
                existingRaw = try? Data(contentsOf: URL(fileURLWithPath: path))
            } else if let kc = KeychainStore.readForeign(service: cliKeychainService), decodeClaudeAiOauth(kc) != nil {
                filePath = nil
                existingRaw = kc
            } else {
                filePath = defaultCredentialsFile
                existingRaw = try? Data(contentsOf: URL(fileURLWithPath: defaultCredentialsFile))
            }
            var obj = (existingRaw.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            var oauthObj = (obj["claudeAiOauth"] as? [String: Any]) ?? [:]
            oauthObj["accessToken"] = creds.accessToken
            if let v = creds.refreshToken { oauthObj["refreshToken"] = v }
            if let v = creds.expiresAt { oauthObj["expiresAt"] = v }
            if let v = creds.scopes { oauthObj["scopes"] = v }
            if let v = creds.subscriptionType { oauthObj["subscriptionType"] = v }
            if let v = creds.rateLimitTier { oauthObj["rateLimitTier"] = v }
            obj["claudeAiOauth"] = oauthObj
            guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return }
            if let filePath {
                try? out.write(to: URL(fileURLWithPath: filePath), options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath)
            } else {
                KeychainStore.writeForeign(service: cliKeychainService, data: out)
            }
        case .codexAuthFile:
            break
        }
    }

    // MARK: 额度

    static func fetchUsage(for account: Account) async throws -> (UsageSnapshot, ClaudeCredentials) {
        var creds = try loadCredentials(for: account)
        if creds.isExpired {
            creds = try await refresh(creds)
            persist(creds, for: account)
        }
        do {
            let snapshot = try await fetchUsage(accessToken: creds.accessToken)
            return (snapshot, creds)
        } catch QuotaError.unauthorized {
            creds = try await refresh(creds)
            persist(creds, for: account)
            let snapshot = try await fetchUsage(accessToken: creds.accessToken)
            return (snapshot, creds)
        }
    }

    static func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        let data = try await HTTP.getJSON(url: usageURL, headers: [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": betaHeader,
            "User-Agent": userAgent,
        ])
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaError.parse("usage 响应不是 JSON 对象")
        }
        let windows = parseWindows(obj)
        guard !windows.isEmpty else {
            throw QuotaError.parse("usage 响应里没有识别到额度窗口: \(String(String(data: data, encoding: .utf8)?.prefix(160) ?? ""))")
        }
        return UsageSnapshot(windows: windows, planType: nil, email: nil, creditsBalance: nil, fetchedAt: Date())
    }

    static let knownWindowOrder = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus",
                                   "seven_day_oauth_apps", "seven_day_routines", "cowork", "extra_usage"]
    static let windowTitles: [String: String] = [
        "five_hour": "5 小时窗口",
        "seven_day": "本周(全部模型)",
        "seven_day_sonnet": "本周(Sonnet)",
        "seven_day_opus": "本周(Opus)",
        "seven_day_oauth_apps": "本周(OAuth 应用)",
        "seven_day_routines": "本周(Routines)",
        "cowork": "本周(Routines)",
        "extra_usage": "额外用量",
    ]

    static func parseWindows(_ obj: [String: Any]) -> [UsageWindow] {
        var result: [UsageWindow] = []
        var seen = Set<String>()
        let ordered = knownWindowOrder + obj.keys.sorted().filter { !knownWindowOrder.contains($0) }
        for key in ordered {
            guard !seen.contains(key), let dict = obj[key] as? [String: Any] else { continue }
            guard let utilization = dict["utilization"] as? Double ?? (dict["utilization"] as? Int).map(Double.init) else { continue }
            seen.insert(key)
            var resetsAt: Date?
            if let s = dict["resets_at"] as? String {
                resetsAt = ISO8601DateFormatter.flexible.date(from: s)
            } else if let t = dict["resets_at"] as? Double {
                resetsAt = Date(timeIntervalSince1970: t)
            }
            result.append(UsageWindow(
                key: key,
                title: windowTitles[key] ?? key,
                usedPercent: min(max(utilization, 0), 100),
                resetsAt: resetsAt
            ))
        }
        return result
    }

    static func fetchProfile(accessToken: String) async throws -> (email: String?, plan: String?) {
        let data = try await HTTP.getJSON(url: profileURL, headers: [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": betaHeader,
            "User-Agent": userAgent,
        ])
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        let accountObj = obj["account"] as? [String: Any]
        let email = (accountObj?["email"] as? String) ?? (obj["email"] as? String)
        let orgObj = obj["organization"] as? [String: Any]
        let plan = (orgObj?["organization_type"] as? String) ?? (accountObj?["subscription_type"] as? String)
        return (email, plan)
    }

    // MARK: Token 刷新

    static func refresh(_ creds: ClaudeCredentials) async throws -> ClaudeCredentials {
        guard let refreshToken = creds.refreshToken else { throw QuotaError.unauthorized }
        let data: Data
        do {
            data = try await HTTP.postForm(url: refreshURL, fields: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID,
            ], headers: ["User-Agent": userAgent])
        } catch QuotaError.http(let code, _) where code == 400 {
            throw QuotaError.unauthorized
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw QuotaError.oauth("刷新响应缺少 access_token")
        }
        var next = creds
        next.accessToken = access
        if let r = obj["refresh_token"] as? String { next.refreshToken = r }
        if let expiresIn = obj["expires_in"] as? Double {
            next.expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000
        }
        return next
    }
}

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

func parseISODate(_ s: String) -> Date? {
    ISO8601DateFormatter.flexible.date(from: s) ?? ISO8601DateFormatter.plain.date(from: s)
}

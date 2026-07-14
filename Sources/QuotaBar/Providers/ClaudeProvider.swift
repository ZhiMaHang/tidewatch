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
                throw QuotaError.missingCredentials(L("钥匙串里找不到该账号的 token,请重新登录", "No token for this account in the keychain, please sign in again"))
            }
            guard let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) else {
                throw QuotaError.missingCredentials(L("token 数据损坏,请重新登录", "Token data is corrupted, please sign in again"))
            }
            return creds
        case .claudeCLI(let path):
            if let path {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    throw QuotaError.missingCredentials(L("读不到 ", "Cannot read ") + path)
                }
                guard let creds = decodeClaudeAiOauth(data) else {
                    throw QuotaError.missingCredentials(L("\(path) 里没有 claudeAiOauth", "No claudeAiOauth in \(path)"))
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
            throw QuotaError.missingCredentials(L("本机没有 Claude Code CLI 的主账号凭据(桌面版登录只有 MCP 子凭据)。请在终端 claude /login 后重试,或改用应用内登录",
                                                  "No primary Claude Code CLI credentials found (a desktop login only leaves MCP sub-credentials). Run `claude /login` in a terminal and retry, or use in-app login."))
        case .codexAuthFile:
            throw QuotaError.missingCredentials(L("账号来源类型不匹配", "Account source type mismatch"))
        }
    }

    static func decodeClaudeAiOauth(_ raw: Data) -> ClaudeCredentials? {
        guard let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let oauthObj = obj["claudeAiOauth"],
              let oauthData = try? JSONSerialization.data(withJSONObject: oauthObj) else { return nil }
        return try? JSONDecoder().decode(ClaudeCredentials.self, from: oauthData)
    }

    static func persist(_ creds: ClaudeCredentials, for account: Account) throws {
        switch account.source {
        case .managed:
            guard let data = try? JSONEncoder().encode(creds), KeychainStore.save(data, key: account.id.uuidString) else {
                throw QuotaError.missingCredentials(L("写入 QuotaBar 钥匙串失败", "Failed to write to the QuotaBar keychain"))
            }
        case .claudeCLI(let path):
            // 写回 CLI 的存储,保持 CLI 侧 token 同步(refresh token 会轮转);
            // dict 合并,只覆盖我们管理的键,保留其它键(mcpOAuth、designOauth、未知字段)
            let filePath: String?
            let existingRaw: Data?
            var keychainAccount: String?
            if let path {
                filePath = path
                existingRaw = try? Data(contentsOf: URL(fileURLWithPath: path))
            } else if let item = KeychainStore.readForeignItem(service: cliKeychainService), decodeClaudeAiOauth(item.data) != nil {
                filePath = nil
                existingRaw = item.data
                keychainAccount = item.account
            } else {
                filePath = defaultCredentialsFile
                existingRaw = try? Data(contentsOf: URL(fileURLWithPath: defaultCredentialsFile))
            }
            var obj = (existingRaw.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            if filePath == nil && obj.isEmpty {
                // 钥匙串条目解析不出来就绝不重建,否则会抹掉 mcpOAuth 等兄弟键
                throw QuotaError.missingCredentials(L("钥匙串条目内容异常,拒绝写回以免损坏 Claude Code 凭据", "Keychain item content is abnormal; refusing to write back to avoid corrupting Claude Code credentials"))
            }
            var oauthObj = (obj["claudeAiOauth"] as? [String: Any]) ?? [:]
            oauthObj["accessToken"] = creds.accessToken
            if let v = creds.refreshToken { oauthObj["refreshToken"] = v }
            if let v = creds.expiresAt { oauthObj["expiresAt"] = v }
            if let v = creds.scopes { oauthObj["scopes"] = v }
            if let v = creds.subscriptionType { oauthObj["subscriptionType"] = v }
            if let v = creds.rateLimitTier { oauthObj["rateLimitTier"] = v }
            obj["claudeAiOauth"] = oauthObj
            let out = try JSONSerialization.data(withJSONObject: obj)
            if let filePath {
                try SecureFile.write(out, toPath: filePath)
            } else {
                guard KeychainStore.writeForeign(service: cliKeychainService, account: keychainAccount, data: out) else {
                    throw QuotaError.missingCredentials(L("写回钥匙串 \(cliKeychainService) 失败", "Failed to write back to keychain \(cliKeychainService)"))
                }
            }
        case .codexAuthFile:
            throw QuotaError.missingCredentials(L("账号来源类型不匹配", "Account source type mismatch"))
        }
    }

    /// 刷新后的写回失败时,把新 token 暂存到 QuotaBar 自己的钥匙串,避免轮转后的 refresh token 彻底丢失
    static func persistOrRescue(_ creds: ClaudeCredentials, for account: Account) throws {
        do {
            try persist(creds, for: account)
        } catch {
            if let data = try? JSONEncoder().encode(creds) {
                KeychainStore.save(data, key: "rescue-\(account.id.uuidString)")
            }
            throw QuotaError.oauth(L("token 已刷新但写回原存储失败(新 token 已暂存到钥匙串 rescue 条目):", "Token refreshed but writing back to the original store failed (the new token was stashed in a keychain rescue entry): ") + error.localizedDescription)
        }
    }

    // MARK: 额度

    static func fetchUsage(for account: Account) async throws -> (UsageSnapshot, ClaudeCredentials) {
        // 按凭据存储串行化 + 锁内重读,同 CodexProvider(refresh token 轮转,禁止并发刷新)
        try await KeyedLocks.shared.run(credentialLockKey(account)) {
            var creds = try loadCredentials(for: account)
            if creds.isExpired {
                creds = try await refresh(creds)
                try persistOrRescue(creds, for: account)
            }
            do {
                let snapshot = try await fetchUsage(accessToken: creds.accessToken)
                return (snapshot, creds)
            } catch QuotaError.unauthorized {
                creds = try await refresh(creds)
                try persistOrRescue(creds, for: account)
                let snapshot = try await fetchUsage(accessToken: creds.accessToken)
                return (snapshot, creds)
            }
        }
    }

    static func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        let data = try await HTTP.getJSON(url: usageURL, headers: [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": betaHeader,
            "User-Agent": userAgent,
        ])
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaError.parse(L("usage 响应不是 JSON 对象", "usage response is not a JSON object"))
        }
        let windows = parseWindows(obj)
        guard !windows.isEmpty else {
            throw QuotaError.parse(L("usage 响应里没有识别到额度窗口: ", "No usage windows found in the response: ") + String(String(data: data, encoding: .utf8)?.prefix(160) ?? ""))
        }
        return UsageSnapshot(windows: windows, planType: nil, email: nil, creditsBalance: nil, fetchedAt: Date())
    }

    static let knownWindowOrder = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus",
                                   "seven_day_oauth_apps", "seven_day_routines", "cowork", "extra_usage"]
    static var windowTitles: [String: String] {
        [
            "five_hour": L("5 小时窗口", "5-hour window"),
            "seven_day": L("本周(全部模型)", "This week (all models)"),
            "seven_day_sonnet": L("本周(Sonnet)", "This week (Sonnet)"),
            "seven_day_opus": L("本周(Opus)", "This week (Opus)"),
            "seven_day_oauth_apps": L("本周(OAuth 应用)", "This week (OAuth apps)"),
            "seven_day_routines": L("本周(Routines)", "This week (Routines)"),
            "cowork": L("本周(Routines)", "This week (Routines)"),
            "extra_usage": L("额外用量", "Extra usage"),
        ]
    }

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
                resetsAt = parseISODate(s) // 带不带小数秒都要能解析
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
            throw QuotaError.oauth(L("刷新响应缺少 access_token", "Refresh response is missing access_token"))
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

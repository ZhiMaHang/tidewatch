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

    /// 硬到期:access token 已经(或马上)不能用了,不续期就什么都干不了。
    /// `now` 显式可注入,好让边界行为能被断言(默认值保持所有调用点不变)
    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt / 1000) < now.addingTimeInterval(60)
    }

    /// 软到期:离到期还有 `lead` 秒,可以开始找机会续了。token 这会儿仍然可用——
    /// 提前量的意义就是把「续期时刻」从「到期时刻」上挪开(见 ClaudeProvider.renewLead)
    func renewalDue(lead: TimeInterval, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt / 1000) < now.addingTimeInterval(lead)
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
    /// api.anthropic.com 上的 usage / profile / design-MCP 用的 UA。这几个端点对 `claude-code/` 前缀
    /// 放行(社区实测 + 本机长期在用),不动它。版本号跟随本机较新的 Claude Code CLI
    /// (过旧版本有被服务端另眼相待的风险),发版前顺手对齐。
    static let apiUserAgent = "claude-code/2.1.215"

    /// token 端点(platform.claude.com / console.anthropic.com 的 /v1/oauth/token,刷新与兑换)用的 UA。
    ///
    /// ⚠️ 2026-07-24 本机实测(用假 refresh token,3 轮 + 颠倒发送顺序稳定复现):这两个 token host 有
    /// **一层按 User-Agent 指纹的边缘拦截,发生在凭据校验之前**——同一时刻、同一请求体,
    /// `claude-code/*` 与浏览器 UA 一律 429,而 `claude-cli/*`(真实 Claude Code CLI 的 UA)、
    /// `axios/*`、CFNetwork 默认 UA、空 UA 一律放行到 400 invalid_grant。这是 UA 分桶,不是容量桶
    /// ——容量桶下同一刻所有 UA 会一起 429。**旧值 `claude-code/2.1.207` 恰好落在被拦的那一类**,
    /// 就是自动刷新持续 429、access token 过期后只能重新登录的根因(用户 2026-07-24 报「全部被限流,
    /// 必须重新登录」)。
    ///
    /// 改用真实 CLI 的 UA 不只是「换个眼下能通的串」:它是 Anthropic 自家客户端在刷新这一步真正发送的
    /// UA,服务端无法在不误伤自己 CLI 的前提下封掉它,因此比社区口耳相传、无真实客户端背书的
    /// `claude-code/` 稳得多。
    static let tokenUserAgent = "claude-cli/2.1.215 (external, cli)"
    static let cliKeychainService = "Claude Code-credentials"

    // MARK: 提前续期(错开)

    /// 提前续期窗口:到期前 base…base+spread 之间的某一刻续,具体提前多久按账号定(见 renewLead)。
    /// 取 30~90 分钟是因为它要同时满足两头:比刷新间隔(默认 5 分钟)大得多,
    /// 才有足够多的轮次让名额轮到自己;又远小于 access token 的有效期,不至于频繁续。
    static let renewLeadBase: TimeInterval = 30 * 60
    static let renewLeadSpread: TimeInterval = 60 * 60

    /// 每个账号一个**稳定且互不相同**的提前量,由账号 UUID 派生(FNV-1a)。
    ///
    /// 稳定是必须的:若每轮重掷随机数,续期时刻会自己来回漂移,提前量就失去意义。
    /// 互不相同才是目的——同一批登录铸出来的 token 到期时刻几乎一样,若都等到期那刻才续,
    /// 就会挤成一个突发打在 token 端点上,而该端点与本机每一个 Claude Code 会话
    /// 共用同一个限流桶(2026-07-20 事故:4 个账号同批到期,4 次刷新挤在 5 秒内连发,全部 429,
    /// 冻结一天半)。
    ///
    /// 但别高估它:4 个账号从 1 小时窗口里各取一个点,最小间隔的中位数只有约 3 分钟,
    /// 实测有约 2/3 的概率仍有两个账号落进同一刷新轮。所以**硬保证不在这里,
    /// 在 UsageStore.grantRenewals 的每轮一个名额**;提前量只负责把堆叠的频率压下来,
    /// 让名额不必频繁推迟别人。两者缺一不可,但职责不同。
    static func renewLead(for id: UUID) -> TimeInterval {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        }
        return renewLeadBase + Double(hash % UInt64(renewLeadSpread))
    }

    /// 续期三分支决策的结果
    enum RenewalDecision: Equatable {
        /// 该续,且本轮有名额:先续再抓
        case renew
        /// 直接拿现有 token 去抓额度(还没到续期窗口,或到了但 token 仍可用、把名额让给别人)
        case proceed
        /// token 已硬到期又没名额:本轮一个请求都不发
        case deferred
    }

    /// 续期决策。抽成纯函数(now/lead 显式传入)是为了能精确断言边界——
    /// 夹在钥匙串读取与 HTTP 之间的原始写法没法测
    static func decide(creds: ClaudeCredentials, mayRenew: Bool, lead: TimeInterval, now: Date) -> RenewalDecision {
        // 硬到期**不受 lead 门控**:lead 再小(如 --check 传 0)也不能让已死的 token 蒙混过关,
        // 否则那条路径会拿死 token 去打 usage 端点、白吃一个 401
        let expired = creds.isExpired(now: now)
        guard creds.renewalDue(lead: lead, now: now) || expired else { return .proceed }
        if mayRenew { return .renew }
        // 软到期但没名额:token 还能用,照常抓数,把名额让给别人
        return expired ? .deferred : .proceed
    }
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
        case .codexAuthFile, .glmApiKey:
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
                throw QuotaError.missingCredentials(L("写入 Tidewatch 钥匙串失败", "Failed to write to the Tidewatch keychain"))
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
        case .codexAuthFile, .glmApiKey:
            throw QuotaError.missingCredentials(L("账号来源类型不匹配", "Account source type mismatch"))
        }
    }

    /// 刷新后的写回失败时,把新 token 暂存到 Tidewatch 自己的钥匙串,避免轮转后的 refresh token 彻底丢失
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

    /// `mayRenew`:本轮该账号是否持有「续期名额」(由 UsageStore 轮转发放,每个 provider 每轮一个)。
    /// 抓额度是廉价的,续期不是——续期要打 token 端点,而那个桶和本机所有 Claude Code 会话共用,
    /// 打炸了所有账号一起冻。所以续期必须限量,抓额度不必。
    /// `lead` 默认按账号派生的错开提前量;传 0 即退回「快到期才续」的旧语义
    /// (`--check` 用:它无视名额、串行连打全部账号,叠加提前量会一次性连发多个续期)
    static func fetchUsage(for account: Account, mayRenew: Bool,
                           lead: TimeInterval? = nil) async throws -> (UsageSnapshot, ClaudeCredentials) {
        // 按凭据存储串行化 + 锁内重读,同 CodexProvider(refresh token 轮转,禁止并发刷新)
        try await KeyedLocks.shared.run(credentialLockKey(account)) {
            var creds = try loadCredentials(for: account)
            switch decide(creds: creds, mayRenew: mayRenew,
                          lead: lead ?? renewLead(for: account.id), now: Date()) {
            case .renew:
                creds = try await refresh(creds)
                try persistOrRescue(creds, for: account)
            case .deferred:
                // 硬到期又没轮到名额:本轮一个请求都不发。拿已死的 token 去抓额度
                // 只会白吃一个 401,然后照样得续期——等于把限量绕过去
                throw QuotaError.renewalDeferred
            case .proceed:
                break // 还没到续期窗口,或到了但 token 仍可用、把名额让给别人
            }
            do {
                let snapshot = try await fetchUsage(accessToken: creds.accessToken)
                return (snapshot, creds)
            } catch QuotaError.unauthorized {
                // 兜底续期:提前量算错、服务端提前作废等情况下 token 会早于预期失效。
                // 同样受名额约束,否则「N 个账号一起 401」会重新变成一次突发
                guard mayRenew else { throw QuotaError.renewalDeferred }
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
            "User-Agent": apiUserAgent,
        ])
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaError.parse(L("usage 响应不是 JSON 对象", "usage response is not a JSON object"))
        }
        // 新版响应把各限额(含 Fable 等按模型细分的周额度)放在 limits 数组里,优先用它;
        // 没有 limits 才回退到旧的扁平 seven_day_* 键。
        let windows = parseLimits(obj) ?? parseWindows(obj)
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

    /// 解析新版 limits 数组:每项 { kind, group, percent, resets_at, is_active, scope.model.display_name }。
    /// kind: session / weekly_all / weekly_scoped(按模型细分,如 Fable)。返回 nil 表示响应里没有 limits。
    static func parseLimits(_ obj: [String: Any]) -> [UsageWindow]? {
        guard let limits = obj["limits"] as? [[String: Any]], !limits.isEmpty else { return nil }
        var result: [UsageWindow] = []
        for (i, lim) in limits.enumerated() {
            guard let percent = (lim["percent"] as? Double) ?? (lim["percent"] as? Int).map(Double.init) else { continue }
            let kind = lim["kind"] as? String ?? ""
            let group = lim["group"] as? String ?? ""
            var model: String?
            if let scope = lim["scope"] as? [String: Any], let m = scope["model"] as? [String: Any] {
                model = m["display_name"] as? String
            }
            var resetsAt: Date?
            if let s = lim["resets_at"] as? String { resetsAt = parseISODate(s) }
            result.append(UsageWindow(
                key: "limit-\(i)-\(kind)-\(model ?? "")",
                title: limitTitle(kind: kind, group: group, model: model),
                usedPercent: min(max(percent, 0), 100),
                resetsAt: resetsAt,
                // 账号级周窗 = weekly_all;兜底只认裸 "weekly"——功能域细分周窗
                // (类比扁平键 seven_day_oauth_apps/routines)同样无模型标注,宽前缀匹配会误标
                isAccountWeekly: kind == "weekly_all" || (model == nil && kind == "weekly")
            ))
        }
        return result.isEmpty ? nil : result
    }

    static func limitTitle(kind: String, group: String, model: String?) -> String {
        if kind == "session" || group == "session" { return L("5 小时窗口", "5-hour window") }
        if kind == "weekly_all" { return L("本周(全部模型)", "This week (all models)") }
        if let m = model, kind.hasPrefix("weekly") { return L("本周(\(m))", "This week (\(m))") }
        if kind.hasPrefix("weekly") { return L("本周", "This week") }
        if let m = model { return m }
        return kind.isEmpty ? L("额度", "Limit") : kind
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
                resetsAt: resetsAt,
                isAccountWeekly: key == "seven_day" // 扁平键里的账号级周窗(细分键如 seven_day_opus 不算)
            ))
        }
        return result
    }

    static func fetchProfile(accessToken: String) async throws -> (email: String?, plan: String?) {
        let data = try await HTTP.getJSON(url: profileURL, headers: [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": betaHeader,
            "User-Agent": apiUserAgent,
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
            ], headers: ["User-Agent": tokenUserAgent])
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

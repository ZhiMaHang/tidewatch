import Foundation

/// Claude Design 凭据(独立 OAuth 客户端,scope user:design:read/write)。
/// 结构对应 Claude Code 钥匙串里的 designOauth 子对象。
struct DesignCredentials: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?   // 毫秒
    var clientId: String?
    var scopes: [String]?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt / 1000) < Date().addingTimeInterval(60)
    }
}

enum DesignProvider {
    static let mcpURL = URL(string: "https://api.anthropic.com/v1/design/mcp")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "59637612-477b-4836-a601-b0589eda7704"

    static func keychainKey(_ account: Account) -> String { "design-\(account.id.uuidString)" }
    static func rescueKey(_ account: Account) -> String { "design-rescue-\(account.id.uuidString)" }

    /// 串行锁 key:.claudeCLI 的 design token 与主 token 同住一个钥匙串条目,
    /// 必须和 usage 刷新用**同一把锁**(不带 design: 前缀),否则并发读改写会互相覆盖、
    /// 冲掉对方的轮转 token,连带搞坏用户真实的 Claude Code 登录。
    /// managed 的 design token 是独立钥匙串键,用 design: 前缀即可。
    static func lockKey(for account: Account) -> String {
        if case .claudeCLI = account.source { return credentialLockKey(account) }
        return "design:" + credentialLockKey(account)
    }

    // MARK: 是否有 design 凭据(避免对没登录的账号发无谓请求)

    static func hasCredentials(for account: Account) -> Bool {
        (try? loadCredentials(for: account)) != nil
    }

    // MARK: 读写凭据

    static func loadCredentials(for account: Account) throws -> DesignCredentials {
        let primary = try loadPrimaryCredentials(for: account)
        // 上次刷新后写回失败会把新 token 暂存到 rescue;若它更新则优先用它,避免拿着已轮转掉的旧 token
        if let rd = KeychainStore.load(key: rescueKey(account)),
           let rescued = try? JSONDecoder().decode(DesignCredentials.self, from: rd),
           (rescued.expiresAt ?? 0) > (primary.expiresAt ?? 0) {
            return rescued
        }
        return primary
    }

    private static func loadPrimaryCredentials(for account: Account) throws -> DesignCredentials {
        switch account.source {
        case .managed:
            guard let data = KeychainStore.load(key: keychainKey(account)),
                  let creds = try? JSONDecoder().decode(DesignCredentials.self, from: data) else {
                throw QuotaError.missingCredentials(L("这个账号还没登录 Claude Design", "This account hasn't signed in to Claude Design"))
            }
            return creds
        case .claudeCLI(let path):
            let raw: Data
            if let path {
                guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    throw QuotaError.missingCredentials(L("读不到 ", "Cannot read ") + path)
                }
                raw = d
            } else {
                guard let d = KeychainStore.readForeign(service: ClaudeProvider.cliKeychainService) else {
                    throw QuotaError.missingCredentials(L("本机 Claude Code 没有 Design 凭据(先在终端 /design-login)",
                                                          "No local Claude Code Design credential (run /design-login in a terminal first)"))
                }
                raw = d
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  let designObj = obj["designOauth"],
                  let dd = try? JSONSerialization.data(withJSONObject: designObj),
                  let creds = try? JSONDecoder().decode(DesignCredentials.self, from: dd) else {
                throw QuotaError.missingCredentials(L("凭据里没有 designOauth(先在终端 /design-login)",
                                                      "No designOauth in credentials (run /design-login first)"))
            }
            return creds
        case .codexAuthFile, .glmApiKey:
            throw QuotaError.missingCredentials(L("账号来源类型不匹配", "Account source type mismatch"))
        }
    }

    /// 带锁写回:与 usage 刷新在同一把锁上互斥(见 lockKey),登录/刷新都走这里
    static func persistLocked(_ creds: DesignCredentials, for account: Account) async throws {
        try await KeyedLocks.shared.run(lockKey(for: account)) {
            try persistOrRescue(creds, for: account)
        }
    }

    static func persist(_ creds: DesignCredentials, for account: Account) throws {
        switch account.source {
        case .managed:
            guard let data = try? JSONEncoder().encode(creds), KeychainStore.save(data, key: keychainKey(account)) else {
                throw QuotaError.missingCredentials(L("写入 Tidewatch 钥匙串失败", "Failed to write to the Tidewatch keychain"))
            }
        case .claudeCLI(let path):
            // 把 designOauth 合并写回 Claude Code 的存储,保留 mcpOAuth/claudeAiOauth 等兄弟键
            let filePath: String?
            let existingRaw: Data?
            var hitAccount: String?
            if let path {
                filePath = path
                existingRaw = try? Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                filePath = nil
                let item = KeychainStore.readForeignItem(service: ClaudeProvider.cliKeychainService)
                existingRaw = item?.data
                hitAccount = item?.account
            }
            var obj = (existingRaw.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            guard !obj.isEmpty else {
                throw QuotaError.missingCredentials(L("凭据异常,拒绝写回以免损坏", "Credential store looks abnormal; refusing to write back"))
            }
            var designObj = (obj["designOauth"] as? [String: Any]) ?? [:]
            designObj["accessToken"] = creds.accessToken
            if let v = creds.refreshToken { designObj["refreshToken"] = v }
            if let v = creds.expiresAt { designObj["expiresAt"] = v }
            if let v = creds.clientId { designObj["clientId"] = v }
            if let v = creds.scopes { designObj["scopes"] = v }
            obj["designOauth"] = designObj
            let out = try JSONSerialization.data(withJSONObject: obj)
            if let filePath {
                try SecureFile.write(out, toPath: filePath)
            } else {
                // 写回读到的同一条目,不凭 service 猜
                guard KeychainStore.writeForeign(service: ClaudeProvider.cliKeychainService, account: hitAccount, data: out) else {
                    throw QuotaError.missingCredentials(L("写回钥匙串失败", "Failed to write back to the keychain"))
                }
            }
        case .codexAuthFile, .glmApiKey:
            throw QuotaError.missingCredentials(L("账号来源类型不匹配", "Account source type mismatch"))
        }
        KeychainStore.delete(key: rescueKey(account)) // 写回成功,清掉可能存在的 rescue
    }

    static func persistOrRescue(_ creds: DesignCredentials, for account: Account) throws {
        do {
            try persist(creds, for: account)
        } catch {
            if let data = try? JSONEncoder().encode(creds) {
                KeychainStore.save(data, key: rescueKey(account))
            }
            throw QuotaError.oauth(L("Design token 已刷新但写回失败(已暂存 rescue):", "Design token refreshed but write-back failed (stashed to rescue): ") + error.localizedDescription)
        }
    }

    // MARK: 刷新

    static func refresh(_ creds: DesignCredentials) async throws -> DesignCredentials {
        guard let refreshToken = creds.refreshToken else { throw QuotaError.unauthorized }
        let data: Data
        do {
            data = try await HTTP.postForm(url: tokenURL, fields: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": creds.clientId ?? clientID,
            ], headers: ["User-Agent": ClaudeProvider.userAgent])
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
        if let ei = obj["expires_in"] as? Double { next.expiresAt = (Date().timeIntervalSince1970 + ei) * 1000 }
        return next
    }

    // MARK: 拉项目

    static func fetchProjects(for account: Account) async throws -> [DesignProject] {
        try await KeyedLocks.shared.run(lockKey(for: account)) {
            var creds = try loadCredentials(for: account)
            if creds.isExpired {
                creds = try await refresh(creds)
                try persistOrRescue(creds, for: account)
            }
            do {
                return try await listProjects(token: creds.accessToken)
            } catch QuotaError.unauthorized {
                creds = try await refresh(creds)
                try persistOrRescue(creds, for: account)
                return try await listProjects(token: creds.accessToken)
            }
        }
    }

    static func listProjects(token: String) async throws -> [DesignProject] {
        let client = MCPClient(url: mcpURL, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": ClaudeProvider.betaHeader,
            "User-Agent": ClaudeProvider.userAgent,
        ])
        let data = try await client.callToolText(name: "list_projects", arguments: [:])
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return DesignProject(id: id, name: name, url: item["url"] as? String)
        }
    }
}

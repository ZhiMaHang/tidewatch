import Foundation

struct GLMCredentials: Codable {
    var apiKey: String
}

/// GLM 海外版(z.ai)Coding Plan 用量。
/// 端点是 z.ai 网页仪表盘内部调用的、未公开文档的接口(逆向自社区工具),防御式解析。
enum GLMProvider {
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    static func loadKey(for account: Account) throws -> String {
        guard let data = KeychainStore.load(key: account.id.uuidString),
              let creds = try? JSONDecoder().decode(GLMCredentials.self, from: data) else {
            throw QuotaError.missingCredentials(L("找不到 GLM API key,请重新添加账号", "No GLM API key found, please re-add the account"))
        }
        return creds.apiKey
    }

    static func saveKey(_ key: String, for account: Account) {
        if let data = try? JSONEncoder().encode(GLMCredentials(apiKey: key)) {
            KeychainStore.save(data, key: account.id.uuidString)
        }
    }

    static func fetchUsage(for account: Account) async throws -> UsageSnapshot {
        let key = try loadKey(for: account)
        func get(_ authValue: String) async throws -> Data {
            try await HTTP.getJSON(url: quotaURL, headers: [
                "Authorization": authValue,      // z.ai 内部端点:原始 key(不加 Bearer),失败再回退 Bearer
                "Accept": "application/json",
                "Accept-Language": "en-US,en",
            ])
        }
        let data: Data
        do { data = try await get(key) }
        catch QuotaError.unauthorized { data = try await get("Bearer \(key)") }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaError.parse(L("GLM 用量响应不是 JSON", "GLM usage response is not JSON"))
        }
        // 兼容包裹({data:{...}})与不包裹
        let d = (root["data"] as? [String: Any]) ?? root

        var windows: [UsageWindow] = []
        if let limits = d["limits"] as? [[String: Any]] {
            for lim in limits {
                guard let pct = (lim["percentage"] as? Double) ?? (lim["percentage"] as? Int).map(Double.init) else { continue }
                let type = lim["type"] as? String ?? ""
                let unit = (lim["unit"] as? Int) ?? (lim["unit"] as? Double).map(Int.init) ?? -1
                var resetsAt: Date?
                if let t = (lim["nextResetTime"] as? Double) ?? (lim["nextResetTime"] as? Int).map(Double.init) {
                    resetsAt = Date(timeIntervalSince1970: t / 1000) // 毫秒
                }
                windows.append(UsageWindow(
                    key: "\(type)-\(unit)",
                    title: title(type: type, unit: unit),
                    usedPercent: min(max(pct, 0), 100),
                    resetsAt: resetsAt,
                    isAccountWeekly: type != "TIME_LIMIT" && unit == 6 // unit 6 = 周;TIME_LIMIT 是月度 MCP
                ))
            }
        }
        guard !windows.isEmpty else {
            throw QuotaError.parse(L("GLM 用量里没有识别到额度窗口(接口可能已变)", "No usage windows in GLM response (the endpoint may have changed)"))
        }
        windows.sort { rank($0.key) < rank($1.key) }

        let level = (d["level"] as? String)?.uppercased()
        return UsageSnapshot(windows: windows, planType: level, email: nil, creditsBalance: nil, fetchedAt: Date())
    }

    private static func title(type: String, unit: Int) -> String {
        if type == "TIME_LIMIT" { return L("本月(MCP 工具)", "This month (MCP tools)") }
        switch unit {
        case 3: return L("5 小时窗口", "5-hour window")
        case 6: return L("本周", "This week")
        case 5: return L("本月", "This month")
        default: return L("额度", "Limit")
        }
    }

    private static func rank(_ key: String) -> Int {
        if key.hasPrefix("TIME_LIMIT") { return 3 }
        if key.hasSuffix("-3") { return 0 }
        if key.hasSuffix("-6") { return 1 }
        if key.hasSuffix("-5") { return 2 }
        return 4
    }
}

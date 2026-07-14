import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// 账号凭据的来源。
enum CredentialSource: Codable, Equatable {
    /// 应用内 OAuth 登录,token 存在 QuotaBar 自己的钥匙串条目里
    case managed
    /// 实时读取 Codex CLI 的 auth.json(支持多个 CODEX_HOME);刷新后写回
    case codexAuthFile(path: String)
    /// 实时读取 Claude Code CLI 的凭据:钥匙串 "Claude Code-credentials",或指定 credentials.json 路径
    case claudeCLI(credentialsFilePath: String?)
}

struct Account: Codable, Identifiable, Equatable {
    var id: UUID
    var provider: Provider
    var label: String
    var planType: String?
    var source: CredentialSource
    var addedAt: Date
}

struct UsageWindow: Equatable {
    var key: String
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
}

struct UsageSnapshot: Equatable {
    var windows: [UsageWindow]
    var planType: String?
    var email: String?
    var creditsBalance: String?
    var fetchedAt: Date
}

enum AccountState: Equatable {
    case idle
    case loading
    case loaded(UsageSnapshot)
    case needsReauth(String)
    case error(String)

    var snapshot: UsageSnapshot? {
        if case .loaded(let s) = self { return s }
        return nil
    }
}

enum QuotaError: LocalizedError {
    case http(Int, String)
    case unauthorized
    case missingCredentials(String)
    case parse(String)
    case oauth(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(String(body.prefix(160)))"
        case .unauthorized: return "凭据已失效,需要重新登录"
        case .missingCredentials(let detail): return detail
        case .parse(let detail): return "响应解析失败: \(detail)"
        case .oauth(let detail): return "OAuth 失败: \(detail)"
        }
    }
}

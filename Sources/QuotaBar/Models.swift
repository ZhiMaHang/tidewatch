import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex
    case glm

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .glm: return "GLM"
        }
    }
}

/// 账号凭据的来源。
enum CredentialSource: Codable, Equatable {
    /// 应用内 OAuth 登录,token 存在 Tidewatch 自己的钥匙串条目里
    case managed
    /// 实时读取 Codex CLI 的 auth.json(支持多个 CODEX_HOME);刷新后写回
    case codexAuthFile(path: String)
    /// 实时读取 Claude Code CLI 的凭据:钥匙串 "Claude Code-credentials",或指定 credentials.json 路径
    case claudeCLI(credentialsFilePath: String?)
    /// GLM(z.ai 海外版)API key,存在 Tidewatch 钥匙串,按账号 id 取
    case glmApiKey
}

enum PaymentType: String, Codable, CaseIterable {
    case applePay
    case googlePay
    case creditCard

    var displayName: String {
        switch self {
        case .applePay: return "Apple Pay"
        case .googlePay: return "Google Pay"
        case .creditCard: return L("信用卡", "Credit card")
        }
    }

    var icon: String {
        switch self {
        case .applePay: return "apple.logo"
        case .googlePay: return "g.circle.fill"
        case .creditCard: return "creditcard.fill"
        }
    }

    var fieldPlaceholder: String {
        switch self {
        case .applePay: return L("Apple ID(邮箱)", "Apple ID (email)")
        case .googlePay: return L("Google 邮箱", "Google email")
        case .creditCard: return L("卡号(仅保存后四位)", "Card number (only last 4 stored)")
        }
    }
}

struct PaymentMethod: Codable, Equatable {
    var type: PaymentType
    /// Apple ID / Google 邮箱;信用卡只存后四位(绝不保存完整卡号)
    var detail: String

    var summary: String {
        switch type {
        case .creditCard:
            return detail.isEmpty ? type.displayName : "\(type.displayName) •••• \(detail)"
        default:
            return detail.isEmpty ? type.displayName : "\(type.displayName) · \(detail)"
        }
    }
}

struct Account: Codable, Identifiable, Equatable {
    var id: UUID
    var provider: Provider
    var label: String
    var planType: String?
    var source: CredentialSource
    var addedAt: Date
    /// 用户手填的订阅到期日(主要给 Claude 用——接口拿不到)。可选,老 accounts.json 缺此键解码为 nil
    var manualSubscriptionEndsAt: Date? = nil
    /// 付款方式(Apple Pay/Google Pay/信用卡)。信用卡只存后四位
    var payment: PaymentMethod? = nil
}

struct DesignProject: Identifiable, Equatable {
    var id: String
    var name: String
    var url: String?
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
    /// 订阅到期/续订日(目前仅 Codex 从 id_token 拿得到;Claude 接口不暴露,为 nil)
    var subscriptionEndsAt: Date? = nil
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
        case .unauthorized: return L("凭据已失效,需要重新登录", "Credentials expired, please sign in again")
        case .missingCredentials(let detail): return detail
        case .parse(let detail): return L("响应解析失败: ", "Failed to parse response: ") + detail
        case .oauth(let detail): return L("OAuth 失败: ", "OAuth failed: ") + detail
        }
    }
}

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

struct UsageWindow: Equatable, Codable {
    var key: String
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
    /// 账号级「本周」窗口(非按模型细分)。各 provider 构造时自行判定,
    /// 供周额度类排序取键用(排序键缓存见 UsageStore.cachedSortKeys)
    var isAccountWeekly: Bool = false
}

struct UsageSnapshot: Equatable, Codable {
    var windows: [UsageWindow]
    var planType: String?
    var email: String?
    var creditsBalance: String?
    /// 订阅到期/续订日(目前仅 Codex 从 id_token 拿得到;Claude 接口不暴露,为 nil)
    var subscriptionEndsAt: Date? = nil
    var fetchedAt: Date
}

/// 一次 429 限流的原始现场:响应正文(含 host/Retry-After 前缀,见 HTTP.errorBody)与发生时间。
/// 持久化(见 RateLimitsRepository);记录存在即表示该账号处于「限流粘滞」——
/// 自动刷新对它停摆(重启后依旧),只有手动刷新成功才清除。
struct RateLimitRecord: Codable, Equatable {
    var body: String
    var at: Date
}

/// 旧快照仍在展示时,它「不新鲜」的原因(驱动卡片上不同的标注文案)
enum StaleReason: Equatable {
    /// 最近一次刷新被限流(HTTP 429)。原始响应在 UsageStore.rateLimits 里,卡片可展开查看;
    /// 该账号已退出自动刷新,只能手动刷新
    case rateLimited
    /// 重启后从磁盘恢复的上次数据,首轮刷新还没跑完(中性状态,不是故障)
    case restored
}

enum AccountState: Equatable {
    case idle
    case loading
    case loaded(UsageSnapshot)
    /// 有旧快照可看,但数据不新鲜(原因见 StaleReason):继续展示旧数据,
    /// 卡片如实标注数据时刻与原因,不再静默装作一切正常
    case loadedStale(UsageSnapshot, StaleReason)
    case needsReauth(String)
    case error(String)
    /// 响应解析失败:多半是官方接口改了字段(不是用户的问题),提示看是否有新版
    case apiChanged
    /// 被端点限流(HTTP 429),且没有旧快照可显示。原始响应在 UsageStore.rateLimits;
    /// 该账号已退出自动刷新,只能手动刷新(成功即恢复)
    case rateLimited

    var snapshot: UsageSnapshot? {
        switch self {
        case .loaded(let s), .loadedStale(let s, _): return s
        default: return nil
        }
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

// 本 target 禁止构造 UsageStore、禁止调用任何 *Repository 与 KeychainStore。
// 只测 nonisolated static 纯函数。
//
// 理由不是洁癖:Repository 的路径来自 FileManager 的 applicationSupportDirectory,
// 是 enum + static、没有任何注入点,且改 HOME 也无效(macOS 走 getpwuid)。
// UsageStore.init() 的残留清理会直接 save() 覆写用户真实的
// ~/Library/Application Support/Tidewatch/*.json;removeAccount 还会 KeychainStore.delete。
// 在测试里碰这些等于拿用户的真实凭据做实验。

@testable import Tidewatch
import Foundation

func acct(_ provider: Provider = .claude, _ id: UUID = UUID()) -> Account {
    Account(id: id, provider: provider, label: "", planType: nil, source: .managed, addedAt: Date())
}

/// 构造一份「距 now 还有 expiresIn 秒到期」的凭据;expiresIn 传 nil 表示凭据里没有 expiresAt
func creds(expiresIn: TimeInterval?, now: Date) -> ClaudeCredentials {
    ClaudeCredentials(
        accessToken: "access",
        refreshToken: "refresh",
        expiresAt: expiresIn.map { now.addingTimeInterval($0).timeIntervalSince1970 * 1000 },
        scopes: nil,
        subscriptionType: nil,
        rateLimitTier: nil
    )
}

/// 固定时间基准:所有涉及时刻的用例都以它为原点,不依赖真实当前时间
let T0 = Date(timeIntervalSince1970: 1_800_000_000)

let MINUTE: TimeInterval = 60

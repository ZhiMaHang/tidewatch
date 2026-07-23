@testable import Tidewatch
import Foundation
import Testing

/// 续期三分支决策与提前量取值。边界靠注入 now/lead 钉死,不依赖真实时钟。
@Suite("续期决策")
struct RenewalDecisionTests {

    @Test("离到期还早时直接抓额度,不续期")
    func farFromExpiryProceeds() {
        let c = creds(expiresIn: 120 * MINUTE, now: T0)
        #expect(ClaudeProvider.decide(creds: c, mayRenew: true, lead: 60 * MINUTE, now: T0) == .proceed)
    }

    @Test("进入续期窗口且有名额则续期")
    func dueWithGrantRenews() {
        let c = creds(expiresIn: 40 * MINUTE, now: T0)
        #expect(ClaudeProvider.decide(creds: c, mayRenew: true, lead: 60 * MINUTE, now: T0) == .renew)
    }

    @Test("软到期但没名额:token 还能用,照常抓额度")
    func softDueWithoutGrantProceeds() {
        // 关键分支:让出名额但不牺牲这一轮的数据
        let c = creds(expiresIn: 40 * MINUTE, now: T0)
        #expect(ClaudeProvider.decide(creds: c, mayRenew: false, lead: 60 * MINUTE, now: T0) == .proceed)
    }

    @Test("硬到期又没名额:本轮一个请求都不发")
    func hardExpiredWithoutGrantDefers() {
        let c = creds(expiresIn: -10 * MINUTE, now: T0)
        #expect(ClaudeProvider.decide(creds: c, mayRenew: false, lead: 60 * MINUTE, now: T0) == .deferred)
    }

    @Test("续期窗口边界:恰好等于 lead 不触发,略小于才触发")
    func leadBoundary() {
        let lead: TimeInterval = 60 * MINUTE
        // renewalDue 用的是严格小于
        #expect(ClaudeProvider.decide(creds: creds(expiresIn: lead, now: T0),
                                      mayRenew: true, lead: lead, now: T0) == .proceed)
        #expect(ClaudeProvider.decide(creds: creds(expiresIn: lead - 1, now: T0),
                                      mayRenew: true, lead: lead, now: T0) == .renew)
    }

    /// 锁住 --check 的修正:它无视名额、串行连打所有账号,
    /// 若叠加 30~90 分钟提前量,会在离到期还有 40 分钟时对每个账号各发一次续期——
    /// 正是 2026-07-20 事故的同构形态。lead: 0 让它退回「快到期才续」的旧语义。
    @Test("check 路径 lead 传 0 时退回 isExpired 语义")
    func checkPathWithZeroLead() {
        #expect(ClaudeProvider.decide(creds: creds(expiresIn: 40 * MINUTE, now: T0),
                                      mayRenew: true, lead: 0, now: T0) == .proceed)
        #expect(ClaudeProvider.decide(creds: creds(expiresIn: 30, now: T0),
                                      mayRenew: true, lead: 0, now: T0) == .renew)
    }

    @Test("凭据没有 expiresAt 时永不触发续期")
    func missingExpiryNeverRenews() {
        // CLI 来源的凭据可能缺这个字段,不能让它每轮空续
        let c = creds(expiresIn: nil, now: T0)
        #expect(ClaudeProvider.decide(creds: c, mayRenew: true, lead: 60 * MINUTE, now: T0) == .proceed)
        #expect(ClaudeProvider.decide(creds: c, mayRenew: false, lead: 60 * MINUTE, now: T0) == .proceed)
    }
}

@Suite("提前量取值")
struct RenewLeadTests {

    @Test("提前量落在 [base, base+spread) 区间内")
    func leadWithinRange() {
        for _ in 0..<20_000 {
            let lead = ClaudeProvider.renewLead(for: UUID())
            #expect(lead >= ClaudeProvider.renewLeadBase)
            #expect(lead < ClaudeProvider.renewLeadBase + ClaudeProvider.renewLeadSpread)
        }
    }

    @Test("同一 UUID 的提前量恒定")
    func leadIsStable() {
        // 稳定是提前量有意义的前提:每轮重掷会让续期时刻自己漂移
        let id = UUID()
        let first = ClaudeProvider.renewLead(for: id)
        for _ in 0..<100 { #expect(ClaudeProvider.renewLead(for: id) == first) }
    }

    @Test("不同 UUID 会散开,不是常量函数")
    func leadVaries() {
        let leads = Set((0..<200).map { _ in ClaudeProvider.renewLead(for: UUID()) })
        #expect(leads.count > 150, "200 个 UUID 只产生了 \(leads.count) 个不同提前量")
    }

    /// 常量脆弱性守卫:spread 被改成 0("关掉抖动"是很自然的改法)会让
    /// UInt64(renewLeadSpread) 变成除零崩溃
    @Test("提前量常量必须为正")
    func constantsArePositive() {
        #expect(ClaudeProvider.renewLeadSpread > 0)
        #expect(ClaudeProvider.renewLeadBase > 0)
    }

    /// 把注释里那句「比刷新间隔大得多」变成可执行断言。
    /// 每个账号拿到名额的周期 = 账号数 × 刷新间隔,必须小于它自己的提前量,
    /// 否则会在等名额的过程中硬过期
    @Test("最小提前量至少覆盖若干个刷新轮次")
    func leadCoversSeveralRounds() {
        let defaultInterval: TimeInterval = 5 * MINUTE
        #expect(ClaudeProvider.renewLeadBase >= defaultInterval * 4)
    }
}

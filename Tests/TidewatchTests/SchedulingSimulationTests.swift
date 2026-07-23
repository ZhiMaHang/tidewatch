@testable import Tidewatch
import Foundation
import Testing

/// 零网络的调度模拟:用**真代码**(renewalGrants / decide / renewLead)跑多轮,
/// 度量的是 2026-07-20 事故的直接指标——同一 provider 相邻两次 token 端点请求的间隔。
/// 事故当天这个值是 1.5 秒(4 个账号连发),改动后它应当 ≥ 一个刷新周期。
@Suite("调度模拟")
struct SchedulingSimulationTests {

    struct Result {
        var renewCount: [UUID: Int] = [:]
        /// 每次续期时距原到期还剩多久。≤0 表示「硬过期之后才续上」,期间没数可看
        var margins: [TimeInterval] = []
        /// 所有 token 端点请求的时刻(秒),用于算相邻间隔
        var renewTimes: [TimeInterval] = []
        var maxConsecutiveDeferred: [UUID: Int] = [:]
        var maxGrantsInOneRound = 0

        var minRenewGap: TimeInterval? {
            let sorted = renewTimes.sorted()
            guard sorted.count > 1 else { return nil }
            return (1..<sorted.count).map { sorted[$0] - sorted[$0 - 1] }.min()
        }
        var minMargin: TimeInterval? { margins.min() }
    }

    /// 严格照抄 refreshAll 的时序:分组 → 发名额 → 组内串行 + 1.5s 错峰。
    /// tokenLifetime 是**假设值**——真实 TTL 全仓没有任何地方记录过(见 ClaudeProvider 注释),
    /// 拿到实测值前它是这个模拟里唯一的猜测
    func simulate(accountCount: Int, interval: TimeInterval, rounds: Int,
                  tokenLifetime: TimeInterval = 8 * 3600,
                  initialExpiry: TimeInterval,
                  skippedProvider: ((Int) -> Set<UUID>)? = nil,
                  verbose: Bool = false) -> Result {
        // 用确定性 UUID,保证用例可复现
        let accounts = (0..<accountCount).map { i -> Account in
            acct(.claude, UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))!)
        }
        var expiry = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, initialExpiry) })
        var lastGrant: [UUID: UInt64] = [:]
        var deferStreak: [UUID: Int] = [:]
        var r = Result()

        for round in 0..<rounds {
            let t = TimeInterval(round) * interval
            let now = T0.addingTimeInterval(t)
            let skipped = skippedProvider?(round) ?? []
            let grants = UsageStore.renewalGrants(
                byProvider: [.claude: accounts], skipped: skipped, force: false,
                round: UInt64(round + 1), lastGrantRound: &lastGrant)
            r.maxGrantsInOneRound = max(r.maxGrantsInOneRound, grants.count)

            var line = ""
            let active = accounts.filter { !skipped.contains($0.id) }
            for (i, a) in active.enumerated() {
                let at = t + Double(i) * 1.5              // 组内 1.5s 错峰
                let atDate = T0.addingTimeInterval(at)
                let c = creds(expiresIn: expiry[a.id]! - at, now: atDate)
                let decision = ClaudeProvider.decide(
                    creds: c, mayRenew: grants.contains(a.id),
                    lead: ClaudeProvider.renewLead(for: a.id), now: atDate)
                let tag = a.id.uuidString.suffix(2)
                switch decision {
                case .renew:
                    r.margins.append(expiry[a.id]! - at)   // 距原到期还剩多久
                    r.renewTimes.append(at)
                    expiry[a.id] = at + tokenLifetime
                    r.renewCount[a.id, default: 0] += 1
                    deferStreak[a.id] = 0
                    line += " renew=\(tag)"
                case .deferred:
                    deferStreak[a.id, default: 0] += 1
                    r.maxConsecutiveDeferred[a.id] = max(r.maxConsecutiveDeferred[a.id] ?? 0, deferStreak[a.id]!)
                    line += " defer=\(tag)"
                case .proceed:
                    deferStreak[a.id] = 0
                }
            }
            if verbose, !line.isEmpty {
                print(String(format: "r=%03d t=%6.1fmin%@", round, t / 60, line))
            }
        }
        return r
    }

    @Test("稳态:同批铸造的 4 个账号,单轮永不并发续期")
    func steadyStateNoBurst() {
        let interval: TimeInterval = 5 * MINUTE
        let r = simulate(accountCount: 4, interval: interval, rounds: 500,
                         initialExpiry: 8 * 3600)
        #expect(r.maxGrantsInOneRound == 1, "单轮名额数应恒为 1,实际 \(r.maxGrantsInOneRound)")
        // 事故当天这个值是 1.5 秒;现在它至少是一个刷新周期
        #expect((r.minRenewGap ?? .infinity) >= interval,
                "相邻续期间隔 \(((r.minRenewGap ?? 0) / 60)) 分钟,应 ≥ \(interval / 60) 分钟")
        #expect((r.minMargin ?? 0) > 0, "有账号在硬过期之后才续上(裕量 \((r.minMargin ?? 0) / 60) 分钟)")
    }

    @Test("冷启动:App 关很久再开,全部 token 已过期时也不并发")
    func coldStartStaggers() {
        let interval: TimeInterval = 5 * MINUTE
        // 起点即全部硬过期——提前量在这个场景完全失效,只剩名额兜底
        let r = simulate(accountCount: 4, interval: interval, rounds: 20,
                         initialExpiry: -3600)
        #expect(r.maxGrantsInOneRound == 1)
        #expect((r.minRenewGap ?? .infinity) >= interval)
        // 4 个账号应在前 4 轮里依次恢复
        #expect(r.renewCount.count == 4, "20 轮内 4 个账号都应至少续期一次")
    }

    /// 反向断言:把已知限制钉成可执行文档。
    /// 每个账号拿到名额的周期 = 账号数 × 刷新间隔,必须小于它自己的提前量(下限 30 分钟),
    /// 否则会在排队等名额的过程中硬过期。4 账号 × 15 分钟 = 60 > 30,必然越界。
    @Test("已知限制:账号数 × 刷新间隔超过最小提前量时会硬过期")
    func documentedLimitAtLargeInterval() {
        let r = simulate(accountCount: 4, interval: 15 * MINUTE, rounds: 200,
                         initialExpiry: 8 * 3600)
        #expect((r.minMargin ?? 1) <= 0,
                "这个组合本应触发硬过期;若这条变绿,说明提前量或名额策略改了,请同步更新限制说明")
        // 但即便越界,也绝不能退化成并发突发——那才是事故形态
        #expect(r.maxGrantsInOneRound == 1)
    }

    @Test("集合抖动:账号进出粘滞时无人被饿死")
    func churnNoStarvation() {
        let ids = (0..<4).map { i in UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))! }
        let r = simulate(accountCount: 4, interval: 5 * MINUTE, rounds: 400,
                         initialExpiry: 8 * 3600,
                         skippedProvider: { round in round % 2 == 0 ? Set([ids[2], ids[3]]) : [] })
        for id in ids {
            #expect(r.renewCount[id, default: 0] > 0, "账号 \(id.uuidString.suffix(2)) 从未续期")
        }
        #expect(r.maxGrantsInOneRound == 1)
    }
}

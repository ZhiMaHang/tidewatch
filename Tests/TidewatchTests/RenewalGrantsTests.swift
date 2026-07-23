@testable import Tidewatch
import Foundation
import Testing

/// 续期名额发放:每轮每 provider 恰好一个,且长期公平(谁都不能被饿死)。
/// 名额是这次改动的**硬保证**——提前量只是软化器,真正拦住突发的是这里。
@Suite("续期名额发放")
struct RenewalGrantsTests {

    @Test("每轮每个 provider 只发一个名额")
    func oneGrantPerProvider() {
        let accounts = (0..<4).map { _ in acct(.claude) }
        var lastGrant: [UUID: UInt64] = [:]
        let grants = UsageStore.renewalGrants(
            byProvider: [.claude: accounts], skipped: [], force: false, round: 1, lastGrantRound: &lastGrant)
        #expect(grants.count == 1)
    }

    @Test("多个 provider 同轮各发一个,互不挤占")
    func perProviderIndependent() {
        let claude = (0..<3).map { _ in acct(.claude) }
        let codex = (0..<2).map { _ in acct(.codex) }
        var lastGrant: [UUID: UInt64] = [:]
        let grants = UsageStore.renewalGrants(
            byProvider: [.claude: claude, .codex: codex], skipped: [], force: false, round: 1, lastGrantRound: &lastGrant)
        #expect(grants.count == 2)
        #expect(claude.filter { grants.contains($0.id) }.count == 1)
        #expect(codex.filter { grants.contains($0.id) }.count == 1)
    }

    @Test("GLM 不参与名额发放")
    func glmTakesNoGrant() {
        // GLM 是纯 API key,没有 OAuth 续期路径(GLMProvider.fetchUsage 根本不接 mayRenew)。
        // 给它发名额是白白空转一个轮转位
        let claude = [acct(.claude)]
        let glm = (0..<2).map { _ in acct(.glm) }
        var lastGrant: [UUID: UInt64] = [:]
        let grants = UsageStore.renewalGrants(
            byProvider: [.claude: claude, .glm: glm], skipped: [], force: false, round: 1, lastGrantRound: &lastGrant)
        #expect(glm.allSatisfy { !grants.contains($0.id) })
        #expect(glm.allSatisfy { lastGrant[$0.id] == nil })
    }

    @Test("force 无视粘滞与待重登,仍只发一个")
    func forceIgnoresSkipped() {
        let accounts = (0..<4).map { _ in acct(.claude) }
        var lastGrant: [UUID: UInt64] = [:]
        let grants = UsageStore.renewalGrants(
            byProvider: [.claude: accounts],
            skipped: Set(accounts.map(\.id)), force: true, round: 1, lastGrantRound: &lastGrant)
        #expect(grants.count == 1)
    }

    @Test("非 force 且全员被跳过时,不发名额也不消耗轮转状态")
    func emptyRoundDoesNotAdvance() {
        let accounts = (0..<3).map { _ in acct(.claude) }
        var lastGrant: [UUID: UInt64] = [:]
        let grants = UsageStore.renewalGrants(
            byProvider: [.claude: accounts],
            skipped: Set(accounts.map(\.id)), force: false, round: 1, lastGrantRound: &lastGrant)
        #expect(grants.isEmpty)
        // 空轮不能留下任何轮转痕迹,否则粘滞期间轮转会空转、解粘后顺序错乱
        #expect(lastGrant.isEmpty)
    }

    @Test("空输入不崩")
    func emptyInputs() {
        var lastGrant: [UUID: UInt64] = [:]
        #expect(UsageStore.renewalGrants(byProvider: [:], skipped: [], force: false, round: 1, lastGrantRound: &lastGrant).isEmpty)
        #expect(UsageStore.renewalGrants(byProvider: [.claude: []], skipped: [], force: false, round: 1, lastGrantRound: &lastGrant).isEmpty)
    }

    @Test("连续 N 轮恰好覆盖全部账号")
    func rotationCoversAll() {
        let accounts = (0..<3).map { _ in acct(.claude) }
        var lastGrant: [UUID: UInt64] = [:]
        var picked: [UUID] = []
        for round in 1...3 {
            let g = UsageStore.renewalGrants(
                byProvider: [.claude: accounts], skipped: [], force: false,
                round: UInt64(round), lastGrantRound: &lastGrant)
            picked.append(contentsOf: g)
        }
        #expect(Set(picked).count == 3, "三轮应覆盖三个不同账号,实际 \(Set(picked).count) 个")
    }

    /// 验收门:eligible 集合大小在轮次之间变化(账号进出粘滞)时,不能有人被系统性饿死。
    /// 下标游标对**变长**的表取模不是轮转——它会稳定跳过某些下标。
    @Test("eligible 集合来回变化时无人被饿死")
    func noStarvationUnderChurn() {
        let accounts = (0..<4).map { _ in acct(.claude) }
        let sometimesSkipped = Set([accounts[2].id, accounts[3].id])
        var lastGrant: [UUID: UInt64] = [:]
        var count: [UUID: Int] = [:]
        for round in 0..<1000 {
            // 偶数轮只有 A/B 可用,奇数轮四个都可用
            let skipped = round % 2 == 0 ? sometimesSkipped : []
            let g = UsageStore.renewalGrants(
                byProvider: [.claude: accounts], skipped: skipped, force: false,
                round: UInt64(round + 1), lastGrantRound: &lastGrant)
            for id in g { count[id, default: 0] += 1 }
        }
        for a in accounts {
            #expect(count[a.id, default: 0] > 0,
                    "账号 \(a.id.uuidString.prefix(8)) 在 1000 轮里一次名额都没拿到")
        }
    }

    @Test("间歇粘滞的账号解粘后应尽快拿到名额")
    func returningAccountGetsGrantSoon() {
        let accounts = (0..<3).map { _ in acct(.claude) }
        let latecomer = accounts[2]
        var lastGrant: [UUID: UInt64] = [:]
        for round in 1...10 {
            _ = UsageStore.renewalGrants(byProvider: [.claude: accounts],
                                         skipped: [latecomer.id], force: false,
                                         round: UInt64(round), lastGrantRound: &lastGrant)
        }
        // 解粘后,最久未拿名额的应当是它
        var seen = false
        for round in 11...13 {
            let g = UsageStore.renewalGrants(byProvider: [.claude: accounts],
                                             skipped: [], force: false,
                                             round: UInt64(round), lastGrantRound: &lastGrant)
            if g.contains(latecomer.id) { seen = true; break }
        }
        #expect(seen, "解粘后 3 轮内应至少拿到一次名额")
    }
}

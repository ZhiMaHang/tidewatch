@testable import Tidewatch
import Foundation
import Testing

/// renewalDeferred 的展示态映射。这是「限量生效」的用户可见面,
/// 映射错了会让用户以为应用坏了(永久转圈)或以为限流已解除(误导)。
@Suite("待续期状态映射")
struct DeferredStateTests {

    private func snapshot() -> UsageSnapshot {
        UsageSnapshot(windows: [], planType: nil, email: nil, creditsBalance: nil, fetchedAt: T0)
    }

    @Test("有旧快照且未粘滞:展示旧数据并标注待续期")
    func staleWithRenewalDeferred() {
        let snap = snapshot()
        let s = UsageStore.stateAfterRenewalDeferred(previous: .loaded(snap), throttled: false)
        #expect(s == .loadedStale(snap, .renewalDeferred))
    }

    @Test("有旧快照且仍粘滞:必须继续标限流,不能标待续期")
    func stickyKeepsRateLimitedReason() {
        // 粘滞的主导事实是「不会自动恢复,只有手动刷新成功才解除」。
        // 标成「待续期」会误导成「下一轮自动就好」
        let snap = snapshot()
        let s = UsageStore.stateAfterRenewalDeferred(previous: .loaded(snap), throttled: true)
        #expect(s == .loadedStale(snap, .rateLimited))
    }

    @Test("无快照但仍粘滞:落限流态")
    func stickyWithoutSnapshot() {
        #expect(UsageStore.stateAfterRenewalDeferred(previous: nil, throttled: true) == .rateLimited)
    }

    /// 无快照且未粘滞时绝不能返回 .loading:
    /// 卡片会永久转圈,而且 hasProblem 不认 .loading,菜单栏的告警标记也会一起消失——
    /// 一个本该「本轮没刷」的中性情况,表现成了「应用卡住且无人告警」
    @Test("无快照且未粘滞时不得停在 loading")
    func neverStuckOnLoading() {
        let s = UsageStore.stateAfterRenewalDeferred(previous: nil, throttled: false)
        #expect(s != .loading)
    }

    @Test("无快照时保留原有诊断态,不被待续期盖掉")
    func preservesDiagnosticStates() {
        // .apiChanged 是「接口变了」的诊断,比「本轮没轮到名额」重要得多,不该被覆盖
        #expect(UsageStore.stateAfterRenewalDeferred(previous: .apiChanged, throttled: false) == .apiChanged)
        let reauth = AccountState.needsReauth("x")
        #expect(UsageStore.stateAfterRenewalDeferred(previous: reauth, throttled: false) == reauth)
    }
}

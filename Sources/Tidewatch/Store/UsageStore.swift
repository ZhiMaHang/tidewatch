import Foundation
import Observation

/// 账号列表排序模式(rawValue 持久化到 UserDefaults)。
/// 旧模式 added/resetTime 已删除,init 恢复时旧值一律迁移为 .subscriptionEnd。
enum AccountSortMode: String, CaseIterable {
    /// 默认:按订阅到期时间升序——到期最早的排第一(最紧迫的续费在最上)。
    /// 键来源优先级:用户手填 manualSubscriptionEndsAt 优先;否则用快照的
    /// subscriptionEndsAt(目前只有 Codex 能从 id_token 拿到;Claude/GLM 为 nil)。
    /// 两处都无键则沉底。
    case subscriptionEnd
    /// 按周额度重置时间升序——最早重置的排第一。
    /// 键 = 账号级周窗(UsageWindow.isAccountWeekly)的 resetsAt;无周窗/无快照沉底。
    case weeklyReset
    /// 按周额度已用百分比升序——用得最少的排第一。
    /// 键 = 账号级周窗的 usedPercent;无周窗/无快照沉底。
    case weeklyUsed
}

@MainActor
@Observable
final class UsageStore {
    var accounts: [Account] = []
    var states: [UUID: AccountState] = [:]
    /// 每个 Claude 账号的 Claude Design 项目列表(有 design 登录才有)
    var designProjects: [UUID: [DesignProject]] = [:]
    /// 项目 id → Tidewatch 首次发现该项目的时间(接口不返回真实时间,这是替代;持久化)
    var designFirstSeen: [String: Date] = [:]
    var lastRefreshAt: Date?
    /// 「添加账号」窗口当前要添加的提供方(nil = 窗口空置)。不持久化,仅驱动独立窗口
    var pendingAddProvider: Provider?
    var refreshIntervalMinutes: Int {
        didSet {
            guard refreshIntervalMinutes != oldValue else { return }
            UserDefaults.standard.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes")
            restartLoop()
        }
    }
    var accountSortMode: AccountSortMode {
        didSet {
            guard accountSortMode != oldValue else { return }
            UserDefaults.standard.set(accountSortMode.rawValue, forKey: "accountSortMode")
        }
    }

    /// 各账号末次成功快照里的排序键(可扩展:后续排序模式往里加字段即可)。
    struct CachedSortKeys {
        /// 快照的订阅到期日(目前仅 Codex 有)
        var subscriptionEndsAt: Date?
        /// 账号级周窗(UsageWindow.isAccountWeekly)的重置时间
        var weeklyResetsAt: Date?
        /// 账号级周窗的已用百分比
        var weeklyUsedPercent: Double?

        /// 从一份成功快照整体重建全部排序键。
        /// 账号级周窗设计上每账号至多一个;这里对意外出现多个的情况做防御:
        /// resetsAt 取最早、usedPercent 取最大(各取最保守的一侧)。
        init(snapshot: UsageSnapshot) {
            subscriptionEndsAt = snapshot.subscriptionEndsAt
            let weekly = snapshot.windows.filter(\.isAccountWeekly)
            weeklyResetsAt = weekly.compactMap(\.resetsAt).min()
            weeklyUsedPercent = weekly.map(\.usedPercent).max()
        }
    }

    /// 排序键缓存,与展示态解耦:刷新瞬时失败会覆盖 states 丢掉快照(卡片要如实显示
    /// 错误态),若排序键跟着消失,账号会在面板开着时沉底、下轮成功再跳回;
    /// 用末次成功快照的键钉住位置。markLoaded 落快照时同步,removeAccount 清理。
    private var cachedSortKeys: [UUID: CachedSortKeys] = [:]

    /// 面板列表的实际展示顺序。读了 accounts/states/accountSortMode/cachedSortKeys 四个可观察属性,
    /// 快照刷新(states 变化)后 @Observable 会驱动列表自动重排。
    var sortedAccounts: [Account] {
        // 现值优先:有快照就按当前快照现算排序键;刷新瞬时失败(快照被错误态覆盖)期间
        // 由 cachedSortKeys 兜底为末次成功值,钉住位置不跳动。
        func liveOrCachedKeys(_ id: UUID) -> CachedSortKeys? {
            if let snapshot = states[id]?.snapshot { return CachedSortKeys(snapshot: snapshot) }
            return cachedSortKeys[id]
        }
        switch accountSortMode {
        case .subscriptionEnd:
            // 键优先级:手填 manualSubscriptionEndsAt > 快照 subscriptionEndsAt(仅 Codex 的快照有此值)
            var keys: [UUID: Date] = [:]
            for account in accounts {
                if let d = account.manualSubscriptionEndsAt
                    ?? liveOrCachedKeys(account.id)?.subscriptionEndsAt {
                    keys[account.id] = d
                }
            }
            // 升序:到期最早的排第一(最紧迫的续费在最上)
            return Self.stableSorted(accounts, keys: keys, ascending: true)
        case .weeklyReset:
            // 键 = 账号级周窗 resetsAt;升序:最早重置的排第一
            var keys: [UUID: Date] = [:]
            for account in accounts {
                if let d = liveOrCachedKeys(account.id)?.weeklyResetsAt {
                    keys[account.id] = d
                }
            }
            return Self.stableSorted(accounts, keys: keys, ascending: true)
        case .weeklyUsed:
            // 键 = 账号级周窗 usedPercent;升序:用得最少的排第一
            var keys: [UUID: Double] = [:]
            for account in accounts {
                if let p = liveOrCachedKeys(account.id)?.weeklyUsedPercent {
                    keys[account.id] = p
                }
            }
            return Self.stableSorted(accounts, keys: keys, ascending: true)
        }
    }

    /// 通用稳定排序:按给定键排(ascending=true 升序/false 降序);
    /// 无键沉底;同键及无键之间保持传入顺序(稳定)。
    /// 纯函数(nonisolated + 显式传键),便于脱离 MainActor 单测。
    nonisolated static func stableSorted<Key: Comparable>(_ accounts: [Account], keys: [UUID: Key], ascending: Bool) -> [Account] {
        accounts.enumerated().sorted { a, b in
            switch (keys[a.element.id], keys[b.element.id]) {
            case let (l?, r?):
                if l == r { return a.offset < b.offset }
                return ascending ? l < r : l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// 手动「立即检查更新」的瞬时反馈(自动回路不用它)
    enum ManualCheck: Equatable { case idle, checking, upToDate(String), failed }
    var manualCheck: ManualCheck = .idle

    /// 有更新且未被用户忽略时非 nil,驱动面板顶部那条克制的「有新版」横幅
    var updateInfo: UpdateInfo?
    /// 匿名版本检查开关(隐私红线:可关)。默认开;关闭立即撤掉横幅并停掉 ping
    var updateCheckEnabled: Bool {
        didSet {
            guard updateCheckEnabled != oldValue else { return }
            UserDefaults.standard.set(updateCheckEnabled, forKey: Keys.updateCheckEnabled)
            if updateCheckEnabled { startUpdateChecks() } else { stopUpdateChecks() }
        }
    }

    private enum Keys {
        static let updateCheckEnabled = "updateCheckEnabled"
        static let skippedUpdateVersion = "skippedUpdateVersion"
    }
    /// 每天查一次:够做「周活版本分布」度量,又不会 phone-home 刷屏
    private let updateCheckInterval: TimeInterval = 24 * 60 * 60

    private var refreshLoop: Task<Void, Never>?
    private var updateLoop: Task<Void, Never>?
    /// 在飞的刷新任务,连同它当时是否持有续期名额(见 refresh 里的去重分支)
    private var inFlight: [UUID: (task: Task<Void, Never>, mayRenew: Bool)] = [:]
    /// 轮次序号(每次 refreshAll 自增一次)与「各账号上次拿到续期名额的轮次」(缺省 0 = 从未)。
    /// 不持久化:重启后归零,于是重启后第一个名额恒定发给 accounts.json 里的第一个 Claude 账号。
    /// 可接受(重启不频繁),而且正因为可预测,真机验证时能事先预言受益者是谁
    private var roundCounter: UInt64 = 0
    private var lastGrantRound: [UUID: UInt64] = [:]
    /// 限流粘滞:账号 → 最近一次 429 的原始现场(响应正文 + 时间),持久化(见 RateLimitsRepository)。
    /// 记录存在即该账号退出自动刷新回路(重启后依旧),卡片可展开查看原始响应;
    /// 只有手动刷新**成功**才清除(见 clearRateLimit)。不做退避、不做熔断、不自动恢复——
    /// 何时再撞端点完全由用户决定(429 惩罚期内自动重试只会喂养惩罚,不如把现场留给人判断)。
    var rateLimits: [UUID: RateLimitRecord] = [:]
    /// 是否有 design 凭据的缓存(nil=未判定),避免每轮刷新做钥匙串读
    private var designAvailable: [UUID: Bool] = [:]
    /// 磁盘上的「各账号最后一次成功快照」的内存镜像。只在刷新成功与移除账号时变更,
    /// **不从展示态 states 派生**——states 会被瞬时错误覆盖,从它重建会把最后成功数据抹掉
    private var diskSnapshots: [UUID: UsageSnapshot] = [:]

    init() {
        let stored = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
        refreshIntervalMinutes = stored >= 3 ? stored : 5
        // 迁移:旧值 "added"/"resetTime"/缺失/未知一律落到新默认 .subscriptionEnd(不回写,
        // didSet 的持久化机制照旧,用户下次切换才写)。
        accountSortMode = UserDefaults.standard.string(forKey: "accountSortMode")
            .flatMap(AccountSortMode.init(rawValue:)) ?? .subscriptionEnd
        // 默认开:老用户/首启时该 key 不存在(nil)也视为开。didSet 在 init 内不触发,不会提前启动 loop。
        updateCheckEnabled = UserDefaults.standard.object(forKey: Keys.updateCheckEnabled) as? Bool ?? true
        accounts = AccountsRepository.load()
        // 重启后先亮出上次成功的快照(中性标注「上次数据」,不是限流告警),等首轮刷新覆盖;
        // 若首轮就被限流,用户至少还有上次的数字可看,而不是一排空卡片
        diskSnapshots = SnapshotsRepository.load()
        // 限流粘滞跨重启:上次退出前吃过 429 的账号,重启后继续停在限流态、不进自动回路
        // (否则重启就成了变相的自动重试),原始响应照旧可查看
        rateLimits = RateLimitsRepository.load()
        for account in accounts {
            if let snap = diskSnapshots[account.id] {
                states[account.id] = rateLimits[account.id] != nil
                    ? .loadedStale(snap, .rateLimited)
                    : .loadedStale(snap, .restored)
                cachedSortKeys[account.id] = CachedSortKeys(snapshot: snap)
            } else if rateLimits[account.id] != nil {
                states[account.id] = .rateLimited
            }
        }
        // 磁盘里可能残留已移除账号的条目(如移除时写盘失败/在飞任务复活),清掉并回写
        let ids = Set(accounts.map(\.id))
        let pruned = diskSnapshots.filter { ids.contains($0.key) }
        if pruned.count != diskSnapshots.count {
            diskSnapshots = pruned
            SnapshotsRepository.save(diskSnapshots)
        }
        let prunedRL = rateLimits.filter { ids.contains($0.key) }
        if prunedRL.count != rateLimits.count {
            rateLimits = prunedRL
            RateLimitsRepository.save(rateLimits)
        }
        if let data = UserDefaults.standard.data(forKey: "designFirstSeen"),
           let d = try? JSONDecoder().decode([String: Date].self, from: data) {
            designFirstSeen = d
        }
    }

    private func recordFirstSeen(_ projects: [DesignProject]) {
        var changed = false
        for p in projects where designFirstSeen[p.id] == nil {
            designFirstSeen[p.id] = Date()
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(designFirstSeen) {
            UserDefaults.standard.set(data, forKey: "designFirstSeen")
        }
    }

    func start(immediate: Bool = true) {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            if immediate { await self?.refreshAll() }
            while !Task.isCancelled {
                let minutes = self?.refreshIntervalMinutes ?? 5
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled else { break }
                await self?.refreshAll()
            }
        }
        // 版本检查独立于额度刷新回路(不同频率、失败互不影响)
        startUpdateChecks()
    }

    private func restartLoop() {
        guard refreshLoop != nil else { return }
        refreshLoop?.cancel()
        refreshLoop = nil
        start(immediate: false)
    }

    // MARK: 匿名版本检查(仅版本号)

    /// 启动即查一次,之后每天一次;全程静默,只有查到更严格新版且未被忽略时才亮横幅。
    func startUpdateChecks() {
        guard updateCheckEnabled, updateLoop == nil else { return }
        updateLoop = Task { [weak self] in
            await self?.checkForUpdate()
            while !Task.isCancelled {
                let interval = self?.updateCheckInterval ?? 86_400
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.checkForUpdate()
            }
        }
    }

    private func stopUpdateChecks() {
        updateLoop?.cancel()
        updateLoop = nil
        updateInfo = nil // 关掉即撤横幅
    }

    /// 拉一次 latest.json;忽略过的版本不再打扰(但 GET 照发,计数不受影响)。
    func checkForUpdate() async {
        guard updateCheckEnabled else { return }
        let info = await UpdateChecker.fetchIfNewer()
        let skipped = UserDefaults.standard.string(forKey: Keys.skippedUpdateVersion)
        updateInfo = (info?.latest == skipped) ? nil : info
    }

    /// 「忽略此版本」:记住这个版本号,之后不再为它亮横幅(有更新的版本仍会提示)。
    func skipUpdate() {
        if let v = updateInfo?.latest {
            UserDefaults.standard.set(v, forKey: Keys.skippedUpdateVersion)
        }
        updateInfo = nil
    }

    /// 手动「立即检查更新」:无视开关与「忽略此版本」(用户明确要查),给出明确反馈。
    /// 有新版→亮横幅;已是最新/失败→顶部短暂提示 3 秒后自动消失。
    func checkForUpdatesNow() async {
        manualCheck = .checking
        switch await UpdateChecker.checkNow() {
        case .newer(let info):
            UserDefaults.standard.removeObject(forKey: Keys.skippedUpdateVersion) // 手动查:清掉「忽略」,确保横幅出
            updateInfo = info
            manualCheck = .idle // 结果用横幅呈现
            return
        case .upToDate(let v):
            updateInfo = nil
            manualCheck = .upToDate(v)
        case .failed:
            manualCheck = .failed
        }
        try? await Task.sleep(for: .seconds(3))
        switch manualCheck { case .upToDate, .failed: manualCheck = .idle; default: break }
    }

    // MARK: 刷新

    func refreshAll(force: Bool = false) async {
        // 同一 provider 的账号共用同一 host + 同一 client_id(Claude 尤甚:所有账号都用 Claude Code 的
        // client_id),并发请求会触发端点按 IP/client 的突发限流(429,多个账号一起挂)。所以:
        // 同 provider 内串行 + 相邻请求错开一点;不同 provider 之间仍并发(不同 host,互不影响)。
        // 某账号吃到 429 不影响本轮其余账号:各自请求、各自留现场、各自进粘滞。
        let byProvider = Dictionary(grouping: accounts, by: { $0.provider })
        let grants = grantRenewals(byProvider: byProvider, force: force)
        await withTaskGroup(of: Void.self) { group in
            for (_, providerAccounts) in byProvider {
                group.addTask { [weak self] in
                    for (i, account) in providerAccounts.enumerated() {
                        // 同 provider 相邻请求错开 1.5s:多账号共用同一 client_id/IP,连续快打会踩端点短窗口限流。
                        if i > 0 { try? await Task.sleep(for: .milliseconds(1500)) }
                        // 回路被取消(如改刷新间隔触发 restartLoop)时上面的 sleep 立即返回,
                        // 错峰就没了——直接停掉本轮剩余账号,别退化成背靠背连击
                        if Task.isCancelled { break }
                        await self?.refresh(account, force: force, mayRenew: grants.contains(account.id))
                    }
                }
            }
        }
        lastRefreshAt = Date()
    }

    /// 每轮每个 provider 只发放**一个**续期名额,在本轮真会去刷新的账号里轮转发放。
    ///
    /// 抓额度和续期是两件不同的事,代价差着量级:抓额度打 usage 端点,便宜,失败也只是这一次没数;
    /// 续期打 token 端点,而那个桶和本机每一个 Claude Code 会话共用,一旦打进限流所有账号一起冻
    /// (2026-07-20:4 个账号同批到期,4 次刷新挤在 5 秒内连发,全部 429,冻了一天半)。
    /// 所以抓额度可以每轮全量,续期必须限量。
    ///
    /// 名额轮转与 ClaudeProvider.renewLead 的错开提前量是两道独立的保险,缺一不可:
    /// 提前量负责让「同批铸造的 token」在正常运行时自然错开续期时刻;名额负责兜住提前量
    /// 失效的情形——App 关了几小时再打开,一上来所有 token 都已过期,提前量此时一点用没有。
    /// 名额发放的纯逻辑。抽成 nonisolated static + 显式传入跳过集合与轮转状态,
    /// 是为了能脱离 MainActor 与磁盘/钥匙串直接单测(测试禁止构造 UsageStore)。
    nonisolated static func renewalGrants(
        byProvider: [Provider: [Account]],
        skipped: Set<UUID>,
        force: Bool,
        round: UInt64,
        lastGrantRound: inout [UUID: UInt64]
    ) -> Set<UUID> {
        var grants: Set<UUID> = []
        for (provider, providerAccounts) in byProvider {
            // GLM 是纯 API key,没有 OAuth 续期路径(GLMProvider.fetchUsage 根本不接 mayRenew),
            // 给它发名额只是白白空转一个轮转位
            guard provider != .glm else { continue }
            // 只在本轮真会去刷新的账号里发:名额落到被跳过的账号(粘滞/待重登)上就白白浪费一轮
            let eligible = force ? providerAccounts : providerAccounts.filter { !skipped.contains($0.id) }
            guard !eligible.isEmpty else { continue }
            // 最久未拿到名额者优先;并列(含全部从未拿过)时 min 取首个,顺序可预测。
            //
            // 别退回「下标游标取模」:eligible 集合在轮次之间会变长变短(账号进出粘滞、
            // force 与非 force 交替),对一张长度会变的表取模**不是轮转**——它会稳定跳过
            // 某些下标,把账号永久饿死。测试实证过:4 账号集合在 2/4 之间交替,
            // 1000 轮里有账号一次名额都拿不到。LRG 则有界:N 个持续 eligible 的账号
            // 任何一个最多等 N 轮
            let picked = eligible.min { (lastGrantRound[$0.id] ?? 0) < (lastGrantRound[$1.id] ?? 0) }!
            grants.insert(picked.id)
            lastGrantRound[picked.id] = round
        }
        return grants
    }

    private func grantRenewals(byProvider: [Provider: [Account]], force: Bool) -> Set<UUID> {
        roundCounter &+= 1
        let skipped = Set(accounts.filter { rateLimits[$0.id] != nil || isNeedsReauth($0.id) }.map(\.id))
        return Self.renewalGrants(byProvider: byProvider, skipped: skipped, force: force,
                                  round: roundCounter, lastGrantRound: &lastGrantRound)
    }

    /// renewalDeferred 的状态映射。纯函数,`previous` 是 performRefresh 置 .loading **之前**的状态。
    nonisolated static func stateAfterRenewalDeferred(previous: AccountState?, throttled: Bool) -> AccountState {
        if let snap = previous?.snapshot {
            // 粘滞账号的主导事实是「不会自动恢复」,标成待续期会误导成「下轮自动就好」
            return .loadedStale(snap, throttled ? .rateLimited : .renewalDeferred)
        }
        if throttled { return .rateLimited }
        switch previous {
        case .apiChanged, .error, .needsReauth:
            // 无快照时保留原有诊断:接口变更/待重登比「本轮没轮到名额」重要得多,别被盖掉
            return previous!
        default:
            // 绝不能返回 .loading:卡片会永久转圈,而且 hasProblem 不认 .loading,
            // 菜单栏告警也会一起消失——本该中性的「本轮没刷」表现成「卡住且无人告警」
            return .error(L("等待续期名额,本轮未刷新", "Waiting for a renewal slot; not refreshed this round"))
        }
    }

    private func isNeedsReauth(_ id: UUID) -> Bool {
        if case .needsReauth = states[id] ?? .idle { return true }
        return false
    }

    /// force=false 时跳过两类账号:已标记需重登的(避免每轮空刷 invalid_grant),
    /// 与限流粘滞的(上次吃过 429,见 rateLimits——只能手动刷新,自动回路不碰)。
    /// 同一账号只允许一个进行中的刷新,重复触发直接等已有任务。
    /// `mayRenew` 默认 true:单卡手动刷新、新增账号这类用户直接发起的单账号操作
    /// 不受名额约束(只有一个账号,不构成突发);只有 refreshAll 的批量轮次才发名额。
    func refresh(_ account: Account, force: Bool = false, mayRenew: Bool = true) async {
        if let existing = inFlight[account.id] {
            await existing.task.value
            // 在飞那次没有续期名额而这次有(典型:自动轮次正跑着,用户点了手动刷新),
            // 就不能跟着它一起返回——否则用户点了刷新却一个请求都没发出去,
            // 「待续期」账号唯一的即时恢复通道被静默吞掉
            if !(mayRenew && !existing.mayRenew) { return }
        }
        if !force {
            if case .needsReauth = states[account.id] ?? .idle { return }
            if rateLimits[account.id] != nil { return }
        }
        let task = Task {
            await self.performRefresh(account, mayRenew: mayRenew)
            // 完成即清,不等创建者的 continuation 恢复:那一跳间隙里进来的手动刷新
            // 会命中上面的 dedup 分支、await 一个已完成的任务然后静默返回——
            // 粘滞账号唯一的恢复通道被无声吞掉
            self.inFlight[account.id] = nil
        }
        inFlight[account.id] = (task, mayRenew)
        await task.value
        // 账号可能在刷新途中被移除:removeAccount 清过的东西不该被在飞任务写回来
        // (states 幽灵会虚高 throttledCount;markLoaded 复活的 diskSnapshots 条目
        // 会把已移除账号的邮箱/用量残留在磁盘上)
        if !accounts.contains(where: { $0.id == account.id }) {
            states[account.id] = nil
            cachedSortKeys[account.id] = nil
            if diskSnapshots[account.id] != nil {
                diskSnapshots[account.id] = nil
                SnapshotsRepository.save(diskSnapshots)
            }
            if rateLimits[account.id] != nil {
                rateLimits[account.id] = nil
                RateLimitsRepository.save(rateLimits)
            }
        }
    }

    /// 落地成功快照:更新展示态、同步排序键缓存(见 cachedSortKeys),并持久化到磁盘
    /// (重启后可先展示上次数据;见 SnapshotsRepository)。
    /// diskSnapshots 只在这里与 removeAccount 变更,绝不从 states 重建——
    /// states 会被瞬时错误(.error/.needsReauth)覆盖,从它派生会把最后成功数据抹掉。
    private func markLoaded(_ id: UUID, _ snapshot: UsageSnapshot) {
        states[id] = .loaded(snapshot)
        cachedSortKeys[id] = CachedSortKeys(snapshot: snapshot)
        diskSnapshots[id] = snapshot
        SnapshotsRepository.save(diskSnapshots)
    }

    /// 首次成功抓额度后学到该账号的组织 UUID 并持久化(供 [ClaudeDesktopCache] 兜底映射)。
    /// 只在 claudeOrgUUID 尚缺时调一次;profile 拿不到就静默作罢,下次成功再试。
    private func learnClaudeOrgUUID(_ id: UUID, accessToken: String) async {
        guard let profile = try? await ClaudeProvider.fetchProfile(accessToken: accessToken),
              let org = profile.orgUUID, !org.isEmpty else { return }
        // 期间账号可能被移除或已被别的路径写入,读最新再落
        guard let idx = accounts.firstIndex(where: { $0.id == id }),
              accounts[idx].claudeOrgUUID != org else { return }
        accounts[idx].claudeOrgUUID = org
        AccountsRepository.save(accounts)
    }

    /// Claude 账号刷新拿不到新数据时的桌面缓存兜底:返回**比 existing 更新**的缓存快照,否则 nil。
    /// 纯读本地文件,不发任何请求。非 Claude 账号一律 nil。
    private func claudeDesktopFallback(_ account: Account, existing: UsageSnapshot?) -> UsageSnapshot? {
        guard account.provider == .claude else { return nil }
        let data = try? Data(contentsOf: ClaudeDesktopCache.fileURL)
        return ClaudeDesktopCache.fallbackSnapshot(orgUUID: account.claudeOrgUUID, planType: account.planType,
                                                   existingFetchedAt: existing?.fetchedAt, data: data)
    }

    private func performRefresh(_ account: Account, mayRenew: Bool) async {
        // 入口前的状态要留一份:renewalDeferred 分支需要它才能把诊断态(.apiChanged 等)原样保住
        let previous = states[account.id]
        if previous?.snapshot == nil {
            states[account.id] = .loading
        }
        do {
            switch account.provider {
            case .claude:
                let (snapshot, creds) = try await ClaudeProvider.fetchUsage(for: account, mayRenew: mayRenew)
                markLoaded(account.id, snapshot)
                // 首次成功后自学组织 UUID(供桌面缓存兜底映射),之后不再重复;best-effort、非致命。
                // profile 在 api.anthropic.com,不碰 token 刷新的限流桶
                if account.claudeOrgUUID == nil {
                    Task { [weak self] in await self?.learnClaudeOrgUUID(account.id, accessToken: creds.accessToken) }
                }
                Task { [weak self] in await self?.refreshDesign(account) } // 有 design 登录才拉,best-effort
            case .codex:
                let (snapshot, tokens) = try await CodexProvider.fetchUsage(for: account, mayRenew: mayRenew)
                markLoaded(account.id, snapshot)
                updateLabelIfNeeded(account, email: snapshot.email ?? tokens.id_token.flatMap(CodexProvider.email(fromIDToken:)), plan: snapshot.planType)
            case .glm:
                let snapshot = try await GLMProvider.fetchUsage(for: account)
                markLoaded(account.id, snapshot)
                updateLabelIfNeeded(account, email: nil, plan: snapshot.planType)
            }
            clearRateLimit(account.id)
        } catch QuotaError.unauthorized {
            states[account.id] = .needsReauth(L("凭据已失效,请重新登录", "Credentials expired, please sign in again"))
        } catch QuotaError.renewalDeferred {
            // token 到期但本轮没轮到续期名额,**一个请求都没发出去**。保留旧快照如实标注,
            // 绝不落错误态:这是限量在按设计生效,不是故障。下一轮或再下一轮就轮到它。
            //
            // 粘滞账号例外:它的主导事实是「限流停摆,只有手动刷新成功才恢复」。
            // 标成「待续期」会误导成「下轮自动就好」,而粘滞根本不会自动恢复
            states[account.id] = Self.stateAfterRenewalDeferred(
                previous: previous, throttled: rateLimits[account.id] != nil)
        } catch QuotaError.http(429, let body) {
            // 限流:把原始响应正文存下来(持久化,卡片可展开查看),该账号进入粘滞——
            // 退出自动刷新回路,只能手动刷新。不退避、不熔断、不定时自动恢复。
            rateLimits[account.id] = RateLimitRecord(body: body, at: Date())
            RateLimitsRepository.save(rateLimits)
            // 兜底:限流拿不到新数据时,若 Claude 桌面应用缓存里有更新的采样就显示它(零请求、零 token 刷新)。
            // 限流现场条(rateLimitResponse)不绑状态、只要 rateLimits 有记录就常驻,所以这里换成缓存数据
            // 不会吞掉「已停摆·可展开原始响应」的提示——用户既看到可用数字,又知道该账号在限流。
            let existing = states[account.id]?.snapshot
            if let cache = claudeDesktopFallback(account, existing: existing) {
                states[account.id] = .loadedStale(cache, .desktopCache)
            } else if let snap = existing {
                // 有上次成功的快照就继续展示,但如实标注「限流中·旧数据」
                states[account.id] = .loadedStale(snap, .rateLimited)
            } else {
                // 从没成功过、也没缓存可兜底,才落到光秃秃的限流态
                states[account.id] = .rateLimited
            }
        } catch QuotaError.parse {
            // 解析失败=接口字段多半变了,进降级态(引导看新版),而不是当成用户侧错误
            states[account.id] = .apiChanged
        } catch {
            states[account.id] = .error(error.localizedDescription)
        }
    }

    /// 解除限流粘滞:**只有一次成功的刷新才走到这里**(账号重新回到自动刷新回路)。
    /// 任何失败都不清——401/parse 等分支看似「穿过了限流层」,但同名错误也可能在
    /// 发出请求之前就地抛出(无 refresh token 的 unauthorized、钥匙串被拒的
    /// missingCredentials 落进兜底 catch),本地失败不该销毁用户要查看的 429 现场,
    /// 更不该把账号悄悄放回自动回路;离线/超时(URLError)同理。
    /// 「成功才恢复」也和粘滞的语义自洽:恢复自动刷新的唯一凭证是端点真的又可用了。
    private func clearRateLimit(_ id: UUID) {
        guard rateLimits[id] != nil else { return }
        rateLimits[id] = nil
        RateLimitsRepository.save(rateLimits)
    }

    private func updateLabelIfNeeded(_ account: Account, email: String?, plan: String?) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        var changed = false
        // 只在名称还空着时用邮箱回填;用户手动改过的名字不覆盖
        if let email, accounts[idx].label.isEmpty {
            accounts[idx].label = email
            changed = true
        }
        if let plan, accounts[idx].planType != plan {
            accounts[idx].planType = plan
            changed = true
        }
        if changed { AccountsRepository.save(accounts) }
    }

    // MARK: 账号管理

    /// 返回 false 表示同来源账号已存在。只对"指向同一文件/存储"的来源去重
    /// (codexAuthFile / claudeCLI);managed 与 glmApiKey 各自独立,不去重。
    @discardableResult
    func addAccount(_ account: Account) -> Bool {
        switch account.source {
        case .codexAuthFile, .claudeCLI:
            if accounts.contains(where: { $0.provider == account.provider && $0.source == account.source }) {
                return false
            }
        case .managed, .glmApiKey:
            break
        }
        accounts.append(account)
        AccountsRepository.save(accounts)
        Task { await refresh(account, force: true) }
        return true
    }

    /// 当前处于限流粘滞的账号数,驱动面板底栏的「N 个账号限流,待手动刷新」。
    /// 按 rateLimits 记录统计而非展示态:粘滞是「被自动回路排除」的事实,
    /// 记录才是它的唯一权威(粘滞期间手动刷新若又遇到别的错误,states 会被
    /// 覆盖成 .error/.needsReauth,从展示态数就会漏计)。按 accounts 过滤
    /// 防已移除账号的残留记录虚高(init 已 prune,双保险)。
    var throttledCount: Int {
        accounts.filter { rateLimits[$0.id] != nil }.count
    }

    func removeAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        states[account.id] = nil
        cachedSortKeys[account.id] = nil
        rateLimits[account.id] = nil
        RateLimitsRepository.save(rateLimits)
        lastGrantRound[account.id] = nil
        diskSnapshots[account.id] = nil
        SnapshotsRepository.save(diskSnapshots)
        designProjects[account.id] = nil
        designAvailable[account.id] = nil
        switch account.source {
        case .managed:
            KeychainStore.delete(key: account.id.uuidString)
            KeychainStore.delete(key: DesignProvider.keychainKey(account))
        case .glmApiKey:
            KeychainStore.delete(key: account.id.uuidString) // GLM API key
        default:
            break
        }
        KeychainStore.delete(key: DesignProvider.rescueKey(account)) // 清 design rescue 残留
        AccountsRepository.save(accounts)
    }

    func relabel(_ account: Account, to label: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].label = label
        AccountsRepository.save(accounts)
    }

    func setManualSubscriptionEnd(_ account: Account, date: Date?) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].manualSubscriptionEndsAt = date
        AccountsRepository.save(accounts)
    }

    func setPayment(_ account: Account, payment: PaymentMethod?) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].payment = payment
        AccountsRepository.save(accounts)
    }

    /// 拉该账号的 Claude Design 项目(仅当已 design 登录);best-effort。
    /// designAvailable 缓存避免每轮刷新都做钥匙串读(尤其 claudeCLI 的外部钥匙串读会弹框)。
    func refreshDesign(_ account: Account) async {
        guard account.provider == .claude else { return }
        if designAvailable[account.id] == false { return }
        let has = designAvailable[account.id] ?? DesignProvider.hasCredentials(for: account)
        designAvailable[account.id] = has
        guard has else { return }
        do {
            let projects = try await DesignProvider.fetchProjects(for: account)
            designProjects[account.id] = projects
            recordFirstSeen(projects)
        } catch {
            designProjects[account.id] = nil // token 失效/过期就别再显示旧列表
        }
    }

    /// 刚 design 登录成功后立即拉(跳过缓存判定)
    func refreshDesignForced(_ account: Account) async {
        designAvailable[account.id] = true
        do {
            let projects = try await DesignProvider.fetchProjects(for: account)
            designProjects[account.id] = projects
            recordFirstSeen(projects)
        } catch {
            designProjects[account.id] = nil
        }
    }

    // MARK: 菜单栏文案

    var menuBarText: String {
        var parts: [String] = []
        let worstClaude = worstPercent(provider: .claude)
        let worstCodex = worstPercent(provider: .codex)
        if let p = worstClaude { parts.append("C \(Int(p))%") }
        if let p = worstCodex { parts.append("X \(Int(p))%") }
        if hasProblem { parts.append("⚠︎") }
        return parts.isEmpty ? "" : parts.joined(separator: " ")
    }

    private func worstPercent(provider: Provider) -> Double? {
        let percents = accounts.filter { $0.provider == provider }
            .compactMap { states[$0.id]?.snapshot }
            .flatMap { $0.windows.map(\.usedPercent) }
        return percents.max()
    }

    var hasProblem: Bool {
        states.values.contains { state in
            if case .needsReauth = state { return true }
            if case .error = state { return true }
            return false
        }
    }
}

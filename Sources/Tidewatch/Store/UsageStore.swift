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

    /// 单次刷新的结局(驱动手动强刷的探针熔断:只有确实吃到 429 才停掉同 provider 的后续账号)
    enum RefreshOutcome { case success, rateLimited, failed, skipped }

    private var refreshLoop: Task<Void, Never>?
    private var updateLoop: Task<Void, Never>?
    private var inFlight: [UUID: Task<RefreshOutcome, Never>] = [:]
    /// 429 指数退避:账号 → (下次允许自动刷新的时间, 连续 429 次数)。
    /// token 刷新端点(platform.claude.com)对 client_id/IP 限流有惩罚期,429 后继续按周期戳它
    /// 会让惩罚自我维持;退避 15m→30m→1h→2h 封顶(带 ±20% 抖动防多账号对齐),
    /// 成功一次即清零。手动强刷(force)可跳过账号级退避,但受 provider 熔断约束(见下)。
    private var backoff429: [UUID: (until: Date, streak: Int)] = [:]
    /// Provider 级限流熔断,**只对 Claude 生效**:Claude 的所有账号共用同一 client_id + 本机 IP
    /// + 同一后端限流桶(2026-07-19 实测:platform/console/claude.ai 三个 OAuth host 的 token
    /// 端点共享限流,且限流判定在凭据校验之前)。任一账号吃到 429 即对整个 provider 进入冷却:
    /// 冷却期内其余账号不再逐个撞端点——否则 4 账号一轮 4 连击,反而喂养惩罚期。
    /// 冷却后的下一轮里,第一个账号天然成为探针:成功即清熔断放行其余账号。
    /// GLM 是每账号独立 API key(无共享限流桶),Codex 未实测——都只走账号级退避,不熔断。
    private var providerCooldown: [Provider: Date] = [:]
    /// 共享限流桶已被实测证实的 provider(熔断只对它们生效)
    private static let cooldownProviders: Set<Provider> = [.claude]
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
        for account in accounts {
            if let snap = diskSnapshots[account.id] {
                states[account.id] = .loadedStale(snap, .restored)
                cachedSortKeys[account.id] = CachedSortKeys(snapshot: snap)
            }
        }
        // 磁盘里可能残留已移除账号的条目(如移除时写盘失败),顺手清理
        let ids = Set(accounts.map(\.id))
        diskSnapshots = diskSnapshots.filter { ids.contains($0.key) }
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
        let byProvider = Dictionary(grouping: accounts, by: { $0.provider })
        await withTaskGroup(of: Void.self) { group in
            for (provider, providerAccounts) in byProvider {
                group.addTask { [weak self] in
                    for (i, account) in providerAccounts.enumerated() {
                        // 同 provider 相邻请求错开 1.5s:多账号共用同一 client_id/IP,连续快打会踩端点短窗口限流。
                        // 每 30 分钟一轮,即便 4 个 Claude 摊到 ~4.5s 也可忽略。
                        if i > 0 { try? await Task.sleep(for: .milliseconds(1500)) }
                        // 回路被取消(如改刷新间隔触发 restartLoop)时上面的 sleep 立即返回,
                        // 错峰就没了——直接停掉本轮剩余账号,别退化成背靠背连击
                        if Task.isCancelled { break }
                        let outcome = await self?.refresh(account, force: force)
                        // 手动强刷防雪崩:本账号**确实吃到 429**(而非冷却残留)才停,它就是这轮的探针,
                        // 其余账号不再继续撞端点,直接标成「限流中·旧数据」。自动回路不需要这个 break:
                        // refresh() 的熔断守卫会让后续账号各自快速跳过。
                        if force, outcome == .rateLimited, let self {
                            await self.degradeRemainingAfterRateLimit(provider, Array(providerAccounts[(i + 1)...]))
                            break
                        }
                    }
                }
            }
        }
        lastRefreshAt = Date()
    }

    /// provider 熔断冷却若生效,返回截止时间;过期返回 nil
    private func activeProviderCooldown(_ provider: Provider) -> Date? {
        guard let until = providerCooldown[provider], until > Date() else { return nil }
        return until
    }

    /// 探针吃到 429 后处理同 provider 的剩余账号:读冷却与改状态在同一次 MainActor 调用里完成
    /// (拆成两次 await 会留竞态窗口:中间若另一账号刷新成功清了熔断,这里就会拿旧冷却盖新数据)。
    /// 在飞与已移除的账号不碰——前者让它自己收尾,后者不该再留幽灵状态。
    private func degradeRemainingAfterRateLimit(_ provider: Provider, _ remaining: [Account]) {
        guard let until = activeProviderCooldown(provider) else { return }
        let liveIDs = Set(accounts.map(\.id))
        for account in remaining where liveIDs.contains(account.id) && inFlight[account.id] == nil {
            markSkippedByCooldown(account, until: until)
        }
    }

    /// 因限流冷却被跳过的账号:有旧快照的标成「限流中·旧数据」,从没成功过的标成限流态;
    /// 其余状态(needsReauth/error/apiChanged/loading)保持原样,不掩盖更具体的问题
    private func markSkippedByCooldown(_ account: Account, until: Date) {
        switch states[account.id] {
        case .loaded(let snap), .loadedStale(let snap, _):
            states[account.id] = .loadedStale(snap, .rateLimited(nextRetryAt: until))
        case .idle, .rateLimited, nil:
            states[account.id] = .rateLimited
        default:
            break
        }
    }

    /// force=false 时跳过已标记需重登的账号(避免每轮空刷 invalid_grant);
    /// 同一账号只允许一个进行中的刷新,重复触发直接等已有任务。
    /// 返回本次结局;等到别人已有任务或被守卫跳过都算 .skipped(不能替探针熔断作证)。
    @discardableResult
    func refresh(_ account: Account, force: Bool = false) async -> RefreshOutcome {
        if let existing = inFlight[account.id] {
            _ = await existing.value
            return .skipped
        }
        if !force {
            if case .needsReauth = states[account.id] ?? .idle {
                return .skipped
            }
            // 账号级退避与 provider 级熔断取较晚者;冷却期内不撞端点,
            // 但要把「还在限流等待」如实反映到卡片上(旧快照 → loadedStale)
            let untils = [backoff429[account.id]?.until, providerCooldown[account.provider]].compactMap { $0 }
            if let until = untils.max(), until > Date() {
                markSkippedByCooldown(account, until: until)
                return .skipped
            }
        }
        let task = Task { await self.performRefresh(account) }
        inFlight[account.id] = task
        let outcome = await task.value
        inFlight[account.id] = nil
        // 账号可能在刷新途中被移除:removeAccount 清过的 state 不该被在飞任务写回来
        // (幽灵条目会让 throttledCount 这类按 states 汇总的数字虚高)
        if !accounts.contains(where: { $0.id == account.id }) {
            states[account.id] = nil
        }
        return outcome
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

    @discardableResult
    private func performRefresh(_ account: Account) async -> RefreshOutcome {
        if states[account.id]?.snapshot == nil {
            states[account.id] = .loading
        }
        do {
            switch account.provider {
            case .claude:
                let (snapshot, _) = try await ClaudeProvider.fetchUsage(for: account)
                markLoaded(account.id, snapshot)
                Task { [weak self] in await self?.refreshDesign(account) } // 有 design 登录才拉,best-effort
            case .codex:
                let (snapshot, tokens) = try await CodexProvider.fetchUsage(for: account)
                markLoaded(account.id, snapshot)
                updateLabelIfNeeded(account, email: snapshot.email ?? tokens.id_token.flatMap(CodexProvider.email(fromIDToken:)), plan: snapshot.planType)
            case .glm:
                let snapshot = try await GLMProvider.fetchUsage(for: account)
                markLoaded(account.id, snapshot)
                updateLabelIfNeeded(account, email: nil, plan: snapshot.planType)
            }
            backoff429[account.id] = nil // 成功即清退避
            providerCooldown[account.provider] = nil // 探针成功,解除整个 provider 的熔断
            return .success
        } catch QuotaError.unauthorized {
            states[account.id] = .needsReauth(L("凭据已失效,请重新登录", "Credentials expired, please sign in again"))
            return .failed
        } catch QuotaError.http(429, let body) {
            // 限流:进指数退避(15m→30m→1h→2h 封顶,±20% 抖动防多账号同轮进入后每轮对齐连击),
            // 服务端给了 Retry-After 就尊重它(钳制在 1 分钟~2 小时:0/畸形值会让整套背压失效,
            // 离谱大值会把账号锁死太久);对 Claude 同时点燃 provider 熔断(共用限流桶,
            // 一个账号 429 之后紧接着刷其余账号只会喂养惩罚期;GLM/Codex 见 providerCooldown 注释)。
            // 有上次成功的快照就继续展示,但如实标注「限流中·旧数据」;从没成功过才落到限流态。
            let streak = (backoff429[account.id]?.streak ?? 0) + 1
            let base = min(900 * pow(2, Double(streak - 1)), 7200)
            let jittered = base * Double.random(in: 0.8...1.2)
            let delay = Self.retryAfterSeconds(inErrorBody: body).map { min(max($0, 60), 7200) } ?? jittered
            let until = Date().addingTimeInterval(delay)
            backoff429[account.id] = (until, streak)
            if Self.cooldownProviders.contains(account.provider) {
                // 直接覆盖而非取 max:最新一次 429 携带的是端点当下最新鲜的状态
                providerCooldown[account.provider] = until
            }
            if let snap = states[account.id]?.snapshot {
                states[account.id] = .loadedStale(snap, .rateLimited(nextRetryAt: until))
            } else {
                states[account.id] = .rateLimited
            }
            return .rateLimited
        } catch QuotaError.parse {
            // 解析失败=接口字段多半变了,进降级态(引导看新版),而不是当成用户侧错误
            states[account.id] = .apiChanged
            return .failed
        } catch {
            states[account.id] = .error(error.localizedDescription)
            return .failed
        }
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

    /// HTTP.errorBody 会把限流响应的 Retry-After 以 "Retry-After:<秒>s" 形式嵌进错误正文前缀,
    /// 从中解析出服务端建议的重试等待秒数(没有该头则返回 nil)
    nonisolated static func retryAfterSeconds(inErrorBody body: String) -> Double? {
        guard let range = body.range(of: #"Retry-After:[0-9]+s"#, options: .regularExpression) else { return nil }
        return Double(body[range].dropFirst("Retry-After:".count).dropLast(1))
    }

    /// 当前处于限流状态的账号数(含展示旧数据的),驱动面板底栏的限流提示。
    /// 按 accounts 汇总(而非 states.values):防已移除账号的残留状态把数字虚高;
    /// 重启恢复的 .restored 不算——那是中性状态,不是限流告警
    var throttledCount: Int {
        accounts.reduce(0) { count, account in
            switch states[account.id] {
            case .loadedStale(_, .rateLimited), .rateLimited: return count + 1
            default: return count
            }
        }
    }

    func removeAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        states[account.id] = nil
        cachedSortKeys[account.id] = nil
        backoff429[account.id] = nil
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

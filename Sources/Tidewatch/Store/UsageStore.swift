import Foundation
import Observation

/// 账号列表排序模式(rawValue 持久化到 UserDefaults)
enum AccountSortMode: String, CaseIterable {
    /// 默认:按添加顺序
    case added
    /// 按重置时间降序:重置时刻离现在最远(刚重置完、额度最新鲜)的排第一
    case resetTime
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

    /// 面板列表的实际展示顺序。读了 accounts/states/accountSortMode 三个可观察属性,
    /// 快照刷新(states 变化)后 @Observable 会驱动列表自动重排。
    var sortedAccounts: [Account] {
        guard accountSortMode == .resetTime else { return accounts }
        var resets: [UUID: Date] = [:]
        for account in accounts {
            if let d = states[account.id]?.snapshot?.windows.compactMap(\.resetsAt).max() {
                resets[account.id] = d
            }
        }
        return Self.sortedByReset(accounts, resets: resets)
    }

    /// 排序键 = 该账号最新快照所有窗口 resetsAt 的最大值,降序(最远的排第一);
    /// 无键(无快照或全无 resetsAt)排最后;同键及无键之间保持传入顺序(稳定)。
    /// 纯函数(nonisolated + 显式传键),便于脱离 MainActor 单测。
    nonisolated static func sortedByReset(_ accounts: [Account], resets: [UUID: Date]) -> [Account] {
        accounts.enumerated().sorted { a, b in
            switch (resets[a.element.id], resets[b.element.id]) {
            case let (l?, r?): return l == r ? a.offset < b.offset : l > r
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
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    /// 429 指数退避:账号 → (下次允许自动刷新的时间, 连续 429 次数)。
    /// token 刷新端点(platform.claude.com)对 client_id/IP 限流有惩罚期,429 后继续按周期戳它
    /// 会让惩罚自我维持;退避 15m→30m→1h→2h 封顶,成功一次即清零。手动强刷(force)可跳过。
    private var backoff429: [UUID: (until: Date, streak: Int)] = [:]
    /// 是否有 design 凭据的缓存(nil=未判定),避免每轮刷新做钥匙串读
    private var designAvailable: [UUID: Bool] = [:]

    init() {
        let stored = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
        refreshIntervalMinutes = stored >= 3 ? stored : 5
        accountSortMode = UserDefaults.standard.string(forKey: "accountSortMode")
            .flatMap(AccountSortMode.init(rawValue:)) ?? .added
        // 默认开:老用户/首启时该 key 不存在(nil)也视为开。didSet 在 init 内不触发,不会提前启动 loop。
        updateCheckEnabled = UserDefaults.standard.object(forKey: Keys.updateCheckEnabled) as? Bool ?? true
        accounts = AccountsRepository.load()
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
            for (_, providerAccounts) in byProvider {
                group.addTask { [weak self] in
                    for (i, account) in providerAccounts.enumerated() {
                        // 同 provider 相邻请求错开 1.5s:多账号共用同一 client_id/IP,连续快打会踩端点短窗口限流。
                        // 每 30 分钟一轮,即便 4 个 Claude 摊到 ~4.5s 也可忽略。
                        if i > 0 { try? await Task.sleep(for: .milliseconds(1500)) }
                        await self?.refresh(account, force: force)
                    }
                }
            }
        }
        lastRefreshAt = Date()
    }

    /// force=false 时跳过已标记需重登的账号(避免每轮空刷 invalid_grant);
    /// 同一账号只允许一个进行中的刷新,重复触发直接等已有任务
    func refresh(_ account: Account, force: Bool = false) async {
        if let existing = inFlight[account.id] {
            await existing.value
            return
        }
        if !force, case .needsReauth = states[account.id] ?? .idle {
            return
        }
        if !force, let b = backoff429[account.id], b.until > Date() {
            return // 429 退避期内不自动重试,让端点的限流惩罚自然消退
        }
        let task = Task { await self.performRefresh(account) }
        inFlight[account.id] = task
        await task.value
        inFlight[account.id] = nil
    }

    private func performRefresh(_ account: Account) async {
        if states[account.id]?.snapshot == nil {
            states[account.id] = .loading
        }
        do {
            switch account.provider {
            case .claude:
                let (snapshot, _) = try await ClaudeProvider.fetchUsage(for: account)
                states[account.id] = .loaded(snapshot)
                Task { [weak self] in await self?.refreshDesign(account) } // 有 design 登录才拉,best-effort
            case .codex:
                let (snapshot, tokens) = try await CodexProvider.fetchUsage(for: account)
                states[account.id] = .loaded(snapshot)
                updateLabelIfNeeded(account, email: snapshot.email ?? tokens.id_token.flatMap(CodexProvider.email(fromIDToken:)), plan: snapshot.planType)
            case .glm:
                let snapshot = try await GLMProvider.fetchUsage(for: account)
                states[account.id] = .loaded(snapshot)
                updateLabelIfNeeded(account, email: nil, plan: snapshot.planType)
            }
            backoff429[account.id] = nil // 成功即清退避
        } catch QuotaError.unauthorized {
            states[account.id] = .needsReauth(L("凭据已失效,请重新登录", "Credentials expired, please sign in again"))
        } catch QuotaError.http(429, _) {
            // 限流:进指数退避(15m→30m→1h→2h 封顶),期间自动回路不再戳端点;
            // 有上次成功的快照就留着别覆盖,只有从没成功过(无旧数据)才落到限流态。
            let streak = (backoff429[account.id]?.streak ?? 0) + 1
            let delay = min(900 * pow(2, Double(streak - 1)), 7200)
            backoff429[account.id] = (Date().addingTimeInterval(delay), streak)
            if states[account.id]?.snapshot == nil {
                states[account.id] = .rateLimited
            }
        } catch QuotaError.parse {
            // 解析失败=接口字段多半变了,进降级态(引导看新版),而不是当成用户侧错误
            states[account.id] = .apiChanged
        } catch {
            states[account.id] = .error(error.localizedDescription)
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

    func removeAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        states[account.id] = nil
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

import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    var accounts: [Account] = []
    var states: [UUID: AccountState] = [:]
    /// 每个 Claude 账号的 Claude Design 项目列表(有 design 登录才有)
    var designProjects: [UUID: [DesignProject]] = [:]
    /// 项目 id → QuotaBar 首次发现该项目的时间(接口不返回真实时间,这是替代;持久化)
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

    private var refreshLoop: Task<Void, Never>?
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    /// 是否有 design 凭据的缓存(nil=未判定),避免每轮刷新做钥匙串读
    private var designAvailable: [UUID: Bool] = [:]

    init() {
        let stored = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
        refreshIntervalMinutes = stored >= 3 ? stored : 5
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
    }

    private func restartLoop() {
        guard refreshLoop != nil else { return }
        refreshLoop?.cancel()
        refreshLoop = nil
        start(immediate: false)
    }

    // MARK: 刷新

    func refreshAll(force: Bool = false) async {
        let list = accounts
        await withTaskGroup(of: Void.self) { group in
            for account in list {
                group.addTask { [weak self] in
                    await self?.refresh(account, force: force)
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
            }
        } catch QuotaError.unauthorized {
            states[account.id] = .needsReauth(L("凭据已失效,请重新登录", "Credentials expired, please sign in again"))
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

    /// 返回 false 表示同来源账号已存在(managed 账号各有独立 token,不算重复)
    @discardableResult
    func addAccount(_ account: Account) -> Bool {
        if account.source != .managed,
           accounts.contains(where: { $0.provider == account.provider && $0.source == account.source }) {
            return false
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
        if case .managed = account.source {
            KeychainStore.delete(key: account.id.uuidString)
            KeychainStore.delete(key: DesignProvider.keychainKey(account))
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

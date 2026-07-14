import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    var accounts: [Account] = []
    var states: [UUID: AccountState] = [:]
    var lastRefreshAt: Date?
    var refreshIntervalMinutes: Int {
        didSet { UserDefaults.standard.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes") }
    }

    private var refreshLoop: Task<Void, Never>?

    init() {
        let stored = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
        refreshIntervalMinutes = stored > 0 ? stored : 5
        accounts = AccountsRepository.load()
    }

    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            await self?.refreshAll()
            while !Task.isCancelled {
                let minutes = await MainActor.run { self?.refreshIntervalMinutes ?? 5 }
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                await self?.refreshAll()
            }
        }
    }

    // MARK: 刷新

    func refreshAll() async {
        let list = accounts
        await withTaskGroup(of: Void.self) { group in
            for account in list {
                group.addTask { [weak self] in
                    await self?.refresh(account)
                }
            }
        }
        lastRefreshAt = Date()
    }

    func refresh(_ account: Account) async {
        if states[account.id]?.snapshot == nil {
            states[account.id] = .loading
        }
        do {
            switch account.provider {
            case .claude:
                let (snapshot, _) = try await ClaudeProvider.fetchUsage(for: account)
                states[account.id] = .loaded(snapshot)
            case .codex:
                let (snapshot, tokens) = try await CodexProvider.fetchUsage(for: account)
                states[account.id] = .loaded(snapshot)
                updateLabelIfNeeded(account, email: snapshot.email ?? tokens.id_token.flatMap(CodexProvider.email(fromIDToken:)), plan: snapshot.planType)
            }
        } catch QuotaError.unauthorized {
            states[account.id] = .needsReauth("凭据已失效,请重新登录")
        } catch {
            states[account.id] = .error(error.localizedDescription)
        }
    }

    private func updateLabelIfNeeded(_ account: Account, email: String?, plan: String?) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        var changed = false
        if let email, accounts[idx].label.isEmpty || accounts[idx].label.hasPrefix("未命名") {
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

    func addAccount(_ account: Account) {
        accounts.append(account)
        AccountsRepository.save(accounts)
        Task { await refresh(account) }
    }

    func removeAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        states[account.id] = nil
        if case .managed = account.source {
            KeychainStore.delete(key: account.id.uuidString)
        }
        AccountsRepository.save(accounts)
    }

    func relabel(_ account: Account, to label: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].label = label
        AccountsRepository.save(accounts)
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

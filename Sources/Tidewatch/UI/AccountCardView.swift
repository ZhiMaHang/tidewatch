import SwiftUI

struct AccountCardView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let account: Account
    let state: AccountState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                providerBadge
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.label.isEmpty ? L("未命名账号", "Unnamed") : account.label)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let plan = account.planType ?? state.snapshot?.planType {
                            Text(planBadge(plan))
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        Text(sourceDescription)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    if let end = account.manualSubscriptionEndsAt ?? state.snapshot?.subscriptionEndsAt {
                        Label {
                            Text(L("订阅至 ", "Renews ") + end.localized(date: .abbreviated))
                                .foregroundStyle(Self.isExpiringSoon(end) ? Color.red : Color.secondary)
                        } icon: {
                            Image(systemName: "calendar")
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    }
                    if let payment = account.payment {
                        Label {
                            Text(payment.summary)
                        } icon: {
                            Image(systemName: payment.type.icon)
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button(L("重命名…", "Rename…")) {
                        if let name = RenamePrompt.run(current: account.label) {
                            store.relabel(account, to: name)
                        }
                    }
                    Button(L("设置订阅到期日…", "Set renewal date…")) {
                        switch DatePrompt.run(current: account.manualSubscriptionEndsAt) {
                        case .set(let d): store.setManualSubscriptionEnd(account, date: d)
                        case .clear: store.setManualSubscriptionEnd(account, date: nil)
                        case .cancel: break
                        }
                    }
                    Button(L("设置付款方式…", "Set payment method…")) {
                        switch PaymentPrompt.run(current: account.payment) {
                        case .set(let p): store.setPayment(account, payment: p)
                        case .clear: store.setPayment(account, payment: nil)
                        case .cancel: break
                        }
                    }
                    if canRelogin {
                        Button(L("重新登录…", "Re-sign in…")) { reloginClaude() }
                    }
                    if account.provider == .claude {
                        Button(L("登录 Claude Design…", "Sign in to Claude Design…")) {
                            guard let r = DesignLoginPrompt.run() else { return }
                            Task {
                                if let creds = try? await ClaudeDesignOAuth.exchange(pastedCode: r.code, pkce: r.pkce),
                                   (try? await DesignProvider.persistLocked(creds, for: account)) != nil {
                                    await store.refreshDesignForced(account)
                                }
                            }
                        }
                    }
                    Button(L("刷新", "Refresh")) { Task { await store.refresh(account, force: true) } }
                    Divider()
                    Button(L("移除账号", "Remove account"), role: .destructive) { store.removeAccount(account) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            switch state {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("加载中…", "Loading…")).font(.caption).foregroundStyle(.secondary)
                }
            case .loaded(let snapshot):
                windowsView(snapshot)
            case .loadedStale(let snapshot, let reason):
                windowsView(snapshot)
                staleNotice(snapshot, reason: reason)
            case .needsReauth(let message):
                VStack(alignment: .leading, spacing: 3) {
                    Label {
                        Text(message).font(.caption2)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    reloginButton
                }
            case .error(let message):
                Label {
                    Text(message).font(.caption2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            case .rateLimited:
                VStack(alignment: .leading, spacing: 3) {
                    Label {
                        // 不断言「登录已过期」:这个态也可能来自熔断跳过(本轮没发请求,凭据完全有效)
                        Text(canRelogin
                             ? L("Claude 端点限流中,稍后自动重试;重新登录可立即恢复", "Claude endpoint is rate limited — retrying later; re-sign in to recover now")
                             : L("请求被限流,稍后自动重试", "Rate limited — retrying automatically"))
                            .font(.caption2)
                    } icon: {
                        Image(systemName: "hourglass")
                            .foregroundStyle(.orange)
                    }
                    reloginButton
                }
            case .apiChanged:
                VStack(alignment: .leading, spacing: 3) {
                    Label {
                        Text(L("接口可能已变更,不是你的问题。", "The API may have changed — not your fault."))
                            .font(.caption2)
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(.secondary)
                    }
                    Link(destination: URL(string: "https://github.com/ZhiMaHang/tidewatch/releases")!) {
                        Text(L("看是否有新版 ›", "Check for a newer version ›"))
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }

            if let projects = store.designProjects[account.id], !projects.isEmpty {
                Button {
                    openWindow(id: DesignProjectsWindow.windowID)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label(L("Design 项目 (\(projects.count)) ›", "Design projects (\(projects.count)) ›"), systemImage: "paintpalette")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func windowsView(_ snapshot: UsageSnapshot) -> some View {
        ForEach(snapshot.windows, id: \.key) { window in
            WindowGaugeView(window: window)
        }
        if let credits = snapshot.creditsBalance {
            Text(L("额外 Credits: ", "Extra credits: ") + credits)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 旧数据标注:数字还在,但要让用户一眼知道它不新鲜、以及为什么。
    /// 之前限流保留旧快照时完全静默(卡片与正常态无异),用户只会觉得「刷新失效了」。
    /// 两种口吻:限流是橙色告警(附恢复时间与重登通道);重启恢复是中性灰(首轮刷新即覆盖)。
    @ViewBuilder
    private func staleNotice(_ snapshot: UsageSnapshot, reason: StaleReason) -> some View {
        let dataTime = snapshot.fetchedAt.localized(date: .abbreviated, time: .shortened)
        switch reason {
        case .rateLimited(let nextRetryAt):
            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text(L("限流中,显示 \(dataTime) 的数据", "Rate limited — showing data from \(dataTime)"))
                        .font(.caption2)
                } icon: {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    if let retry = nextRetryAt, retry > Date() {
                        // 说「恢复自动刷新」而非「自动重试」:真正的重试发生在这之后的下一个刷新周期
                        let t = retry.localized(date: .omitted, time: .shortened)
                        Text(L("\(t) 后恢复自动刷新", "Auto-refresh resumes after \(t)"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    reloginButton
                }
            }
        case .restored:
            Label {
                Text(L("上次数据(\(dataTime)),刷新中…", "Last data (\(dataTime)), refreshing…"))
                    .font(.caption2)
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 订阅临期红字阈值:到期日距今 ≤ 3 个自然日
    static let expiringSoonThresholdDays = 3

    /// 订阅是否临近到期:按日历自然日差判定(非 72 小时秒差,避免同一天内随时刻闪变),
    /// 已过期(差为负)同样算临期。
    /// 边界用例(设 now = 7月15日,任意时刻):
    /// - end = 7月15日(今天到期,差 0 天)→ true
    /// - end = 7月18日(3 天后)→ true
    /// - end = 7月19日(4 天后)→ false
    /// - end = 7月10日(已过期,差 -5 天)→ true
    static func isExpiringSoon(_ end: Date, now: Date = .init(), calendar: Calendar = .current) -> Bool {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: end)
        ).day ?? .max
        return days <= expiringSoonThresholdDays
    }

    /// 只有 managed Claude(应用内登录)有重新登录通道;CLI/文件导入的凭据归各自 CLI 管
    private var canRelogin: Bool {
        account.provider == .claude && account.source == .managed
    }

    /// 换全新 token 家族:旧家族被限流惩罚/吊销时的自愈通道;保留 UUID 和全部元数据。
    /// 成功后自动强刷,额度立即回来。
    private func reloginClaude() {
        guard let r = ClaudeReloginPrompt.run(label: account.label) else { return }
        Task {
            if let creds = try? await ClaudeOAuth.exchange(pastedCode: r.code, pkce: r.pkce),
               let data = try? JSONEncoder().encode(creds) {
                KeychainStore.save(data, key: account.id.uuidString)
                await store.refresh(account, force: true)
            }
        }
    }

    @ViewBuilder
    private var reloginButton: some View {
        if canRelogin {
            Button { reloginClaude() } label: {
                Text(L("重新登录 ›", "Re-sign in ›")).font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }

    private var providerBadge: some View {
        Text(badgeLetter)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .frame(width: 22, height: 22)
            .background(badgeColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.white)
    }

    private var badgeLetter: String {
        switch account.provider {
        case .claude: return "C"
        case .codex: return "X"
        case .glm: return "G"
        }
    }

    private var badgeColor: Color {
        switch account.provider {
        case .claude: return .orange
        case .codex: return .teal
        case .glm: return .indigo
        }
    }

    /// 徽章文案:去掉 claude_/chatgpt_ 前缀再大写(claude_max -> MAX,pro -> PRO)
    private func planBadge(_ plan: String) -> String {
        var s = plan.lowercased()
        for prefix in ["claude_", "claude-", "claude ", "chatgpt_", "chatgpt-", "chatgpt "] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        return s.uppercased()
    }

    private var sourceDescription: String {
        switch account.source {
        case .managed: return L("应用内登录", "In-app login")
        case .codexAuthFile(let path):
            return path == CodexProvider.defaultAuthPath ? L("本机 Codex CLI", "Local Codex CLI") : (path as NSString).abbreviatingWithTildeInPath
        case .claudeCLI(let path):
            return path == nil ? L("本机 Claude Code", "Local Claude Code") : ((path! as NSString).abbreviatingWithTildeInPath)
        case .glmApiKey:
            return "z.ai API key"
        }
    }
}

struct WindowGaugeView: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(window.usedPercent))%")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
            ProgressView(value: window.usedPercent, total: 100)
                .tint(color)
                .controlSize(.small)
            if let resetsAt = window.resetsAt {
                Text(resetLabel(resetsAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var color: Color {
        switch window.usedPercent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    /// 整句组装:重置点已过去时(旧快照常见)单说「已重置」,避免拼出「重置于 已重置」
    private func resetLabel(_ date: Date) -> String {
        date.timeIntervalSinceNow <= 0
            ? L("已重置", "Already reset")
            : L("重置于 ", "Resets ") + resetText(date)
    }

    private func resetText(_ date: Date) -> String {
        let remain = date.timeIntervalSinceNow
        if remain <= 0 { return L("已重置", "Already reset") } // 防御分支:resetLabel 已拦截,正常不可达
        let hours = Int(remain) / 3600
        let minutes = (Int(remain) % 3600) / 60
        if hours >= 48 { return L("\(hours / 24) 天\(hours % 24) 小时后", "in \(hours / 24)d \(hours % 24)h") }
        if hours > 0 { return L("\(hours) 小时 \(minutes) 分后", "in \(hours)h \(minutes)m") }
        return L("\(minutes) 分钟后", "in \(minutes)m")
    }
}

import SwiftUI

struct AccountCardView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let account: Account
    let state: AccountState
    /// 展开显示的 429 现场的时间戳(卡片内联展开,不另开窗口)。
    /// 用时间戳而非布尔:换了一条新记录(再次吃到 429)自动回到收起态
    @State private var expandedRateLimitAt: Date?

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
                        // 不断言「登录已过期」:429 在凭据校验之前发生,凭据可能完全有效;
                        // 停摆提示与原始响应在下方常驻的 rateLimitResponse 里
                        Text(canRelogin
                             ? L("请求被限流;重新登录也可恢复", "Rate limited — re-signing in can also recover")
                             : L("请求被限流", "Rate limited"))
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

            // 限流现场入口不绑在某个状态分支上:只要记录还在(粘滞未解除)就常驻可见——
            // 粘滞期间手动刷新若遇断网,展示态会变成 .error,但 429 现场不该跟着失踪
            rateLimitResponse

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
    /// 两种口吻:限流是橙色告警(附原始响应与重登通道,自动刷新已停);
    /// 重启恢复是中性灰(首轮刷新即覆盖)。
    @ViewBuilder
    private func staleNotice(_ snapshot: UsageSnapshot, reason: StaleReason) -> some View {
        let dataTime = snapshot.fetchedAt.localized(date: .abbreviated, time: .shortened)
        switch reason {
        case .rateLimited:
            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text(L("限流中,显示 \(dataTime) 的数据", "Rate limited — showing data from \(dataTime)"))
                        .font(.caption2)
                } icon: {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.orange)
                }
                reloginButton
            }
        case .restored:
            Label {
                Text(L("上次数据(\(dataTime)),刷新中…", "Last data (\(dataTime)), refreshing…"))
                    .font(.caption2)
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            }
        case .renewalDeferred:
            // 中性灰:轮到它续期就自动恢复,用户什么都不用做(想立刻续可以点这张卡的刷新)
            Label {
                Text(L("待续期,显示 \(dataTime) 的数据", "Awaiting renewal — showing data from \(dataTime)"))
                    .font(.caption2)
            } icon: {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.secondary)
            }
        case .desktopCache:
            // 中性蓝:数据真实但来自 Claude 桌面应用缓存(直连拿不到时的兜底),可能滞后、只有两窗。
            // 若同时在限流,下方常驻的「限流响应」条会说明停摆原因,这里只交代数据来源与时刻
            Label {
                Text(L("来自 Claude 桌面缓存,截至 \(dataTime)", "From Claude desktop cache, as of \(dataTime)"))
                    .font(.caption2)
            } icon: {
                Image(systemName: "externaldrive.badge.checkmark")
                    .foregroundStyle(.blue)
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

    /// 限流粘滞的常驻信息条:停摆提示 + 一行「限流响应 · 时间」可展开原始正文。
    /// 正文来自 HTTP.errorBody(带 host/path 与 Retry-After 前缀),留给用户自己判断何时再刷
    @ViewBuilder
    private var rateLimitResponse: some View {
        if let record = store.rateLimits[account.id] {
            let isExpanded = expandedRateLimitAt == record.at
            VStack(alignment: .leading, spacing: 3) {
                Text(L("已停止自动刷新,手动刷新成功后恢复", "Auto-refresh paused — resumes after a successful manual refresh"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Button {
                    expandedRateLimitAt = isExpanded ? nil : record.at
                } label: {
                    Label {
                        Text(L("限流响应 · ", "Rate-limit response · ")
                             + record.at.localized(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                    } icon: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                if isExpanded {
                    ScrollView {
                        // 只排版前 4KB:CDN/WAF 的 429 错误页可达几十 KB,全量排版会卡住面板;复制仍给全文
                        Text(displayBody(record.body))
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled) // best-effort:nonactivating 面板里选中/⌘C 不可靠,复制靠下面的按钮
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 96)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    // 面板是 nonactivating panel(拿不到键盘焦点,⌘C 会落到前台应用),
                    // 这个按钮是唯一保证可用的复制通道,别当冗余清掉
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.body, forType: .string)
                    } label: {
                        Text(L("复制响应", "Copy response")).font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
        }
    }

    /// 展开区的展示文本:空体给占位说明;超长只取前 4096 字符并注明已截断
    private func displayBody(_ body: String) -> String {
        if body.isEmpty { return L("(响应体为空)", "(empty response body)") }
        let limit = 4096
        guard body.count > limit else { return body }
        return String(body.prefix(limit))
            + "\n… " + L("(已截断,「复制响应」可得全文)", "(truncated — \"Copy response\" gives the full text)")
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

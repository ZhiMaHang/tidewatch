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
                    if account.provider == .claude, account.source == .managed {
                        // 换全新 token 家族:旧家族被限流惩罚/吊销时的自愈通道;保留 UUID 和全部元数据
                        Button(L("重新登录…", "Re-sign in…")) {
                            guard let r = ClaudeReloginPrompt.run(label: account.label) else { return }
                            Task {
                                if let creds = try? await ClaudeOAuth.exchange(pastedCode: r.code, pkce: r.pkce),
                                   let data = try? JSONEncoder().encode(creds) {
                                    KeychainStore.save(data, key: account.id.uuidString)
                                    await store.refresh(account, force: true)
                                }
                            }
                        }
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
                ForEach(snapshot.windows, id: \.key) { window in
                    WindowGaugeView(window: window)
                }
                if let credits = snapshot.creditsBalance {
                    Text(L("额外 Credits: ", "Extra credits: ") + credits)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .needsReauth(let message), .error(let message):
                Label {
                    Text(message).font(.caption2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            case .rateLimited:
                Label {
                    Text(L("请求被限流,稍后自动重试", "Rate limited — retrying automatically"))
                        .font(.caption2)
                } icon: {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.secondary)
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
                Text(L("重置于 ", "Resets ") + resetText(resetsAt))
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

    private func resetText(_ date: Date) -> String {
        let remain = date.timeIntervalSinceNow
        if remain <= 0 { return L("已重置", "now") }
        let hours = Int(remain) / 3600
        let minutes = (Int(remain) % 3600) / 60
        if hours >= 48 { return L("\(hours / 24) 天\(hours % 24) 小时后", "in \(hours / 24)d \(hours % 24)h") }
        if hours > 0 { return L("\(hours) 小时 \(minutes) 分后", "in \(hours)h \(minutes)m") }
        return L("\(minutes) 分钟后", "in \(minutes)m")
    }
}

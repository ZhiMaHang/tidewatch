import SwiftUI

struct AccountCardView: View {
    @Environment(UsageStore.self) private var store
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
                            Text(plan.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        Text(sourceDescription)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Menu {
                    Button(L("重命名…", "Rename…")) {
                        if let name = RenamePrompt.run(current: account.label) {
                            store.relabel(account, to: name)
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
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var providerBadge: some View {
        Text(account.provider == .claude ? "C" : "X")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .frame(width: 22, height: 22)
            .background(account.provider == .claude ? Color.orange.opacity(0.85) : Color.teal.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.white)
    }

    private var sourceDescription: String {
        switch account.source {
        case .managed: return L("应用内登录", "In-app login")
        case .codexAuthFile(let path):
            return path == CodexProvider.defaultAuthPath ? L("本机 Codex CLI", "Local Codex CLI") : (path as NSString).abbreviatingWithTildeInPath
        case .claudeCLI(let path):
            return path == nil ? L("本机 Claude Code", "Local Claude Code") : ((path! as NSString).abbreviatingWithTildeInPath)
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

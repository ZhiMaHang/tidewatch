import SwiftUI

struct MenuContentView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var isRefreshing = false
    @State private var listHeight: CGFloat = 0

    private let maxListHeight: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.accounts.isEmpty {
                emptyState
            } else {
                accountList
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var accountList: some View {
        // ScrollView 在 MenuBarExtra 窗口里没有确定高度会塌缩成 0(卡片全部不显示),
        // 所以先用背景 GeometryReader 量出内容真实高度,再给 ScrollView 定高(超过上限才滚动)。
        ScrollView {
            VStack(spacing: 10) {
                ForEach(store.accounts) { account in
                    AccountCardView(account: account, state: store.states[account.id] ?? .idle)
                }
            }
            .padding(12)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(height: min(max(listHeight, 44), maxListHeight))
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
    }

    private func openAdd(_ provider: Provider) {
        store.pendingAddProvider = provider
        openWindow(id: AddAccountHost.windowID)
        // accessory 应用需主动激活,窗口才能成为 key window 让输入框获得光标
        NSApp.activate(ignoringOtherApps: true)
    }

    private var header: some View {
        HStack {
            Text("QuotaBar")
                .font(.headline)
            Spacer()
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task {
                        isRefreshing = true
                        await store.refreshAll(force: true)
                        isRefreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L("立即刷新", "Refresh now"))
            }

            Menu {
                Button(L("添加 Claude 账号…", "Add Claude account…")) { openAdd(.claude) }
                Button(L("添加 Codex 账号…", "Add Codex account…")) { openAdd(.codex) }
                Divider()
                Picker(L("刷新间隔", "Refresh interval"), selection: Bindable(store).refreshIntervalMinutes) {
                    // Claude 端点社区实测安全轮询 >= 180s
                    Text(L("3 分钟", "3 min")).tag(3)
                    Text(L("5 分钟", "5 min")).tag(5)
                    Text(L("15 分钟", "15 min")).tag(15)
                    Text(L("30 分钟", "30 min")).tag(30)
                }
                Divider()
                Button(L("退出 QuotaBar", "Quit QuotaBar")) { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(L("还没有账号", "No accounts yet"))
                .font(.headline)
            Text(L("添加 Claude 或 Codex 账号后,这里会显示各账号的订阅额度。",
                   "Add a Claude or Codex account to see its subscription usage here."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button(L("添加 Claude", "Add Claude")) { openAdd(.claude) }
                Button(L("添加 Codex", "Add Codex")) { openAdd(.codex) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if let t = store.lastRefreshAt {
                Text(L("更新于 ", "Updated ") + t.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(L("\(store.accounts.count) 个账号", "\(store.accounts.count) accounts"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

import SwiftUI

struct MenuContentView: View {
    @Environment(UsageStore.self) private var store
    @State private var addSheet: Provider?
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.accounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.accounts) { account in
                            AccountCardView(account: account, state: store.states[account.id] ?? .idle)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 480)
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .sheet(item: $addSheet) { provider in
            AddAccountView(provider: provider) { addSheet = nil }
        }
    }

    private var header: some View {
        HStack {
            Text("QuotaBar")
                .font(.headline)
            Spacer()
            Button {
                Task {
                    isRefreshing = true
                    await store.refreshAll()
                    isRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
            }
            .buttonStyle(.borderless)
            .help("立即刷新")

            Menu {
                Button("添加 Claude 账号…") { addSheet = .claude }
                Button("添加 Codex 账号…") { addSheet = .codex }
                Divider()
                Picker("刷新间隔", selection: Bindable(store).refreshIntervalMinutes) {
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                }
                Divider()
                Button("退出 QuotaBar") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
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
            Text("还没有账号")
                .font(.headline)
            Text("添加 Claude 或 Codex 账号后,这里会显示各账号的订阅额度。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("添加 Claude") { addSheet = .claude }
                Button("添加 Codex") { addSheet = .codex }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if let t = store.lastRefreshAt {
                Text("更新于 \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(store.accounts.count) 个账号")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

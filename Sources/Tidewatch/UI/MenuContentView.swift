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
            updateBanner
            manualCheckFeedback
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
                ForEach(store.sortedAccounts) { account in
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
            Text("Tidewatch")
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
                Button(L("添加 GLM 账号…", "Add GLM account…")) { openAdd(.glm) }
                Divider()
                Button(L("Claude Design 项目…", "Claude Design projects…")) {
                    openWindow(id: DesignProjectsWindow.windowID)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Divider()
                Picker(L("刷新间隔", "Refresh interval"), selection: Bindable(store).refreshIntervalMinutes) {
                    // Claude 端点社区实测安全轮询 >= 180s
                    Text(L("3 分钟", "3 min")).tag(3)
                    Text(L("5 分钟", "5 min")).tag(5)
                    Text(L("15 分钟", "15 min")).tag(15)
                    Text(L("30 分钟", "30 min")).tag(30)
                }
                Picker(L("账号排序", "Sort accounts"), selection: Bindable(store).accountSortMode) {
                    Text(L("按订阅到期", "By subscription end")).tag(AccountSortMode.subscriptionEnd)
                }
                Divider()
                // 匿名版本检查:只发当前版本号,可随时关(隐私红线要求默认开、可关)
                Toggle(L("自动检查更新", "Auto-check for updates"), isOn: Bindable(store).updateCheckEnabled)
                Button(L("立即检查更新", "Check for updates now")) {
                    Task { await store.checkForUpdatesNow() }
                }
                .disabled(store.manualCheck == .checking)
                Divider()
                Button(L("退出 Tidewatch", "Quit Tidewatch")) { NSApplication.shared.terminate(nil) }
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

    /// 克制的「有新版」提示:不弹窗、不打断,只在面板顶部亮一条,可下载、可忽略此版本。
    @ViewBuilder
    private var updateBanner: some View {
        if let info = store.updateInfo {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.tint)
                    Text(L("有新版本 ", "New version ") + info.latest)
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer(minLength: 4)
                    if let url = info.url {
                        Link(L("下载", "Download"), destination: url)
                            .font(.caption)
                    }
                    Button {
                        store.skipUpdate()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(L("忽略此版本", "Skip this version"))
                }
                if let notes = info.localizedNotes {
                    Text(notes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.10))
            Divider()
        }
    }

    /// 手动「立即检查更新」的瞬时反馈(检查中/已是最新/失败;有新版走上面的横幅)
    @ViewBuilder
    private var manualCheckFeedback: some View {
        let content: (String, String)? = {
            switch store.manualCheck {
            case .checking: return ("arrow.triangle.2.circlepath", L("正在检查更新…", "Checking for updates…"))
            case .upToDate(let v): return ("checkmark.circle", L("已是最新版本 (\(v))", "You're up to date (\(v))"))
            case .failed: return ("wifi.exclamationmark", L("检查失败,请稍后再试", "Check failed, try again later"))
            case .idle: return nil
            }
        }()
        if let (icon, text) = content {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(text).font(.caption)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary)
            Divider()
        }
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
                Button(L("添加 GLM", "Add GLM")) { openAdd(.glm) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if let t = store.lastRefreshAt {
                Text(L("更新于 ", "Updated ") + t.localized(date: .omitted, time: .shortened))
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

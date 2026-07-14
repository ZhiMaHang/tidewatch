import SwiftUI

/// 「Claude Design 项目」独立窗口:按 Claude 账号分组列出项目(名称 + 首次发现时间 + 打开链接)。
/// 时间是 Tidewatch 记录的"首次发现",因为接口不返回项目真实创建/修改时间。
struct DesignProjectsWindow: View {
    static let windowID = "design-projects"

    @Environment(UsageStore.self) private var store
    @State private var refreshing = false

    private var claudeAccounts: [Account] {
        store.accounts.filter { $0.provider == .claude }
    }

    private var isEmpty: Bool {
        claudeAccounts.allSatisfy { (store.designProjects[$0.id] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(claudeAccounts) { account in
                            let projects = store.designProjects[account.id] ?? []
                            if !projects.isEmpty {
                                accountSection(account, projects)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 480, height: 540)
        .id(store.languageMode) // 语言切换即重译
        .background(WindowConfigurator { window in
            window.level = .normal
            window.hidesOnDeactivate = false
        })
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    private var header: some View {
        HStack {
            Label(L("Claude Design 项目", "Claude Design projects"), systemImage: "paintpalette")
                .font(.headline)
            Spacer()
            if refreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task {
                        refreshing = true
                        for account in claudeAccounts { await store.refreshDesign(account) }
                        refreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L("刷新", "Refresh"))
            }
        }
        .padding(16)
    }

    private func accountSection(_ account: Account, _ projects: [DesignProject]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(account.label.isEmpty ? L("未命名账号", "Unnamed") : account.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(projects) { project in
                HStack(spacing: 8) {
                    Link(destination: URL(string: project.url ?? "https://claude.ai/design") ?? URL(string: "https://claude.ai/design")!) {
                        Label(project.name, systemImage: "doc.richtext")
                            .font(.system(size: 13))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 12)
                    if let seen = store.designFirstSeen[project.id] {
                        Text(L("首次发现 ", "First seen ") + seen.localized(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "paintpalette")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(L("还没有 Design 项目", "No Design projects yet"))
                .font(.headline)
            Text(L("在某个 Claude 账号卡片的 ⋯ 菜单里「登录 Claude Design」后,这里会列出它的项目。",
                   "Use \"Sign in to Claude Design\" in a Claude account's ⋯ menu, then its projects appear here."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(L("注:Claude Design 接口不返回项目时间,时间列为 Tidewatch 首次发现的时间。",
                   "Note: the Claude Design API returns no project timestamps; the time shown is when Tidewatch first saw it."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

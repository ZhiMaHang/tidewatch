import SwiftUI
import AppKit

@main
enum Entry {
    static func main() async {
        // 无头自检:quotabar --check 直接拉取所有账号额度并打印,便于脚本化验证
        if CommandLine.arguments.contains("--check") {
            await runHeadlessCheck()
            return
        }
        QuotaBarApp.main()
    }
}

struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(store)
                .onAppear { store.start() }
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        // 「添加账号」独立开一个真窗口。MenuBarExtra 的面板是 nonactivating panel,
        // 在它上面弹 sheet 时 TextField 拿不到键盘焦点(光标进不去),必须用能成为 key window 的普通窗口。
        Window(L("添加账号", "Add account"), id: AddAccountHost.windowID) {
            AddAccountHost()
                .environment(store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()

        Window(L("Claude Design 项目", "Claude Design projects"), id: DesignProjectsWindow.windowID) {
            DesignProjectsWindow()
                .environment(store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        // 菜单栏只显示图标;各账号额度在点开的面板里看。onAppear 挂这里,不点开也会开始拉取。
        Image(systemName: "gauge.with.needle")
            .onAppear { store.start() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 改名后一次性把旧钥匙串服务名下的 token 迁到新名,避免已添加账号丢失
        KeychainStore.migrateLegacyServiceIfNeeded()
        // 菜单栏应用,不占 Dock(swift run 直跑时也生效;打包后由 LSUIElement 保证)
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - 无头自检

@MainActor
func runHeadlessCheck() async {
    let store = UsageStore()
    let accounts = store.accounts
    print(L("QuotaBar 自检:共 \(accounts.count) 个账号", "QuotaBar check: \(accounts.count) account(s)"))
    if accounts.isEmpty {
        print(L("(尚未添加账号。先启动 App 添加,或直接测试本机 Codex CLI:--check-codex-cli)",
                "(No accounts yet. Launch the app to add one, or probe the local Codex CLI: --check-codex-cli)"))
    }
    for account in accounts {
        await checkOne(account)
    }
    if CommandLine.arguments.contains("--check-codex-cli") || accounts.isEmpty {
        let probe = Account(id: UUID(), provider: .codex, label: L("本机 Codex CLI(探测)", "Local Codex CLI (probe)"), planType: nil,
                            source: .codexAuthFile(path: CodexProvider.defaultAuthPath), addedAt: Date())
        if FileManager.default.fileExists(atPath: CodexProvider.defaultAuthPath) {
            await checkOne(probe)
        }
    }
}

@MainActor
private func checkOne(_ account: Account) async {
    print("\n[\(account.provider.displayName)] \(account.label)")
    do {
        let snapshot: UsageSnapshot
        switch account.provider {
        case .claude:
            (snapshot, _) = try await ClaudeProvider.fetchUsage(for: account)
        case .codex:
            (snapshot, _) = try await CodexProvider.fetchUsage(for: account)
        case .glm:
            snapshot = try await GLMProvider.fetchUsage(for: account)
        }
        if let plan = snapshot.planType { print("  " + L("套餐: ", "Plan: ") + plan) }
        if let email = snapshot.email { print("  " + L("邮箱: ", "Email: ") + email) }
        if let end = snapshot.subscriptionEndsAt {
            print("  " + L("订阅至: ", "Renews: ") + end.formatted(date: .abbreviated, time: .omitted))
        }
        for w in snapshot.windows {
            let reset = w.resetsAt.map { " (" + L("重置于 ", "resets ") + "\($0.formatted()))" } ?? ""
            print("  \(w.title): \(Int(w.usedPercent))%\(reset)")
        }
        if let credits = snapshot.creditsBalance { print("  Credits: \(credits)") }
    } catch {
        print("  " + L("失败: ", "Failed: ") + error.localizedDescription)
    }
}

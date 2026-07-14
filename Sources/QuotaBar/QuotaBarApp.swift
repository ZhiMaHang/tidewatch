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
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        let text = store.menuBarText
        if text.isEmpty {
            Image(systemName: "gauge.with.needle")
        } else {
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.needle")
                Text(text)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏应用,不占 Dock(swift run 直跑时也生效;打包后由 LSUIElement 保证)
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - 无头自检

@MainActor
func runHeadlessCheck() async {
    let store = UsageStore()
    let accounts = store.accounts
    print("QuotaBar 自检:共 \(accounts.count) 个账号")
    if accounts.isEmpty {
        print("(尚未添加账号。先启动 App 添加,或直接测试本机 Codex CLI:--check-codex-cli)")
    }
    for account in accounts {
        await checkOne(account)
    }
    if CommandLine.arguments.contains("--check-codex-cli") || accounts.isEmpty {
        let probe = Account(id: UUID(), provider: .codex, label: "本机 Codex CLI(探测)", planType: nil,
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
        }
        if let plan = snapshot.planType { print("  套餐: \(plan)") }
        if let email = snapshot.email { print("  邮箱: \(email)") }
        for w in snapshot.windows {
            let reset = w.resetsAt.map { " (重置于 \($0.formatted()))" } ?? ""
            print("  \(w.title): \(Int(w.usedPercent))%\(reset)")
        }
        if let credits = snapshot.creditsBalance { print("  Credits: \(credits)") }
    } catch {
        print("  失败: \(error.localizedDescription)")
    }
}

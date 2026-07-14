import SwiftUI

/// 「添加账号」独立窗口的根视图:从 store.pendingAddProvider 取要添加的提供方,
/// 完成/取消后清空并关闭窗口。窗口能成为 key window,输入框才能获得光标。
struct AddAccountHost: View {
    static let windowID = "add-account"

    @Environment(UsageStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let provider = store.pendingAddProvider {
                AddAccountView(provider: provider) {
                    store.pendingAddProvider = nil
                    dismiss()
                }
            } else {
                // 冷启动时系统可能恢复空窗口,直接关掉
                Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear { dismiss() }
            }
        }
        .background(WindowConfigurator { window in
            // 降回普通层级,别一直浮在最前面;当窗口不再是焦点时也不隐藏
            window.level = .normal
            window.hidesOnDeactivate = false
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.isMovableByWindowBackground = false
        })
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

struct AddAccountView: View {
    @Environment(UsageStore.self) private var store
    let provider: Provider
    let onDone: () -> Void

    @State private var pkce = PKCE()
    @State private var pastedCode = ""
    @State private var customLabel = ""
    @State private var busy = false
    @State private var statusText = ""
    @State private var errorText = ""
    @State private var authPath = CodexProvider.defaultAuthPath
    @State private var callbackServer: LocalCallbackServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("添加 \(provider.displayName) 账号", "Add \(provider.displayName) account"))
                .font(.headline)

            if provider == .claude {
                claudeFlow
            } else {
                codexFlow
            }

            if !statusText.isEmpty {
                Label(statusText, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !errorText.isEmpty {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(L("取消", "Cancel")) {
                    callbackServer?.stop()
                    onDone()
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    // MARK: Claude:浏览器授权 + 粘贴授权码

    private var claudeFlow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("1. 打开浏览器登录要添加的 Claude 账号并授权;\n2. 把回调页显示的授权码粘贴到下面。",
                   "1. Open the browser, sign in to the Claude account you want to add, and authorize.\n2. Paste the code shown on the callback page below."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(L("在浏览器中打开授权页", "Open authorization page")) {
                errorText = ""
                NSWorkspace.shared.open(ClaudeOAuth.authorizeURL(pkce: pkce))
            }

            TextField(L("粘贴授权码(形如 xxxx#yyyy)", "Paste code (like xxxx#yyyy)"), text: $pastedCode)
                .textFieldStyle(.roundedBorder)

            TextField(L("账号备注名(可选,如\"个人 Max\")", "Nickname (optional, e.g. \"Personal Max\")"), text: $customLabel)
                .textFieldStyle(.roundedBorder)

            Button(busy ? L("验证中…", "Verifying…") : L("完成登录", "Finish login")) {
                Task { await finishClaude() }
            }
            .disabled(pastedCode.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            .keyboardShortcut(.defaultAction)

            Divider()
            Button(L("改为导入本机 Claude Code CLI 凭据", "Import local Claude Code CLI credentials instead")) {
                importClaudeCLI()
            }
            .font(.caption)
        }
    }

    private func finishClaude() async {
        busy = true
        defer { busy = false }
        errorText = ""
        do {
            let creds = try await ClaudeOAuth.exchange(pastedCode: pastedCode, pkce: pkce)
            var label = customLabel.trimmingCharacters(in: .whitespaces)
            var plan: String?
            if let profile = try? await ClaudeProvider.fetchProfile(accessToken: creds.accessToken) {
                if label.isEmpty, let email = profile.email { label = email }
                plan = profile.plan
            }
            if label.isEmpty { label = L("未命名 Claude", "Unnamed Claude") }
            let account = Account(id: UUID(), provider: .claude, label: label, planType: plan, source: .managed, addedAt: Date())
            if let data = try? JSONEncoder().encode(creds) {
                KeychainStore.save(data, key: account.id.uuidString)
            }
            store.addAccount(account)
            onDone()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importClaudeCLI() {
        errorText = ""
        let account = Account(id: UUID(), provider: .claude, label: L("本机 Claude Code", "Local Claude Code"), planType: nil, source: .claudeCLI(credentialsFilePath: nil), addedAt: Date())
        do {
            let creds = try ClaudeProvider.loadCredentials(for: account)
            var final = account
            final.planType = creds.subscriptionType
            // ~/.claude.json 的 oauthAccount 里有邮箱(非机密元数据)
            let claudeJSON = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
            if let data = try? Data(contentsOf: URL(fileURLWithPath: claudeJSON)),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let oauthAccount = obj["oauthAccount"] as? [String: Any],
               let email = oauthAccount["emailAddress"] as? String {
                final.label = email
            }
            guard store.addAccount(final) else {
                errorText = L("本机 Claude Code 凭据已经添加过了", "Local Claude Code credentials are already added")
                return
            }
            onDone()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: Codex:导入 auth.json 或浏览器授权(localhost 回调)

    private var codexFlow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("方式一:导入 Codex CLI 已登录的 auth.json(推荐,多账号可指向不同 CODEX_HOME)",
                   "Option 1: import a signed-in Codex CLI auth.json (recommended; point multiple accounts at different CODEX_HOME dirs)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField(L("auth.json 路径", "auth.json path"), text: $authPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button(L("选择…", "Choose…")) { pickAuthFile() }
            }
            Button(L("导入此 auth.json", "Import this auth.json")) { importCodexAuthFile() }
                .disabled(busy)

            Divider()
            Text(L("方式二:在浏览器中登录要添加的 ChatGPT 账号(独立 token,不影响 CLI)",
                   "Option 2: sign in to the ChatGPT account in the browser (separate token, doesn't affect the CLI)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(busy ? L("等待浏览器授权…", "Waiting for browser…") : L("在浏览器中登录", "Sign in with browser")) {
                Task { await loginCodex() }
            }
            .disabled(busy)
        }
    }

    private func pickAuthFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".codex"))
        if panel.runModal() == .OK, let url = panel.url {
            authPath = url.path
        }
    }

    private func importCodexAuthFile() {
        errorText = ""
        let path = (authPath as NSString).expandingTildeInPath
        let account = Account(id: UUID(), provider: .codex, label: "", planType: nil, source: .codexAuthFile(path: path), addedAt: Date())
        do {
            let tokens = try CodexProvider.loadTokens(for: account)
            var final = account
            final.label = tokens.id_token.flatMap(CodexProvider.email(fromIDToken:)) ?? L("本机 Codex CLI", "Local Codex CLI")
            guard store.addAccount(final) else {
                errorText = L("这个 auth.json 已经添加过了", "This auth.json is already added")
                return
            }
            onDone()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loginCodex() async {
        busy = true
        statusText = L("已打开浏览器,等待授权回调…", "Browser opened, waiting for the callback…")
        errorText = ""
        defer {
            busy = false
            statusText = ""
        }
        let server = LocalCallbackServer(port: CodexOAuth.callbackPort)
        callbackServer = server
        NSWorkspace.shared.open(CodexOAuth.authorizeURL(pkce: pkce))
        do {
            let params = try await server.waitForCallback(expectedState: pkce.state)
            guard let code = params["code"] else {
                throw QuotaError.oauth(params["error_description"] ?? params["error"] ?? L("回调里没有授权码", "No authorization code in the callback"))
            }
            statusText = L("正在换取 token…", "Exchanging token…")
            let tokens = try await CodexOAuth.exchange(code: code, pkce: pkce)
            let account = Account(
                id: UUID(),
                provider: .codex,
                label: tokens.id_token.flatMap(CodexProvider.email(fromIDToken:)) ?? "",
                planType: nil,
                source: .managed,
                addedAt: Date()
            )
            if let data = try? JSONEncoder().encode(tokens) {
                KeychainStore.save(data, key: account.id.uuidString)
            }
            store.addAccount(account)
            onDone()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

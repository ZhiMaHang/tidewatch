import SwiftUI

struct AddAccountView: View {
    @Environment(UsageStore.self) private var store
    let provider: Provider
    let onDone: () -> Void

    @State private var pkce = PKCE()
    @State private var pastedCode = ""
    @State private var busy = false
    @State private var statusText = ""
    @State private var errorText = ""
    @State private var authPath = CodexProvider.defaultAuthPath
    @State private var callbackServer: LocalCallbackServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加 \(provider.displayName) 账号")
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
                Button("取消") {
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
            Text("1. 打开浏览器登录要添加的 Claude 账号并授权;\n2. 把回调页显示的授权码粘贴到下面。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("在浏览器中打开授权页") {
                errorText = ""
                NSWorkspace.shared.open(ClaudeOAuth.authorizeURL(pkce: pkce))
            }

            TextField("粘贴授权码(形如 xxxx#yyyy)", text: $pastedCode)
                .textFieldStyle(.roundedBorder)

            Button(busy ? "验证中…" : "完成登录") {
                Task { await finishClaude() }
            }
            .disabled(pastedCode.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            .keyboardShortcut(.defaultAction)

            Divider()
            Button("改为导入本机 Claude Code CLI 凭据") {
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
            var label = "未命名 Claude"
            var plan: String?
            if let profile = try? await ClaudeProvider.fetchProfile(accessToken: creds.accessToken) {
                if let email = profile.email { label = email }
                plan = profile.plan
            }
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
        let account = Account(id: UUID(), provider: .claude, label: "本机 Claude Code", planType: nil, source: .claudeCLI(credentialsFilePath: nil), addedAt: Date())
        do {
            let creds = try ClaudeProvider.loadCredentials(for: account)
            var final = account
            final.planType = creds.subscriptionType
            store.addAccount(final)
            onDone()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: Codex:导入 auth.json 或浏览器授权(localhost 回调)

    private var codexFlow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("方式一:导入 Codex CLI 已登录的 auth.json(推荐,多账号可指向不同 CODEX_HOME)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("auth.json 路径", text: $authPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("选择…") { pickAuthFile() }
            }
            Button("导入此 auth.json") { importCodexAuthFile() }
                .disabled(busy)

            Divider()
            Text("方式二:在浏览器中登录要添加的 ChatGPT 账号(独立 token,不影响 CLI)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(busy ? "等待浏览器授权…" : "在浏览器中登录") {
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
            final.label = tokens.id_token.flatMap(CodexProvider.email(fromIDToken:)) ?? "本机 Codex CLI"
            store.addAccount(final)
            onDone()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loginCodex() async {
        busy = true
        statusText = "已打开浏览器,等待授权回调…"
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
                throw QuotaError.oauth(params["error_description"] ?? params["error"] ?? "回调里没有授权码")
            }
            statusText = "正在换取 token…"
            let tokens = try await CodexOAuth.exchange(code: code, pkce: pkce)
            let account = Account(
                id: UUID(),
                provider: .codex,
                label: tokens.id_token.flatMap(CodexProvider.email(fromIDToken:)) ?? "未命名 Codex",
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

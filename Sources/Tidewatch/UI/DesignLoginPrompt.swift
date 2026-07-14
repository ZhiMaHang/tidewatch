import AppKit

/// 打开浏览器做 Claude Design 授权,再弹 NSAlert 让用户粘贴授权码。
/// 返回 (pkce, code) 供调用方 exchange;取消返回 nil。
@MainActor
enum DesignLoginPrompt {
    static func run() -> (pkce: PKCE, code: String)? {
        let pkce = PKCE()
        NSWorkspace.shared.open(ClaudeDesignOAuth.authorizeURL(pkce: pkce))
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = L("登录 Claude Design", "Sign in to Claude Design")
        alert.informativeText = L("已打开浏览器授权 Design 读取权限;把回调页显示的授权码粘到下面。",
                                  "Browser opened to authorize Design read access — paste the code from the callback page below.")
        alert.addButton(withTitle: L("完成", "Done"))
        alert.addButton(withTitle: L("取消", "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "code#state"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let code = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : (pkce, code)
    }
}

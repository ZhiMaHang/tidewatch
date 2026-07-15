import AppKit

/// 打开浏览器做 Claude 主账号授权,再弹 NSAlert 让用户粘贴授权码。
/// 用于已有 managed 账号「重新登录」:换全新 token 家族(旧家族被限流/吊销时的自愈通道),
/// 保留账号 UUID 与全部元数据(备注名/付款方式/订阅日期)。
@MainActor
enum ClaudeReloginPrompt {
    static func run(label: String) -> (pkce: PKCE, code: String)? {
        let pkce = PKCE()
        NSWorkspace.shared.open(ClaudeOAuth.authorizeURL(pkce: pkce))
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = L("重新登录「\(label)」", "Re-sign in \"\(label)\"")
        alert.informativeText = L("已打开浏览器;请登录这个账号并授权,再把回调页显示的授权码粘到下面。",
                                  "Browser opened — sign in to this account, authorize, then paste the code from the callback page below.")
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

import AppKit

/// 弹一个带输入框的 NSAlert 改账号名。用 AppKit modal 而不是 SwiftUI 面板内的 TextField,
/// 因为 MenuBarExtra 的 nonactivating panel 里输入框拿不到键盘焦点;NSAlert 激活后能稳定获得光标。
@MainActor
enum RenamePrompt {
    static func run(current: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = L("重命名账号", "Rename account")
        alert.informativeText = L("设置这个账号在 Tidewatch 里显示的名称", "Set the name shown for this account in Tidewatch")
        alert.addButton(withTitle: L("保存", "Save"))
        alert.addButton(withTitle: L("取消", "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        field.placeholderString = L("账号名称", "Account name")
        field.lineBreakMode = .byTruncatingTail
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

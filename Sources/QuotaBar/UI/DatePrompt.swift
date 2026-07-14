import AppKit

/// 弹一个带日期选择器的 NSAlert,让用户手填/清除订阅到期日。
/// 用 AppKit modal 而非面板内控件——MenuBarExtra 的 nonactivating panel 里控件拿不到焦点。
@MainActor
enum DatePrompt {
    enum Result {
        case set(Date)
        case clear
        case cancel
    }

    static func run(current: Date?) -> Result {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = L("设置订阅到期日", "Set renewal date")
        alert.informativeText = L("Claude 接口不返回续订日,可在此手动填写;留空或点清除可移除。",
                                  "Claude's API doesn't return a renewal date — set it manually here. Use Clear to remove it.")
        alert.addButton(withTitle: L("保存", "Save"))
        alert.addButton(withTitle: L("清除", "Clear"))
        alert.addButton(withTitle: L("取消", "Cancel"))

        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .yearMonthDay
        picker.dateValue = current ?? Date()
        alert.accessoryView = picker
        alert.window.initialFirstResponder = picker

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .set(picker.dateValue)
        case .alertSecondButtonReturn: return .clear
        default: return .cancel
        }
    }
}

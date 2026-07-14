import SwiftUI
import AppKit

/// 编辑账号付款方式。NSAlert 弹窗内嵌一个 SwiftUI 表单(类型分段选择 + 明细输入),
/// 用 AppKit modal 保证键盘焦点。信用卡只保留后四位,绝不保存完整卡号。
@MainActor
enum PaymentPrompt {
    enum Result {
        case set(PaymentMethod)
        case clear
        case cancel
    }

    static func run(current: PaymentMethod?) -> Result {
        NSApp.activate(ignoringOtherApps: true)

        let draft = PaymentDraft(current)
        let alert = NSAlert()
        alert.messageText = L("设置付款方式", "Set payment method")
        alert.informativeText = L("信用卡只会保存并显示后四位,不保存完整卡号。",
                                  "For a credit card, only the last 4 digits are stored and shown — never the full number.")
        alert.addButton(withTitle: L("保存", "Save"))
        alert.addButton(withTitle: L("清除", "Clear"))
        alert.addButton(withTitle: L("取消", "Cancel"))

        let host = NSHostingView(rootView: PaymentForm(draft: draft))
        host.frame = NSRect(x: 0, y: 0, width: 288, height: 76)
        alert.accessoryView = host

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .set(PaymentMethod(type: draft.type, detail: draft.sanitizedDetail()))
        case .alertSecondButtonReturn:
            return .clear
        default:
            return .cancel
        }
    }
}

@MainActor
final class PaymentDraft: ObservableObject {
    @Published var type: PaymentType
    @Published var detail: String

    init(_ current: PaymentMethod?) {
        type = current?.type ?? .applePay
        detail = current?.detail ?? ""
    }

    /// 信用卡:只从输入里取数字的后四位;其它:去空白
    func sanitizedDetail() -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == .creditCard {
            return String(trimmed.filter(\.isNumber).suffix(4))
        }
        return trimmed
    }
}

private struct PaymentForm: View {
    @ObservedObject var draft: PaymentDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $draft.type) {
                ForEach(PaymentType.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(draft.type.fieldPlaceholder, text: $draft.detail)
                .textFieldStyle(.roundedBorder)
        }
        .frame(width: 288)
    }
}

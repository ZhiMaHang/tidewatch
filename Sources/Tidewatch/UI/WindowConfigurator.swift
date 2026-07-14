import SwiftUI
import AppKit

/// 拿到承载视图的 NSWindow 做原生配置。用于把从 MenuBarExtra 派生的窗口
/// 从浮动层降回普通层级,避免它一直盖在所有窗口最前面。
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            configure(window)
        }
    }
}
